# frozen_string_literal: true

require 'rails_helper'
require_relative 'board_rows'

RSpec.describe SeasonBoard::CrawlPlanner do
  include SeasonBoardRows
  include ActiveSupport::Testing::TimeHelpers

  let(:season) { FactoryBot.build_stubbed(:season, id: 262) }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:rows) do
    [
      board_row(fin_event_id: '1', state: :link_not_crawled, action: :crawl),
      board_row(fin_event_id: '2', state: :link_not_crawled, action: :crawl),
      board_row(fin_event_id: '3', state: :structure_committed, action: :check_results),
      board_row(fin_event_id: '4', state: :link_not_crawled, action: :crawl)
    ]
  end
  let(:builder) { instance_double(SeasonBoard::Builder, call: board_result(rows)) }

  def change_for(*fin_ids, key: 'added')
    { key => fin_ids.map { |id| { 'url' => rows.find { |row| row.fin_event_id == id }.url } }, 'removed' => [] }
  end

  def plan(change)
    described_class.new(season:, activity_log:, builder:).call(change)
  end

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(true)
  end

  after(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  it 'auto-crawls the changed :link_not_crawled rows only' do
    change = change_for('1', '3').merge('with_results' => change_for('2')['added'], 'updated' => [])
    expect(plan(change)).to eq(%w[1 2])
    expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '1', url: rows[0].url, origin: :auto)
    expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '2', url: rows[1].url, origin: :auto)
    expect(SeasonBoard::Scheduler).to have_received(:crawl!).twice
  end

  it 'skips the rows whose date matches a local calendar not linked yet' do
    rows[1] = board_row(fin_event_id: '2', state: :link_not_crawled, action: :crawl, flags: [:possible_unlinked_meeting])
    expect(plan(change_for('1', '2'))).to eq(%w[1])
    expect(SeasonBoard::Scheduler).to have_received(:crawl!).once
  end

  it 'stores its board build as the board summary' do
    plan(change_for('1'))
    expect(SeasonBoard::Snapshot.read(262).rows.map(&:fin_event_id)).to eq(%w[1 2 3 4])
  end

  it 'considers the updated rows too' do
    expect(plan(change_for('4', key: 'updated'))).to eq(%w[4])
  end

  it 'skips rows already attempted for the same URL (the change is cumulative)' do
    activity_log.queue!('1', kind: :crawl, origin: :auto, url: rows[0].url)
    activity_log.finish!('1', kind: :crawl, status: :done, message: 'no results yet')
    expect(plan(change_for('1', '2'))).to eq(%w[2])
  end

  it 'crawls again when the previous attempt was for a different URL' do
    activity_log.queue!('1', kind: :crawl, origin: :auto, url: 'https://www.federnuoto.it/old#/risultati/1:old.html')
    activity_log.finish!('1', kind: :crawl, status: :failed)
    expect(plan(change_for('1'))).to eq(%w[1])
  end

  it 'logs a failed enqueue and goes on with the remaining rows' do
    allow(SeasonBoard::Scheduler).to receive(:crawl!).with(hash_including(fin_event_id: '1')).and_raise(StandardError, 'queue DB missing')
    allow(Rails.logger).to receive(:error)
    expect(plan(change_for('1', '2'))).to eq(%w[2])
    expect(Rails.logger).to have_received(:error).with(/FIN 1.*queue DB missing/)
  end

  it 'omits rows refused by the Scheduler (busy)' do
    allow(SeasonBoard::Scheduler).to receive(:crawl!).and_return(false)
    expect(plan(change_for('1'))).to eq([])
  end

  it 'does nothing without a change, changed FIN ids or season' do
    expect(plan(nil)).to eq([])
    expect(plan('added' => [{ 'url' => '' }])).to eq([])
    expect(described_class.new(season: nil, activity_log:, builder:).call(change_for('1'))).to eq([])
    expect(builder).not_to have_received(:call)
  end

  it 'queues nothing with the automation master switch off (phase 10)' do
    DataFix::Automation.store!(:enabled, false)
    expect(plan(change_for('1', '2'))).to eq([])
    expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
  end

  describe '#plan_recrawl (FIN now lists a structure-committed meeting with results)' do
    def recrawl(change)
      described_class.new(season:, activity_log:, builder:).plan_recrawl(change)
    end

    let(:with_results) { { 'with_results' => [{ 'url' => rows[2].url }, { 'url' => rows[0].url }] } }

    it 're-crawls only the :structure_committed rows listed under with_results, ignoring the same-URL dedupe' do
      activity_log.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
      activity_log.finish!('3', kind: :crawl, status: :done)
      Ops::Snapshot.delete_all
      travel_to(21.hours.from_now) do
        expect(recrawl(with_results)).to eq(%w[3])
        expect(SeasonBoard::Scheduler).to have_received(:crawl!).with(season_id: 262, fin_event_id: '3', url: rows[2].url, origin: :auto).once
      end
    end

    it 'crawls a row at most once per 20 hours' do
      activity_log.queue!('3', kind: :crawl, origin: :auto, url: rows[2].url)
      activity_log.finish!('3', kind: :crawl, status: :done)
      expect(recrawl(with_results)).to eq([])
      expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
    end

    it 'skips busy rows and queues nothing with the automation off' do
      rows[2] = board_row(fin_event_id: '3', state: :structure_committed, action: :check_results, busy: true)
      expect(recrawl(with_results)).to eq([])
      rows[2] = board_row(fin_event_id: '3', state: :structure_committed, action: :check_results)
      allow(DataFix::Automation).to receive(:env_off?).and_return(true)
      expect(recrawl(with_results)).to eq([])
      expect(SeasonBoard::Scheduler).not_to have_received(:crawl!)
    end
  end
end
