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
end
