# frozen_string_literal: true

require 'rails_helper'
require_relative '../season_board/board_rows'

# 0.10.103: when the pending FIN change has been followed up by the pipeline (the auto-dismissal of the alert).
RSpec.describe FedernuotoWatch::Parity do
  include SeasonBoardRows
  include ActiveSupport::Testing::TimeHelpers

  let(:season) { FactoryBot.build_stubbed(:season, id: 262, begin_date: Date.new(2026, 10, 1), end_date: Date.new(2027, 9, 30)) }
  let(:tmp_dir) { Pathname.new(Dir.mktmpdir('fin-parity')) }
  let(:store) { FedernuotoWatch::StateStore.new(path: tmp_dir.join('state.json')) }
  let(:activity_log) { SeasonBoard::ActivityLog.new }
  let(:rows) { [] }
  let(:detected_at) { 1.hour.ago }
  let(:calendar_key) { Sources::CrawlRequest.eventi_calendar(season).key }

  def summary_of(board_rows)
    payload = SeasonBoard::Snapshot::Payload.call(board_result(board_rows), season_id: 262, fingerprint: nil)
    SeasonBoard::Snapshot::Summary.from_payload(payload, stored: false, taken_at: Time.current)
  end

  # A change row of +fin_id+ (its own link unless url: '').
  def change_row(fin_id, url: nil, name: nil)
    { 'key' => "k-#{fin_id}", 'name' => name || "Meeting #{fin_id}", 'date' => '08/11', 'year' => '2026', 'place' => 'X',
      'url' => url.nil? ? board_row(fin_event_id: fin_id, state: :not_linked).url : url, 'info' => '' }
  end

  def change(added: [], updated: [], with_results: [], removed: [])
    { 'added' => added, 'updated' => updated, 'with_results' => with_results, 'removed' => removed,
      'detected_at' => detected_at.iso8601, 'first_detected_at' => detected_at.iso8601 }
  end

  def parity(change_hash, board_rows = rows)
    described_class.new(season:, summary: summary_of(board_rows), activity_log:, store:, data_dir: tmp_dir).call(change_hash)
  end

  before(:each) do
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
    DataFix::Automation.store!(:auto_calendar, false) # (no calendar wait unless a context asks for it)
  end

  after(:each) do
    FileUtils.rm_rf(tmp_dir)
    FileUtils.rm_f(SeasonBoard::ActivityLog.default_path)
  end

  describe 'the state table (one actionable added row with its own link)' do
    {
      cancelled: true, sql_pending: true, prepare_failed: true, needs_review: true, ready_to_commit: true, in_review: true,
      results_ready: false, structure_ready: false, manifest_pending: false, committed_with_results: true, structure_committed: true,
      crawled_no_manifest: false, archived_unlinked: true, link_not_crawled: false
    }.each do |state, at_parity|
      it "#{state} is #{'not ' unless at_parity}at parity" do
        board = board_row(fin_event_id: '1', state:)
        if state == :manifest_pending
          board = board.with(next_action: SeasonBoard::NextAction.new(kind: :extract_manifest, params: { fin_event_id: '1', pdf_path: '/x/m.pdf' }))
        end
        result = parity(change(added: [change_row('1')]), [board])
        expect(result.actionable.size).to eq(1)
        expect(result.actionable.first.at_parity?).to be(at_parity)
        expect(result.reached?).to be(at_parity)
      end
    end

    it 'covers every board state' do
      expect(SeasonBoard::StateResolver::STATES - described_class::SETTLED_STATES - described_class::PREPARE_STATES)
        .to match_array(%i[manifest_pending link_not_crawled])
    end

    it 'gives the reason of a row not at parity' do
      reasons = %i[results_ready structure_ready crawled_no_manifest link_not_crawled].map do |state|
        parity(change(added: [change_row('1')]), [board_row(fin_event_id: '1', state:)]).pending.first.reason
      end
      expect(reasons).to eq(%i[waiting_prepare waiting_prepare waiting_prepare waiting_crawl])
    end
  end

  describe 'switches and operator holds' do
    it 'hands a results-ready row to the operator with auto-prepare off, or when held' do
      result = parity(change(added: [change_row('1')]), [board_row(fin_event_id: '1', state: :results_ready, flags: [:prepare_held])])
      expect(result).to be_reached
      DataFix::Automation.store!(:auto_prepare, false)
      expect(parity(change(added: [change_row('1')]), [board_row(fin_event_id: '1', state: :results_ready)])).to be_reached
    end

    it 'hands a pending manifest to the operator once its automatic extraction gave up (or with auto-extract off)' do
      board = board_row(fin_event_id: '1', state: :manifest_pending)
              .with(next_action: SeasonBoard::NextAction.new(kind: :extract_manifest, params: { fin_event_id: '1', pdf_path: '/x/m.pdf' }))
      expect(parity(change(added: [change_row('1')]), [board]).pending.first.reason).to eq(:waiting_extract)
      FactoryBot.create_list(:ops_pipeline_run, 3, kind: 'extract', subject_key: 'm.pdf', origin: 'auto', status: 'failed')
      expect(parity(change(added: [change_row('1')]), [board])).to be_reached
    end

    it 'leaves a row with a not-yet-linked local meeting on its dates to the operator' do
      result = parity(change(added: [change_row('1')]), [board_row(fin_event_id: '1', state: :link_not_crawled, flags: [:possible_unlinked_meeting])])
      expect(result).to be_reached
    end
  end

  describe 'busy and failing rows' do
    it 'is never at parity while a job works on the row, with the kind of job as the reason' do
      activity_log.queue!('1', kind: :crawl, origin: :auto)
      activity_log.queue!('2', kind: :prepare, origin: :auto)
      board = [board_row(fin_event_id: '1', state: :link_not_crawled, busy: true), board_row(fin_event_id: '2', state: :results_ready, busy: true)]
      result = parity(change(added: [change_row('1'), change_row('2')]), board)
      expect(result.pending.map(&:reason)).to eq(%i[crawling preparing])
    end

    it 'keeps a row whose crawl failed not at parity' do
      result = parity(change(added: [change_row('1')]), [board_row(fin_event_id: '1', state: :link_not_crawled, flags: [:crawl_failed])])
      expect(result.pending.first.reason).to eq(:crawl_failed)
    end

    it 'keeps a changed row missing from the board not at parity' do
      expect(parity(change(added: [change_row('9')]), []).pending.first.reason).to eq(:not_on_board)
    end
  end

  describe 'rows adopting their link from the Eventi calendar' do
    let(:adopted) { board_row(fin_event_id: '5', state: :link_not_crawled, flags: [:link_adopted]) }

    it 'are actionable (matched by key) and not at parity until crawled' do
      result = parity(change(added: [change_row('5', url: '')]), [adopted])
      expect(result.actionable.map(&:fin_event_id)).to eq(['5'])
      expect(result.pending.first.reason).to eq(:waiting_crawl)
    end

    it 'count as handed to the operator once their unattended crawls gave up (3 failures in a row)' do
      3.times { Ops.record_event!(kind: 'board.crawl_failed', actor: 'job', subject_type: 'fin_event', subject_key: '5', data: { 'message' => 'x' }) }
      expect(parity(change(added: [change_row('5', url: '')]), [adopted.with(flags: %i[crawl_failed link_adopted])])).to be_reached
    end
  end

  describe "a 'with_results' row already committed" do
    let(:board) { [board_row(fin_event_id: '3', state: :structure_committed)] }
    let(:with_results) { change(with_results: [change_row('3')]) }

    it 'waits for a crawl ended done after the first detection' do
      expect(parity(with_results, board).pending.first.reason).to eq(:waiting_recrawl)
      travel_to(detected_at - 1.hour) do
        activity_log.queue!('3', kind: :crawl, origin: :auto)
        activity_log.finish!('3', kind: :crawl, status: :done)
      end
      expect(parity(with_results, board)).not_to be_reached
      activity_log.queue!('3', kind: :crawl, origin: :auto)
      activity_log.finish!('3', kind: :crawl, status: :failed)
      expect(parity(with_results, board)).not_to be_reached
      activity_log.queue!('3', kind: :crawl, origin: :auto)
      activity_log.finish!('3', kind: :crawl, status: :done)
      expect(parity(with_results, board)).to be_reached
    end
  end

  describe 'a row crawled done for its URL but still not crawled (its files gone since, 0.10.103)' do
    it 'is handed to the operator: the automation never crawls the same URL again' do
      board = board_row(fin_event_id: '1', state: :link_not_crawled)
      activity_log.queue!('1', kind: :crawl, origin: :auto, url: board.url)
      activity_log.finish!('1', kind: :crawl, status: :done)
      expect(parity(change(added: [change_row('1')]), [board])).to be_reached
      activity_log.queue!('1', kind: :crawl, origin: :auto, url: 'https://www.federnuoto.it/old#/risultati/1:old.html')
      activity_log.finish!('1', kind: :crawl, status: :done)
      expect(parity(change(added: [change_row('1')]), [board]).pending.first.reason).to eq(:waiting_crawl)
    end
  end

  describe "a 'with_results' row and its own detection time (0.10.103)" do
    def with_results_change(row_detected)
      change(with_results: [change_row('3')]).merge('row_detected_at' => { 'with_results' => { 'k-3' => row_detected.iso8601 } })
    end

    it 'needs a crawl ended done after ITS detection, not after the first detection of the change' do
      board = [board_row(fin_event_id: '3', state: :results_ready)]
      row_detected = 10.minutes.ago
      travel_to(30.minutes.ago) do
        activity_log.queue!('3', kind: :crawl, origin: :auto)
        activity_log.finish!('3', kind: :crawl, status: :done)
      end
      expect(parity(with_results_change(row_detected), board).pending.first.reason).to eq(:waiting_recrawl)
      activity_log.reload!.queue!('3', kind: :crawl, origin: :auto)
      activity_log.finish!('3', kind: :crawl, status: :done)
      expect(parity(with_results_change(row_detected), board).pending.first.reason).to eq(:waiting_prepare)
    end

    it 'hands a source in review to the operator, listed in the notice' do
      result = parity(with_results_change(10.minutes.ago), [board_row(fin_event_id: '3', state: :needs_review)])
      expect(result).to be_reached
      expect(result.notices.results_in_review.map(&:key)).to eq(['k-3'])
      expect(result.notices.to_h['results_in_review'].pluck('name')).to eq(['Meeting 3'])
    end
  end

  describe 'notices' do
    before(:each) do
      store.update do
        { 'rows' => [{ 'key' => 'renamed', 'name' => 'Same meeting', 'url' => change_row('7')['url'], 'date' => '01/12', 'year' => '2026', 'place' => 'Y' }] }
      end
    end

    it 'lists the rows without a link and the true removals (a rename is no removal); nothing actionable reaches parity' do
      gone = { 'key' => 'gone', 'name' => 'Gone', 'url' => change_row('6')['url'], 'date' => '02/12', 'year' => '2026', 'place' => 'Z' }
      renamed = { 'key' => 'old-name', 'name' => 'Old name', 'url' => change_row('7')['url'], 'date' => '01/12', 'year' => '2026', 'place' => 'Y' }
      result = parity(change(added: [change_row('8', url: '')], removed: [gone, renamed]))
      expect(result.actionable).to be_empty
      expect(result.notices.without_link.map(&:key)).to eq(['k-8'])
      expect(result.notices.removed.pluck('key')).to eq(['gone'])
      expect(result.notices.text_only).to be false
      expect(result).to be_reached
    end

    it 'tells a text-only change' do
      result = parity(change)
      expect(result.notices.text_only).to be true
      expect(result.notices).to be_any
    end
  end

  describe 'rows without a link while the Eventi calendar crawl may lend one' do
    before(:each) { DataFix::Automation.store!(:auto_calendar, true) }

    it 'wait for the calendar crawl, then become notices once it ended' do
      result = parity(change(added: [change_row('8', url: '')]))
      expect(result.awaiting_calendar.map(&:key)).to eq(['k-8'])
      expect(result.notices.without_link).to be_empty
      expect(result).not_to be_reached
      activity_log.queue!(calendar_key, kind: :crawl, origin: :auto)
      activity_log.finish!(calendar_key, kind: :crawl, status: :failed, message: 'no new calendar file')
      result = parity(change(added: [change_row('8', url: '')]))
      expect(result.awaiting_calendar).to be_empty
      expect(result.notices.without_link.map(&:key)).to eq(['k-8'])
      expect(result).to be_reached
    end

    it 'shows the calendar crawl queued or running' do
      activity_log.queue!(calendar_key, kind: :crawl, origin: :auto)
      expect(parity(change(added: [change_row('8', url: '')])).calendar).to eq(:queued)
    end

    it "measure the wait from the row's own detection, not from the latest one" do
      late_change = change(added: [change_row('8', url: '')])
                    .merge('row_detected_at' => { 'added' => { 'k-8' => (described_class::CALENDAR_WAIT + 1.hour).ago.iso8601 } })
      expect(parity(late_change).awaiting_calendar).to be_empty
    end

    it 'stop waiting after CALENDAR_WAIT' do
      pending_change = change(added: [change_row('8', url: '')])
      travel(described_class::CALENDAR_WAIT + 1.minute) do
        expect(parity(pending_change).awaiting_calendar).to be_empty
      end
    end
  end

  describe '.decision' do
    before(:each) { allow(SeasonBoard::Snapshot).to receive(:fetch).and_return(summary_of(rows)) }

    let(:rows) { [board_row(fin_event_id: '1', state: :link_not_crawled), board_row(fin_event_id: '2', state: :needs_review)] }

    def decision(change_hash) = described_class.decision(change_hash, season:).first

    it 'raises the alert while an actionable row is not at parity, and whenever the master switch is off' do
      expect(decision(change(added: [change_row('1')]))).to eq(:alert)
      DataFix::Automation.store!(:enabled, false)
      expect(decision(change(added: [change_row('8', url: '')]))).to eq(:alert)
    end

    it 'acknowledges at once a change already at parity, or with nothing to crawl' do
      expect(decision(change(added: [change_row('2')]))).to eq(:parity)
      expect(decision(change(added: [change_row('8', url: '')]))).to eq(:nothing_to_crawl)
    end

    it 'waits silently for the calendar crawl when only rows without a link changed' do
      DataFix::Automation.store!(:auto_calendar, true)
      expect(decision(change(added: [change_row('8', url: '')]))).to eq(:wait)
    end

    it 'fails safe: the alert when the board cannot be read' do
      allow(SeasonBoard::Snapshot).to receive(:fetch).and_raise(RuntimeError, 'locked')
      expect(decision(change(added: [change_row('1')]))).to eq(:alert)
      expect(described_class.decision(change, season: nil).first).to eq(:alert)
    end
  end

  it 'gives the progress payload of the alert' do
    activity_log.queue!('1', kind: :crawl, origin: :auto)
    board = [board_row(fin_event_id: '1', state: :link_not_crawled, busy: true), board_row(fin_event_id: '2', state: :ready_to_commit)]
    payload = parity(change(added: [change_row('1'), change_row('2')]), board).progress_payload(digest: 'd1')
    expect(payload).to include('digest' => 'd1', 'automation' => true, 'actionable' => 2, 'at_parity' => 1, 'reached' => false)
    expect(payload['pending']).to eq([{ 'key' => 'k-1', 'name' => 'Meeting 1', 'date' => '08/11', 'year' => '2026', 'place' => 'X',
                                        'section' => 'added', 'fin_event_id' => '1', 'reason' => 'crawling' }])
  end

  it 'returns nil without a change, a season or a board summary' do
    expect(parity(nil)).to be_nil
    expect(described_class.new(season: nil, summary: summary_of([])).call(change)).to be_nil
    allow(SeasonBoard::Snapshot).to receive(:fetch).and_return(nil)
    expect(described_class.new(season:).call(change)).to be_nil
  end
end
