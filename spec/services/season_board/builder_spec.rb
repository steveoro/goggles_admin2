# frozen_string_literal: true

require 'rails_helper'
require 'csv'
require_relative 'disk_fixtures'
require_relative 'builder_state_table'

RSpec.describe SeasonBoard::Builder do
  include SeasonBoardDiskFixtures
  include ActiveSupport::Testing::TimeHelpers

  let(:data_dir) { Dir.mktmpdir('season-board-builder') }
  let(:today) { Date.new(2026, 11, 12) }
  let(:season) { FactoryBot.build_stubbed(:season, id: 262, begin_date: Date.new(2026, 9, 1), end_date: Date.new(2027, 8, 31)) }
  let(:disk_index) { SeasonBoard::DiskIndex.new(season_id: 262, data_dir:) }
  let(:activity_log) { SeasonBoard::ActivityLog.new(path: File.join(data_dir, 'season-board.json')) }
  let(:calendars) { {} }
  let(:db_index) do
    instance_double(SeasonBoard::DbIndex, duplicate_fin_event_ids: [], orphans: []).tap do |dbl|
      allow(dbl).to receive(:calendar_for) { |fin_id| calendars[fin_id.to_s] }
    end
  end

  after(:each) { FileUtils.rm_rf(data_dir) }

  def fin_id = '150091'

  def fin_row(date: '08/11', year: '2026', info: '', url: :default)
    url = results_url(fin_id) if url == :default
    { 'year' => year, 'date' => date, 'name' => "Meeting #{fin_id}", 'place' => 'Somewhere',
      'url' => url.to_s, 'info' => info, 'key' => "#{year} | #{date} | Meeting #{fin_id} | Somewhere" }
  end

  # meeting_attrs: results_acquired, mir_count, mrr_count
  def link!(meeting: true, cancelled: false, meeting_cancelled: false, **meeting_attrs)
    meeting_info = if meeting
                     SeasonBoard::DbIndex::MeetingInfo.new(
                       id: 19_000, description: 'Local meeting', code: 'localmeeting', header_date: Date.new(2026, 11, 8),
                       cancelled: meeting_cancelled, results_acquired: false, manifest: true, mir_count: 0, mrr_count: 0, **meeting_attrs
                     )
                   end
    calendars[fin_id] = SeasonBoard::DbIndex::CalendarInfo.new(
      id: 1700, fin_event_id: fin_id, meeting_id: 19_000, meeting_code: 'localmeeting', meeting_name: 'Local meeting',
      meeting_place: 'Somewhere', scheduled_date: '8', year: '2026', month: 'Nov', cancelled:, results_link: nil,
      meeting: meeting_info
    )
  end

  # Ops pipeline facts of the base 'm' (phase 10): a source row in +stage+ with five fresh verdicts and, optionally, a
  # last prepare run.
  # (+attributes+: review_phase, review_count, new_teams_count, new_swimmers_count...)
  def pipeline!(stage:, run_status: nil, **attributes)
    source = FactoryBot.create(:ops_pipeline_source, season_id: 262, base: 'm', source_path: path_for('results.new', 'm-lt4.json'),
                                                     stage:, db_generation: DataFix::Pipeline.db_generation, **attributes)
    (1..5).each { |phase| FactoryBot.create(:ops_phase_verdict, pipeline_source: source, phase:, checked_at: 1.second.from_now) }
    return source unless run_status

    FactoryBot.create(:ops_pipeline_run, pipeline_source: source, subject_key: 'm', kind: 'prepare', origin: 'auto', status: run_status,
                                         phase: 3, error: 'boom', finished_at: 2.seconds.from_now)
    source
  end

  # A results source 'm' with phase files 1-3 (as left by a prepare).
  def prepared_files!
    write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id, results: true))
    write_json('results.new', 'm-lt4.json', lt4_hash(results: true))
    (1..3).each { |phase| write_json('results.new', "m-lt4-phase#{phase}.json", {}) }
  end

  def build(rows = [fin_row], **options)
    described_class.new(season:, rows:, disk_index:, db_index:, activity_log:, today:, **options).call
  end

  def board_row(row = fin_row)
    build([row]).rows.first
  end

  describe 'state table' do
    SeasonBoardBuilderStateTable::ROWS.each do |entry|
      it "#{entry[0]} => #{entry[3]} / #{entry[4].inspect}" do
        _description, setup, overrides, state, action_kind, params = entry
        instance_exec(&setup)
        row = board_row(fin_row(**overrides))
        expect(row.state).to eq(state)
        expect(row.next_action&.kind).to eq(action_kind)
        next if action_kind.nil?

        expected = params.respond_to?(:call) ? instance_exec(&params) : params
        expect(row.next_action.params).to include(fin_event_id: (overrides[:url] == '' ? nil : fin_id), **expected.to_h)
      end
    end

    it 'covers every state & every action' do
      expect(SeasonBoardBuilderStateTable::ROWS.to_set { |entry| entry[3] }).to eq(described_class::STATES.to_set)
      expect(SeasonBoardBuilderStateTable::ROWS.filter_map { |entry| entry[4] }.to_set).to eq(described_class::ACTIONS.to_set)
    end
  end

  describe 'state details & flags' do
    it 'reports the phase number for :in_review' do
      write_json('results.new', 'm-lt4.json', lt4_hash(fin_id: fin_id, results: true))
      write_json('results.new', 'm-lt4-phase3.json', {})
      expect(board_row.state_detail).to eq(phase: 3)
    end

    it 'flags a pending manifest PDF that the state does not ask to extract' do
      link!
      write_json('results.done', 'm.json', lt2_hash(fin_id: fin_id))
      write_file('manifests', 'manifest-m.pdf')
      expect(board_row.flags).to include(:manifest_pdf_pending)
    end

    it 'flags a redundant result-free crawl for an already linked meeting' do
      link!
      write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id))
      row = board_row
      expect(row.state).to eq(:structure_committed)
      expect(row.flags).to include(:redundant_result_free_source)
    end

    it 'flags missing meetings, pushed SQL, multiple sources & dates out of season' do
      link!(meeting: false)
      write_json('results.new', 'a.json', lt2_hash(fin_id: fin_id, results: true))
      write_json('results.new', 'b.json', lt2_hash(fin_id: fin_id))
      write_file('results.sent', '0001-a-lt4.sql')
      row = board_row(fin_row(year: '2025'))
      expect(row.flags).to include(:missing_meeting, :pushed, :multiple_sources, :outside_season)
    end

    describe ':possible_unlinked_meeting' do
      def orphan(scheduled_date:, fin_event_id: nil, cancelled: false)
        SeasonBoard::DbIndex::CalendarInfo.new(
          id: 1800, fin_event_id:, meeting_id: nil, meeting_code: 'x', meeting_name: 'X', meeting_place: nil,
          scheduled_date:, year: '2026', month: '11', cancelled:, results_link: nil, meeting: nil
        )
      end

      it 'flags a :link_not_crawled row having a link candidate calendar within its dates (no extra DB query)' do
        allow(db_index).to receive(:orphans).and_return([orphan(scheduled_date: '2026-11-09')])
        row = board_row(fin_row(date: '08-09/11'))
        expect(row.state).to eq(:link_not_crawled)
        expect(row.flags).to include(:possible_unlinked_meeting)
        expect(db_index).to have_received(:orphans).once
      end

      it 'ignores candidates on other dates, cancelled ones and orphans already carrying a FIN id' do
        allow(db_index).to receive(:orphans).and_return(
          [orphan(scheduled_date: '2026-11-10'), orphan(scheduled_date: '2026-11-08', cancelled: true),
           orphan(scheduled_date: '2026-11-08', fin_event_id: '150999'), orphan(scheduled_date: '8')]
        )
        expect(board_row(fin_row(date: '08/11')).flags).not_to include(:possible_unlinked_meeting)
      end

      it 'does not flag rows in other states' do
        allow(db_index).to receive(:orphans).and_return([orphan(scheduled_date: '2026-11-08')])
        link!
        expect(board_row.flags).not_to include(:possible_unlinked_meeting)
      end
    end

    it 'exposes the board SQL scripts awaiting push' do
      sql = write_file('results.new', '0007-calendar_link-1700-150091.sql')
      expect(build.pending_board_sql_paths).to eq([sql])
    end

    it 'flags unparsable dates' do
      expect(board_row(fin_row(date: 'TBD')).flags).to include(:unparsable_date)
    end

    it 'fills the meeting columns from the linked calendar' do
      link!(mir_count: 3, mrr_count: 1)
      expect(board_row).to have_attributes(
        fin_event_id: fin_id, calendar_id: 1700, meeting_id: 19_000, meeting_description: 'Local meeting',
        mir_count: 3, mrr_count: 1, results_count: 4, first_date: Date.new(2026, 11, 8), last_date: Date.new(2026, 11, 8),
        name: "Meeting #{fin_id}", place: 'Somewhere', year: '2026', date_text: '08/11'
      )
    end
  end

  describe 'activity overlay' do
    it 'marks the row busy without changing its state' do
      activity_log.queue!(fin_id, kind: :crawl, origin: :auto)
      row = board_row
      expect(row.state).to eq(:link_not_crawled)
      expect(row.next_action.kind).to eq(:crawl)
      expect(row).to be_busy
      expect(row.flags).to include(:busy)
      expect(row.activity[:crawl]).to be_queued
    end

    it 'is not busy on a stale running entry & flags failures' do
      travel_to(2.hours.ago) { activity_log.start!(fin_id, kind: :crawl, origin: :auto) }
      expect(board_row).not_to be_busy
      activity_log.finish!(fin_id, kind: :extract, status: :failed, message: 'boom')
      expect(board_row.flags).to include(:extract_failed)
    end

    # 0.10.99: busy (POST buttons off) vs locked (review links off too).
    it 'is busy but not locked while a prepare is only queued (also without a log entry), locked while a job works' do
      prepared_files!
      source = pipeline!(stage: 'needs_review', review_phase: 2, run_status: 'queued')
      row = board_row
      expect(row).to have_attributes(state: :needs_review, busy?: true, locked?: false)

      source.acquire_lease!('job:abc', ttl: 5.minutes)
      expect(board_row).to have_attributes(busy?: true, locked?: true)
      source.release_lease!('job:abc')
      Ops::PipelineRun.update_all(status: 'done') # rubocop:disable Rails/SkipsModelValidations
      activity_log.start!(fin_id, kind: :crawl, origin: :auto)
      expect(board_row).to have_attributes(busy?: true, locked?: true)
    end

    it 'flags a crawl file (LT2) newer than the LT4 working copy, informational only (:newer_crawl)' do
      prepared_files!
      pipeline!(stage: 'needs_review', review_phase: 2)
      expect(board_row.flags).not_to include(:newer_crawl)
      File.utime(1.hour.ago.to_time, 1.hour.ago.to_time, path_for('results.new', 'm-lt4.json'))
      row = board_row
      expect(row.flags).to include(:newer_crawl)
      expect(row.state).to eq(:needs_review)
      FileUtils.rm_f(path_for('results.new', 'm-lt4.json'))
      expect(board_row.flags).not_to include(:newer_crawl)
    end

    it 'exposes the active entries for the page strip' do
      activity_log.start!('150555', kind: :extract)
      expect(build.active_activities.map(&:fin_event_id)).to eq(['150555'])
    end
  end

  describe 'result' do
    it 'reads rows & last_checked from the watcher state store when no rows are given' do
      store = FedernuotoWatch::StateStore.new(path: File.join(data_dir, 'watch.json'))
      store.update { { 'last_checked' => '2026-11-12T09:30:00+01:00', 'rows' => [fin_row] } }
      result = described_class.new(season:, disk_index:, db_index:, activity_log:, today:, state_store: store).call
      expect(result.rows.map(&:fin_event_id)).to eq([fin_id])
      expect(result.snapshot_checked_at).to eq(Time.zone.parse('2026-11-12T09:30:00+01:00'))
      expect(result.season).to eq(season)
    end

    it 'warns on an empty snapshot' do
      expect(build([]).warnings).to include(a_string_matching(/snapshot is empty/))
    end

    it 'warns about rows outside the season & duplicated FIN ids' do
      allow(db_index).to receive(:duplicate_fin_event_ids).and_return(['150777'])
      warnings = build([fin_row(year: '2025'), fin_row(date: '09/11')]).warnings
      expect(warnings).to include(a_string_matching(/1 snapshot row\(s\) \(year 2025\) fall outside season 262/))
      expect(warnings).to include(a_string_matching(/150091 appears on more than one snapshot row/))
      expect(warnings).to include(a_string_matching(/150777 is used by more than one calendar row/))
    end

    it 'passes the orphans (computed on the snapshot FIN ids) & the unmatched disk sources' do
      orphan = instance_double(SeasonBoard::DbIndex::CalendarInfo, fin_event_id: '150500')
      allow(db_index).to receive(:orphans).with([fin_id]).and_return([orphan])
      write_json('results.new', 'ficr-lt4.json', lt4_hash(results: true))
      result = build([fin_row, fin_row(url: '')])
      expect(result.orphans).to eq([orphan])
      expect(result.unmatched_sources.map(&:bases)).to eq([['ficr']])
    end
  end

  # 0.10.102 (SeasonBoard::CalendarIndex, read from the 'calendar.new' folder of the DiskIndex data dir)
  describe "links adopted from the FIN 'Eventi' calendar" do
    let(:adopted_id) { '150112' }
    let(:calendar_file) { '20261125-262-2-FIN-calendar.csv' }
    # Nine meetings linked on both pages (the self-check of the CalendarIndex): 1-9 October, FIN ids 150001-150009.
    let(:linked) { (1..9).map { |day| [day, format('1500%02d', day)] } }

    # The 'Eventi' calendar: the linked meetings (+ids+ overriding their FIN ids) plus 'Cagliari' on 22/11.
    def write_eventi(ids = {})
      rows = linked.map { |day, id| [format('2026-10-%02d', day), "City#{day} (XX)", ids.fetch(id, id)] }
      rows << ['2026-11-22', 'Cagliari (CA)', adopted_id]
      text = CSV.generate do |csv|
        csv << %w[startURL date isCancelled name place meetingUrl year]
        rows.each { |date, place, id| csv << [SeasonBoard::CalendarIndex::EVENTI_START_URL, date, 'false', 'Meeting', place, results_url(id), '2026'] }
      end
      write_file('calendar.new', calendar_file, text)
    end

    def linked_rows
      linked.map do |day, id|
        { 'year' => '2026', 'date' => format('%02d/10', day), 'name' => "Riepilogo #{day}", 'place' => "City#{day}",
          'url' => results_url(id), 'info' => '', 'key' => "k-#{id}" }
      end
    end

    def cagliari_row(url: '')
      { 'year' => '2026', 'date' => '22/11', 'name' => '9° Sardinia in Water', 'place' => 'Cagliari', 'url' => url, 'info' => '',
        'key' => '2026 | 22/11 | 9° Sardinia in Water | Cagliari' }
    end

    def adopted_board(rows = linked_rows + [cagliari_row]) = build(rows)

    before(:each) { write_eventi }

    it 'resolves a link-less row with the adopted link, flagged :link_adopted' do
      result = adopted_board
      row = result.rows.last
      expect(row).to have_attributes(fin_event_id: adopted_id, url: results_url(adopted_id), state: :link_not_crawled, flags: [:link_adopted],
                                     key: '2026 | 22/11 | 9° Sardinia in Water | Cagliari', name: '9° Sardinia in Water')
      expect(row.next_action.params).to eq(fin_event_id: adopted_id, url: results_url(adopted_id))
      expect(row.adopted_link).to have_attributes(fin_event_id: adopted_id, calendar_date: Date.new(2026, 11, 25), file_name: calendar_file)
      expect(result.rows.first(9).map(&:flags)).to all(be_empty)
      expect(result.warnings).to eq([])
    end

    it 'matches the files on disk by the adopted FIN id' do
      write_json('results.new', 'cagliari.json', lt2_hash(fin_id: adopted_id, results: true))
      expect(adopted_board.rows.last).to have_attributes(state: :results_ready, flags: [:link_adopted])
    end

    it 'leaves :link_not_crawled after a result-free crawl, as a linked row' do
      write_json('results.new', 'cagliari.json', lt2_hash(fin_id: adopted_id))
      expect(adopted_board.rows.last).to have_attributes(state: :crawled_no_manifest, flags: [:link_adopted])
    end

    it 'shows the manifest to extract of a result-free crawl, as a linked row' do
      write_json('results.new', 'cagliari.json', lt2_hash(fin_id: adopted_id))
      write_file('manifests', 'manifest-cagliari.pdf')
      expect(adopted_board.rows.last).to have_attributes(state: :manifest_pending, flags: [:link_adopted])
    end

    it 'lends nothing from a calendar older than the last watcher check by more than MAX_FILE_AGE' do
      result = build(linked_rows + [cagliari_row], snapshot_checked_at: Time.zone.local(2026, 12, 10, 9, 30))
      expect(result.rows.last).to have_attributes(fin_event_id: nil, flags: [])
      expect(result.warnings).to eq([I18n.t('season_board.calendar_links.too_old', file: calendar_file, season: '262', date: '25/11/2026', days: 14)])
    end

    it 'lists the pending files whose FIN id is on no board row, without a warning (the adoption gone; 0.10.103: listed under the board)' do
      write_json('results.new', 'cagliari.json', lt2_hash(fin_id: adopted_id, results: true))
      write_json('results.new', 'lignano.json', lt2_hash(fin_id: '150244'))
      write_json('results.done', 'old.json', lt2_hash(fin_id: '150001', results: true))
      expect(adopted_board.off_board_sources.map(&:fin_event_id)).to eq(['150244'])

      write_eventi('150001' => '150901', '150002' => '150902') # (self-check fails: Cagliari loses its link)
      result = adopted_board
      expect(result.off_board_sources.map(&:fin_event_id)).to eq([adopted_id, '150244'])
      expect(result.warnings.join).not_to include('150244')
    end

    it 'counts the adopted FIN id as on the snapshot for the orphans' do
      adopted_board
      expect(db_index).to have_received(:orphans).with(linked.map(&:last) + [adopted_id])
    end

    it 'keeps the own link of the row (the watcher link wins), with a warning when it differs' do
      result = adopted_board(linked_rows + [cagliari_row(url: results_url('150120'))])
      row = result.rows.last
      expect(row).to have_attributes(fin_event_id: '150120', url: results_url('150120'), adopted_link: nil)
      expect(row.flags).not_to include(:link_adopted)
      expect(result.warnings).to eq(
        [I18n.t('season_board.calendar_links.mismatch', watcher_id: '150120', calendar_id: adopted_id, date: '22/11', place: 'Cagliari',
                                                        file: calendar_file)]
      )
    end

    it 'adopts nothing and warns when the self-check fails' do
      write_eventi('150001' => '150901', '150002' => '150902')
      result = adopted_board
      expect(result.rows.last).to have_attributes(fin_event_id: nil, url: nil, state: :not_linked, flags: [])
      expect(result.warnings).to eq([I18n.t('season_board.calendar_links.suspended', file: calendar_file, count: 2, total: 9)])
    end

    it 'uses the calendar index passed in' do
      calendar_index = instance_double(SeasonBoard::CalendarIndex, link_for: nil, warnings: ['calendar note'])
      result = build(linked_rows + [cagliari_row], calendar_index:)
      expect(result.rows.last.fin_event_id).to be_nil
      expect(result.warnings).to eq(['calendar note'])
    end
  end

  describe 'rows FIN removed from the page (0.10.103)' do
    let(:removed_id) { '150500' }
    let(:removed_row) do
      { 'year' => '2026', 'date' => '01/11', 'name' => 'Removed meeting', 'place' => 'Bari', 'url' => results_url(removed_id), 'info' => '',
        'key' => '2026 | 01/11 | Removed meeting | Bari', 'removed_at' => 2.days.ago.iso8601 }
    end

    def build_with_removed(removed = [removed_row]) = build([fin_row], removed_rows: removed)

    it 'appends a removed row with local files, flagged :removed_from_fin, without the crawl actions' do
      write_json('results.new', 'bari.json', lt2_hash(fin_id: removed_id, results: true))
      result = build_with_removed
      row = result.rows.last
      expect(result.rows.size).to eq(2)
      expect(row).to have_attributes(fin_event_id: removed_id, key: removed_row['key'], state: :results_ready, flags: [:removed_from_fin])
      expect(result.off_board_sources).to be_empty
    end

    it 'appends a removed row with a local calendar, dropping its "check results" crawl' do
      link!
      calendars[removed_id] = calendars[fin_id].with(fin_event_id: removed_id)
      row = build_with_removed.rows.last
      expect(row).to have_attributes(state: :structure_committed, state_detail: { past: true }, flags: [:removed_from_fin], next_action: nil)
      expect(db_index).to have_received(:orphans).with([fin_id, removed_id])
    end

    it 'leaves out a removed row with nothing local, or whose FIN id is still on the snapshot' do
      expect(build_with_removed.rows.size).to eq(1)
      write_json('results.new', 'm.json', lt2_hash(fin_id: fin_id, results: true))
      expect(build_with_removed([removed_row.merge('url' => results_url(fin_id))]).rows.size).to eq(1)
    end

    it 'reads the removed rows of the watcher state' do
      write_json('results.new', 'bari.json', lt2_hash(fin_id: removed_id, results: true))
      store = FedernuotoWatch::StateStore.new(path: File.join(data_dir, 'state.json'))
      store.update { { 'rows' => [fin_row], 'removed_rows' => [removed_row] } }
      result = described_class.new(season:, disk_index:, db_index:, activity_log:, today:, state_store: store).call
      expect(result.rows.map(&:fin_event_id)).to eq([fin_id, removed_id])
    end
  end

  describe 'with the real DbIndex' do
    let(:real_season) { FactoryBot.create(:season, begin_date: Date.new(2026, 9, 1), end_date: Date.new(2027, 8, 31)) }

    it 'links the calendar by results_code & reads the result counts' do
      mir = FactoryBot.create(:meeting_individual_result)
      meeting = mir.meeting_program.meeting_event.meeting_session.meeting
      calendar = FactoryBot.create(:calendar, season: real_season, meeting:, results_code: fin_id)
      orphan = FactoryBot.create(:calendar_with_blank_meeting, season: real_season, results_code: nil)

      result = described_class.new(season: real_season, rows: [fin_row], disk_index:, activity_log:, today:).call
      expect(result.rows.first).to have_attributes(
        state: :committed_with_results, calendar_id: calendar.id, meeting_id: meeting.id, mir_count: 1, mrr_count: 0
      )
      expect(result.orphans.map(&:id)).to eq([orphan.id])
    end

    it 'offers as link candidates only the orphans without a FIN id (results_code), never the cancelled ones' do
      blank = FactoryBot.create(:calendar_with_blank_meeting, season: real_season, results_code: nil)
      off_snapshot = FactoryBot.create(:calendar_with_blank_meeting, season: real_season, results_code: '150999')
      cancelled = FactoryBot.create(:calendar_with_blank_meeting, season: real_season, results_code: nil, cancelled: true)

      result = described_class.new(season: real_season, rows: [fin_row], disk_index:, activity_log:, today:).call
      expect(result.orphans.map(&:id)).to contain_exactly(blank.id, off_snapshot.id, cancelled.id)
      expect(result.link_candidates.map(&:id)).to eq([blank.id])
    end
  end
end
