# frozen_string_literal: true

require 'rails_helper'
require_relative 'disk_fixtures'
require_relative 'board_rows'

RSpec.describe SeasonBoard::Snapshot do
  include SeasonBoardDiskFixtures
  include SeasonBoardRows
  include ActiveSupport::Testing::TimeHelpers

  let(:data_dir) { Dir.mktmpdir('season-board-snapshot') }
  let(:season) { FactoryBot.build_stubbed(:season, id: 262, begin_date: Date.new(2026, 9, 1), end_date: Date.new(2027, 8, 31)) }
  let(:rows) do
    [
      board_row(fin_event_id: '1', state: :link_not_crawled, action: :crawl, busy: true, flags: [:busy]),
      board_row(fin_event_id: '2', state: :committed_with_results, last_date: Date.current - 30),
      board_row(fin_event_id: '3', state: :link_not_crawled, action: :crawl)
    ]
  end
  let(:builder) { instance_double(SeasonBoard::Builder, call: board_result(rows)) }
  let(:activity_path) { SeasonBoard::ActivityLog.default_path }

  before(:each) do
    allow(SeasonBoard::DiskIndex).to receive(:default_data_dir).and_return(Pathname.new(data_dir))
    FileUtils.rm_f(activity_path)
  end

  after(:each) do
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_f(activity_path)
  end

  def fetch
    described_class.fetch(season, builder:)
  end

  # Moves the mtime of an existing path 1 hour back, so that the next change is always seen
  # (whatever the file system timestamp granularity).
  def age!(path)
    File.utime(1.hour.ago.to_time, 1.hour.ago.to_time, path.to_s)
  end

  it 'stores the summary under season_board:<season_id>' do
    expect(described_class.key_for(season)).to eq('season_board:262')
    expect(described_class.key_for(262)).to eq('season_board:262')
    summary = fetch
    expect(summary).to be_stored
    expect(Ops::Snapshot.read('season_board:262').payload['fingerprint']).to eq(summary.fingerprint)
  end

  describe '.fetch' do
    it 'does not rebuild when nothing changed' do
      first = fetch
      second = fetch
      expect(builder).to have_received(:call).once
      expect(second.rows.map(&:fin_event_id)).to eq(first.rows.map(&:fin_event_id))
    end

    it 'rebuilds when a file is added to results.new/<season>' do
      folder = File.dirname(write_file('results.new', 'old.json', '{}'))
      age!(folder)
      fetch
      write_file('results.new', 'new-meeting.json', '{}')
      fetch
      expect(builder).to have_received(:call).twice
    end

    it 'rebuilds after an activity log write' do
      log = SeasonBoard::ActivityLog.new
      log.queue!('3', kind: :crawl, origin: :auto, url: 'https://x/y#/risultati/3:a.html')
      age!(activity_path)
      fetch
      log.start!('3', kind: :crawl)
      fetch
      expect(builder).to have_received(:call).twice
    end

    it 'rebuilds after a Phase 6 commit event, not after an unrelated event' do
      fetch
      Ops.record_event!(kind: 'push.uploaded', level: 'success')
      fetch
      expect(builder).to have_received(:call).once
      Ops.record_event!(kind: 'datafix.committed', level: 'success', actor: 'operator', season_id: 262)
      fetch
      expect(builder).to have_received(:call).twice
    end

    it 'rebuilds after a staging purge or a calendar link event' do
      fetch
      Ops.record_event!(kind: 'datafix.purged', actor: 'operator')
      fetch
      Ops.record_event!(kind: 'board.calendar_linked', level: 'success', actor: 'operator')
      fetch
      expect(builder).to have_received(:call).exactly(3).times
    end

    it 'rebuilds a summary older than MAX_AGE even with the same fingerprint' do
      fetch
      travel(9.minutes) { fetch }
      expect(builder).to have_received(:call).once
      travel(11.minutes) { fetch }
      expect(builder).to have_received(:call).twice
    end

    it 'rebuilds after .invalidate!' do
      fetch
      expect(described_class.invalidate!(season)).to be true
      expect(described_class.invalidate!(262)).to be false
      fetch
      expect(builder).to have_received(:call).twice
    end

    it 'rebuilds when the stored fingerprint differs' do
      fetch
      record = Ops::Snapshot.read('season_board:262')
      record.update!(payload: record.payload.merge('fingerprint' => 'other'))
      fetch
      expect(builder).to have_received(:call).twice
    end

    it 'returns nil for a nil season' do
      expect(described_class.fetch(nil, builder:)).to be_nil
    end

    context 'without the ops DB' do
      before(:each) { allow(Ops).to receive(:available?).and_return(false) }

      it 'builds live every time and stores nothing' do
        summary = fetch
        fetch
        expect(builder).to have_received(:call).twice
        expect(summary).not_to be_stored
        expect(summary.rows.size).to eq(3)
        expect(summary.fingerprint).to be_nil
        expect(described_class.read(season)).to be_nil
        expect(described_class.invalidate!(season)).to be false
      end
    end
  end

  describe '.build!' do
    it 'returns the Builder::Result and stores its summary' do
      result = described_class.build!(season, builder:)
      expect(result).to be_a(SeasonBoard::Builder::Result)
      expect(described_class.read(season).rows.map(&:fin_event_id)).to eq(%w[1 2 3])
    end

    it 'still returns the result when the store fails' do
      allow(Ops::Snapshot).to receive(:write!).and_raise(ActiveRecord::StatementInvalid, 'disk I/O error')
      expect(described_class.build!(season, builder:).rows.size).to eq(3)
      expect(described_class.read(season)).to be_nil
    end
  end

  describe 'the summary' do
    let(:today) { Date.new(2026, 11, 12) }
    let(:db_index) do
      calendar = SeasonBoard::DbIndex::CalendarInfo.new(
        id: 1700, fin_event_id: '150092', meeting_id: 19_000, meeting_code: 'm', meeting_name: 'Local', meeting_place: nil,
        scheduled_date: '2026-10-04', year: '2026', month: 'Oct', cancelled: false, results_link: nil,
        meeting: SeasonBoard::DbIndex::MeetingInfo.new(id: 19_000, description: 'Local', code: 'm', header_date: Date.new(2026, 10, 4),
                                                       cancelled: false, results_acquired: true, manifest: true, mir_count: 10, mrr_count: 0)
      )
      instance_double(SeasonBoard::DbIndex, duplicate_fin_event_ids: [], orphans: []).tap do |dbl|
        allow(dbl).to receive(:calendar_for) { |fin_id| fin_id.to_s == '150092' ? calendar : nil }
      end
    end
    let(:fin_rows) do
      [
        { 'year' => '2026', 'date' => '08/11', 'name' => 'In review', 'place' => 'Roma', 'url' => results_url('150091'), 'info' => '', 'key' => 'k1' },
        { 'year' => '2026', 'date' => '04/10', 'name' => 'Done', 'place' => 'Bari', 'url' => results_url('150092'), 'info' => '', 'key' => 'k2' },
        { 'year' => '2026', 'date' => '20/12', 'name' => 'No link', 'place' => 'Pisa', 'url' => '', 'info' => '', 'key' => 'k3' }
      ]
    end
    let(:real_builder) do
      SeasonBoard::Builder.new(
        season:, rows: fin_rows, disk_index: SeasonBoard::DiskIndex.new(season_id: 262, data_dir:), db_index:,
        activity_log: SeasonBoard::ActivityLog.new(path: File.join(data_dir, 'season-board.json')), today:,
        snapshot_checked_at: Time.zone.local(2026, 11, 12, 9, 30)
      )
    end
    let(:summary) { travel_to(Time.zone.local(2026, 11, 12, 10, 0)) { described_class.fetch(season, builder: real_builder) } }

    before(:each) do
      write_json('results.new', 'meeting-a.json', lt2_hash(fin_id: '150091', results: true))
      write_json('results.new', 'meeting-a-lt4-phase2.json', { 'data' => {} })
      write_json('results.new', 'stray-meeting.json', lt2_hash(results: true))
      write_file('results.new', '0007-calendar_link-1700-150092.sql', '-- link')
    end

    def plain?(value)
      case value
      when Hash then value.all? { |key, val| key.is_a?(String) && plain?(val) }
      when Array then value.all? { |val| plain?(val) }
      else [String, Integer, TrueClass, FalseClass, NilClass].any? { |klass| value.is_a?(klass) }
      end
    end

    # 0.10.102
    it 'carries the adopted links and the pending sources whose FIN id is on no row (format 5)' do
      link = SeasonBoard::CalendarIndex::Link.new(url: results_url('150300'), fin_event_id: '150300', name: 'Pisa meeting',
                                                  calendar_date: Date.new(2026, 11, 10), file_name: '20261110-262-2-FIN-calendar.csv')
      calendar_index = instance_double(SeasonBoard::CalendarIndex, warnings: [])
      allow(calendar_index).to receive(:link_for) { |row, _rows| row['key'] == 'k3' ? link : nil }
      write_json('results.new', 'lignano.json', lt2_hash(fin_id: '150244'))
      builder = SeasonBoard::Builder.new(
        season:, rows: fin_rows, disk_index: SeasonBoard::DiskIndex.new(season_id: 262, data_dir:), db_index:,
        activity_log: SeasonBoard::ActivityLog.new(path: File.join(data_dir, 'season-board.json')), today:, calendar_index:
      )
      stored = travel_to(Time.zone.local(2026, 11, 12, 10, 0)) { described_class.fetch(season, builder:) }
      expect(stored).to be_stored
      row = stored.row_for('150300')
      expect(row).to have_attributes(url: results_url('150300'), flags: [:link_adopted], adopted_link: link, state: :link_not_crawled)
      expect(SeasonBoard::RowFlags.tooltip(:link_adopted, row)).to include('10/11/2026')
      expect(stored.off_board_sources.map { |source| [source.fin_event_id, source.base, source.pending] }).to eq([%w[150244 lignano] + [:source]])
      expect(stored.unmatched_sources.map(&:fin_event_id)).to eq([nil])
    end

    it 'stores only plain JSON values' do
      expect(plain?(summary.payload)).to be true
      expect(plain?(Ops::Snapshot.read('season_board:262').payload)).to be true
    end

    it 'has the state counts, the hidden counts and the times' do
      expect(summary.state_counts).to eq(in_review: 1, committed_with_results: 1, not_linked: 1)
      expect(summary.unlinked_count).to eq(1)
      expect(summary.done_count).to eq(1)
      expect(summary.snapshot_checked_at).to eq(Time.zone.local(2026, 11, 12, 9, 30))
      expect(summary.built_at).to eq(Time.zone.local(2026, 11, 12, 10, 0))
      expect(summary.season_id).to eq(262)
    end

    it 'has the rows with their next action (kind & params), busy flag and flags' do
      row = summary.row_for('150091')
      expect(row).to have_attributes(name: 'In review', state: :in_review, state_detail: { phase: 2 }, busy: false, flags: [],
                                     last_date: Date.new(2026, 11, 8), url: results_url('150091'))
      expect(row.next_action).to eq(SeasonBoard::NextAction.new(kind: :resume_review,
                                                                params: { fin_event_id: '150091', file_path: path_for('results.new', 'meeting-a.json'),
                                                                          phase: 2 }))
      expect(row.action?(:resume_review)).to be true
      expect(summary.row_for('150092')).to have_attributes(state: :committed_with_results, next_action: nil, meeting_id: 19_000,
                                                           calendar_id: 1700)
      expect(summary.rows_in(:not_linked).map(&:name)).to eq(['No link'])
    end

    it 'has the unmatched sources, the board SQL scripts and the warnings' do
      expect(summary.unmatched_sources.size).to eq(1)
      expect(summary.unmatched_sources.first).to have_attributes(
        base: 'stray-meeting', pending: :source, review_path: path_for('results.new', 'stray-meeting.json'),
        paths: [path_for('results.new', 'stray-meeting.json')]
      )
      expect(summary.board_sql_paths).to eq([path_for('results.new', '0007-calendar_link-1700-150092.sql')])
      expect(summary.warnings).to eq([])
    end

    it 'carries the pipeline state of an unmatched (non-FIN) source prepared from the Sources page (phase 15)' do
      expect(summary.unmatched_sources.first).to have_attributes(pipeline_state: nil, pipeline_detail: {})
      described_class.invalidate!(262)
      source = FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'stray-meeting', stage: 'needs_review', review_phase: 3,
                                                       review_count: 2, source_path: path_for('results.new', 'stray-meeting.json'))
      (1..5).each { |phase| FactoryBot.create(:ops_phase_verdict, pipeline_source: source, phase:, checked_at: 1.minute.from_now) }
      fresh_builder = SeasonBoard::Builder.new(
        season:, rows: fin_rows, disk_index: SeasonBoard::DiskIndex.new(season_id: 262, data_dir:), db_index:,
        activity_log: SeasonBoard::ActivityLog.new(path: File.join(data_dir, 'season-board.json')), today:
      )
      travel_to(Time.zone.local(2026, 11, 12, 10, 5)) { described_class.build!(season, builder: fresh_builder) }
      rebuilt = described_class.read(season)
      expect(rebuilt.unmatched_sources.first).to have_attributes(pipeline_state: :needs_review, pipeline_detail: { step: 3, count: 2, blocked: false })
      expect(plain?(rebuilt.payload)).to be true
    end

    it 'gives the action targets through SeasonBoard::ActionPaths' do
      target = SeasonBoard::ActionPaths.target_for(summary.row_for('150091').next_action)
      expect(target.http_method).to eq(:get)
      expect(target.path).to eq(Rails.application.routes.url_helpers.review_teams_path(file_path: path_for('results.new', 'meeting-a.json'),
                                                                                       phase2_v2: 1))
    end
  end

  describe SeasonBoard::Snapshot::Fingerprint do
    let(:meeting) { FactoryBot.create(:meeting) }

    it 'changes when a calendar of the season is added' do
      before = described_class.digest(meeting.season_id)
      FactoryBot.create(:calendar, meeting:)
      expect(described_class.digest(meeting.season_id)).not_to eq(before)
    end

    it 'covers the five season folders scanned by the DiskIndex' do
      components = described_class.new(season_id: 262, data_dir:).components
      expect(components['folders'].keys).to eq(%w[results.new results.done results.sent manifests manifests.done])
    end

    # 0.10.102: the adopted links come from the newest one (SeasonBoard::CalendarIndex)
    it "changes with the original FIN 'Eventi' calendar CSVs of calendar.new / calendar.done only" do
      digest = -> { described_class.digest(262, data_dir:) }
      first = digest.call
      write_file('calendar.new', '20261125-262-3-FIN-current-meetings.csv', 'x')
      write_file('calendar.new', '20261125-262-2-FIN-calendar-sel-20261125-110734-892.csv', 'x')
      expect(digest.call).to eq(first)

      csv = write_file('calendar.new', '20261125-262-2-FIN-calendar.csv', 'x')
      added = digest.call
      expect(added).not_to eq(first)
      File.utime(1.hour.ago.to_time, 1.hour.ago.to_time, csv)
      expect(digest.call).not_to eq(added)

      FileUtils.mkdir_p(File.dirname(path_for('calendar.done', 'x')))
      FileUtils.mv(csv, path_for('calendar.done', '20261125-262-2-FIN-calendar.csv'))
      expect(described_class.new(season_id: 262, data_dir:).components['eventi_calendars'].map(&:first))
        .to eq(['calendar.done/20261125-262-2-FIN-calendar.csv'])
    end
  end
end
