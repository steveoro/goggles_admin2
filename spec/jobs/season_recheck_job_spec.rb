# frozen_string_literal: true

require 'rails_helper'
require 'fugit'
require_relative '../services/season_board/board_rows'

RSpec.describe SeasonRecheckJob do
  include SeasonBoardRows
  include ActiveSupport::Testing::TimeHelpers

  let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:rows) { [] }
  let(:builder) { instance_double(SeasonBoard::Builder, call: board_result(rows)) }

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Builder).to receive_messages(latest_season: season, new: builder)
    allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
  end

  after(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  it 'is enqueued on the background queue' do
    expect { described_class.perform_later }.to have_enqueued_job(described_class).on_queue('background')
  end

  it 'is scheduled daily as season_board_recheck, on the background queue, off the watcher minutes' do
    recurring = ActiveSupport::ConfigurationFile.parse(Rails.root.join('config/recurring.yml'))
    task = recurring.dig('production', 'season_board_recheck')
    expect(task).to include('class' => described_class.name, 'queue' => 'background')
    cron = Fugit.parse(task['schedule'])
    expect(cron).to be_a(Fugit::Cron)
    expect(cron.minutes).not_to include(0, 30)
    expect(cron.hours.size).to eq(1)
  end

  context 'with past & future rows' do
    let(:rows) do
      [
        board_row(fin_event_id: '1', state: :structure_committed, action: :check_results, last_date: Date.current - 10),
        board_row(fin_event_id: '2', state: :structure_committed, action: nil, last_date: Date.current + 3),
        board_row(fin_event_id: '3', state: :link_not_crawled, action: :crawl, last_date: Date.current - 2),
        board_row(fin_event_id: '4', state: :link_not_crawled, action: :crawl, last_date: Date.current + 5),
        board_row(fin_event_id: '5', state: :committed_with_results, last_date: Date.current - 20),
        board_row(fin_event_id: '6', state: :link_not_crawled, action: :crawl, last_date: Date.current - 1, busy: true)
      ]
    end

    it 'auto-crawls the past rows still without results, most recent first' do
      expect(described_class.perform_now).to eq(%w[3 1])
      expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '3', url: rows[2].url, origin: :auto).ordered
      expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '1', url: rows[0].url, origin: :auto).ordered
    end

    it 'skips rows crawled less than 20 hours ago' do
      activity_log.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
      activity_log.finish!('3', kind: :crawl, status: :done)
      expect(described_class.perform_now).to eq(%w[1])
    end

    it 'crawls again rows whose last attempt is older than 20 hours' do
      travel_to(21.hours.ago) do
        activity_log.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
        activity_log.finish!('3', kind: :crawl, status: :failed)
      end
      expect(described_class.perform_now).to eq(%w[3 1])
    end
  end

  context 'with future rows whose automatic crawl failed' do
    let(:rows) do
      [
        board_row(fin_event_id: '1', state: :link_not_crawled, action: :crawl, last_date: Date.current + 5),
        board_row(fin_event_id: '2', state: :link_not_crawled, action: :crawl, last_date: Date.current + 9),
        board_row(fin_event_id: '3', state: :link_not_crawled, action: :crawl, last_date: Date.current + 2),
        board_row(fin_event_id: '4', state: :link_not_crawled, action: :crawl, last_date: Date.current - 1),
        board_row(fin_event_id: '5', state: :link_not_crawled, action: :crawl, last_date: nil)
      ]
    end

    def attempt(fin_id, status, at:)
      travel_to(at) do
        activity_log.queue!(fin_id, kind: :crawl, origin: :auto, url: rows.find { |row| row.fin_event_id == fin_id }.url)
        activity_log.finish!(fin_id, kind: :crawl, status:)
      end
    end

    it 'retries the failed crawls older than 20 hours regardless of the date, after the past rows' do
      attempt('1', :failed, at: 21.hours.ago)
      attempt('2', :done, at: 21.hours.ago)
      attempt('3', :failed, at: 2.hours.ago)
      attempt('5', :failed, at: 2.days.ago)
      expect(described_class.perform_now).to eq(%w[4 1 5])
    end

    it 'counts the retries within the per-run cap' do
      stub_const("#{described_class}::MAX_CRAWLS_PER_RUN", 2)
      attempt('1', :failed, at: 21.hours.ago)
      attempt('5', :failed, at: 21.hours.ago)
      expect(described_class.perform_now).to eq(%w[4 1])
    end
  end

  context 'when an enqueue fails' do
    let(:rows) do
      [
        board_row(fin_event_id: '1', state: :link_not_crawled, action: :crawl, last_date: Date.current - 1),
        board_row(fin_event_id: '2', state: :link_not_crawled, action: :crawl, last_date: Date.current - 2)
      ]
    end

    it 'logs the error and goes on with the remaining rows' do
      allow(SeasonBoard::Scheduler).to receive(:crawl!).with(hash_including(fin_event_id: '1')).and_raise(StandardError, 'queue DB missing')
      allow(Rails.logger).to receive(:error)
      expect(described_class.perform_now).to eq(%w[2])
      expect(Rails.logger).to have_received(:error).with(/FIN 1.*queue DB missing/)
    end
  end

  context 'with many candidates' do
    let(:rows) do
      (1..20).map { |idx| board_row(fin_event_id: idx.to_s, state: :link_not_crawled, action: :crawl, last_date: Date.current - idx) }
    end

    it 'caps the crawls per run' do
      expect(described_class.perform_now.size).to eq(described_class::MAX_CRAWLS_PER_RUN)
      expect(SeasonBoard::Scheduler).to have_received(:crawl!).exactly(described_class::MAX_CRAWLS_PER_RUN).times
    end
  end

  it 'does nothing without a season' do
    allow(SeasonBoard::Builder).to receive(:latest_season).and_return(nil)
    expect(described_class.perform_now).to eq([])
  end
end
