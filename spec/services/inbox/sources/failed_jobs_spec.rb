# frozen_string_literal: true

require 'rails_helper'
require_relative '../summary_fixtures'

RSpec.describe Inbox::Sources::FailedJobs do
  include InboxSummaryFixtures

  let(:log) { SeasonBoard::ActivityLog.new }
  let(:queue) { instance_double(Dashboard::QueueActivity, failed: []) }

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    allow(Dashboard::QueueActivity).to receive(:new).and_return(queue)
  end

  after(:each) { FileUtils.rm_f(SeasonBoard::ActivityLog.default_path) }

  def fail!(fin_event_id, kind)
    log.queue!(fin_event_id, kind:, origin: :auto)
    log.finish!(fin_event_id, kind:, status: :failed, message: 'Timeout')
  end

  def items_for(summary)
    described_class.new.items(inbox_context(board_snapshot: summary, now: Time.current))
  end

  it 'retries a failed crawl while the row still asks for it, keyed like the board item it replaces' do
    fail!('1', :crawl)
    fail!('2', :crawl)
    fail!('3', :extract)
    summary = board_summary(rows: [board_row_payload('1', :structure_committed, :check_results),
                                   board_row_payload('2', :results_ready, :review_results, file_path: '/r.json'),
                                   board_row_payload('3', :manifest_pending, :extract_manifest, pdf_path: '/m.pdf')])
    items = items_for(summary)
    expect(items.map(&:key)).to contain_exactly('board:1:check_results', 'board:3:extract_manifest')
    expect(items.map(&:band).uniq).to eq([:failed])
    crawl = items.find { |item| item.key == 'board:1:check_results' }
    expect(crawl.action).to have_attributes(http_method: :post, path: '/season_board/crawl', params: { fin_event_id: '1' })
    expect(crawl.title).to include('Meeting 1')
  end

  it 'reports a stuck (stale) running crawl, but not a busy row nor a row gone from the board' do
    log.start!('1', kind: :crawl)
    entries = log.all_entries.map { |entry| entry.with(started_at: 2.hours.ago) }
    allow(SeasonBoard::ActivityLog).to receive(:new).and_return(instance_double(SeasonBoard::ActivityLog, all_entries: entries))
    expect(items_for(board_summary(rows: [board_row_payload('1', :link_not_crawled, :crawl)])).map(&:kind)).to eq([:crawl_stuck])
    expect(items_for(board_summary(rows: [board_row_payload('1', :link_not_crawled, :crawl, busy: true)]))).to eq([])
    expect(items_for(board_summary(rows: []))).to eq([])
  end

  # 0.10.99: a prepare whose job was lost (closed by SeasonBoard::ActivityReconciler) or that seems stuck.
  describe 'prepares' do
    around(:each) { |example| I18n.with_locale(:en) { example.run } }

    let(:review_row) { board_row_payload('1', :needs_review, :resume_review, file_path: '/d/262/a.json', phase: 2) }

    it 'retries a lost prepare with a POST to the board prepare action, keyed like the PrepareFailed item' do
      log.queue!('1', kind: :prepare, origin: :auto)
      log.finish!('1', kind: :prepare, status: :failed, message: 'lost: gone', reason: SeasonBoard::ActivityLog::LOST_REASON)
      item = items_for(board_summary(rows: [review_row])).sole
      expect(item).to have_attributes(key: 'board:1:prepare', kind: :prepare_lost, band: :failed, title: 'Preparation lost (no longer in the queue): Meeting 1')
      expect(item.action).to have_attributes(http_method: :post, path: '/season_board/prepare', params: { fin_event_id: '1' })
    end

    it 'reports a stuck (stale) queued prepare, not a refused or failed one, nor a row left to PrepareFailed or without source' do
      log.queue!('1', kind: :prepare, origin: :auto)
      stuck = log.all_entries.map { |entry| entry.with(queued_at: 13.hours.ago) }
      allow(SeasonBoard::ActivityLog).to receive(:new).and_return(instance_double(SeasonBoard::ActivityLog, all_entries: stuck))
      expect(items_for(board_summary(rows: [review_row])).map(&:kind)).to eq([:prepare_stuck])
      failed_row = board_row_payload('1', :prepare_failed, :prepare, file_path: '/d/262/a.json')
      expect(items_for(board_summary(rows: [failed_row]))).to eq([])
      expect(items_for(board_summary(rows: [board_row_payload('1', :link_not_crawled, :crawl)]))).to eq([])

      refused = stuck.map { |entry| entry.with(status: :failed, finished_at: 1.hour.ago, message: 'Refused: automation paused') }
      allow(SeasonBoard::ActivityLog).to receive(:new).and_return(instance_double(SeasonBoard::ActivityLog, all_entries: refused))
      expect(items_for(board_summary(rows: [review_row]))).to eq([])
    end
  end

  it 'uses the default board action without a board summary' do
    fail!('9', :extract)
    expect(items_for(nil).map(&:key)).to eq(['board:9:extract_manifest'])
  end

  it 'offers Discard for every failed Solid Queue job, and Retry only outside the protected jobs' do
    failed = Dashboard::QueueActivity::Failed.new(id: 1, job_id: 10, class_name: 'KpiRefreshJob', queue_name: 'default',
                                                  exception_class: 'RuntimeError', message: 'boom', created_at: 1.hour.ago)
    allow(queue).to receive(:failed).and_return([failed, failed.with(id: 2, class_name: 'DataFixCommitJob')])
    items = items_for(nil).index_by(&:key)
    expect(items['job:1'].action).to have_attributes(path: '/dashboard/discard_failed_job', params: { id: 1 })
    expect(items['job:1'].secondary_action.path).to eq('/dashboard/retry_failed_job')
    expect(items['job:1'].detail).to include('RuntimeError: boom')
    expect(items['job:2'].secondary_action).to be_nil
    expect(described_class.retriable?('Outbox::PushJob')).to be false
  end

  describe "the failed automatic FIN 'Eventi' calendar crawl (0.10.103)" do
    let(:season) { FactoryBot.build_stubbed(:season, id: 262, begin_date: Date.new(2026, 10, 1), end_date: Date.new(2027, 9, 30)) }
    let(:request) { Sources::CrawlRequest.eventi_calendar(season) }
    let(:context) { inbox_context(season:, board_snapshot: board_summary, now: Time.current) }

    def calendar!(origin, status, message: 'no new calendar file')
      log.queue!(request.key, kind: :crawl, origin:, url: request.target, label: request.label)
      log.finish!(request.key, kind: :crawl, status:, message:)
    end

    it 'offers Retry: an operator POST of the same Eventi crawl, keyed once per season' do
      calendar!(:auto, :failed)
      item = described_class.new.items(context).sole
      expect(item).to have_attributes(key: 'calendar_crawl:262', band: :failed, kind: :calendar_crawl_failed)
      expect(item.detail).to include('no new calendar file')
      expect(item.action).to have_attributes(http_method: :post, path: '/sources/crawls',
                                             params: { kind: 'calendar', season_id: 262, sub_menu_type: 'Eventi', year_text: '2026/2027' })
    end

    it 'goes once a later crawl succeeds, and never shows a manual failure or a refusal with the automation off' do
      calendar!(:auto, :failed)
      calendar!(:auto, :done, message: 'done')
      expect(described_class.new.items(context)).to eq([])
      calendar!(:manual, :failed)
      expect(described_class.new.items(context)).to eq([])
      calendar!(:auto, :failed, message: I18n.t('pipeline_automation.reasons.automation_paused'))
      expect(described_class.new.items(context)).to eq([])
    end
  end
end
