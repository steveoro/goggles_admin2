# frozen_string_literal: true

require 'rails_helper'
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
