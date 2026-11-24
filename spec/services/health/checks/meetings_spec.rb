# frozen_string_literal: true

require 'rails_helper'
require_relative '../../season_board/disk_fixtures'

RSpec.describe Health::Checks::Meetings do
  include SeasonBoardDiskFixtures

  let(:data_dir) { Dir.mktmpdir }
  let(:season) { closed_health_season }
  let(:status) { :closed }
  let(:today) { Date.current }
  let(:findings) { described_class.new(season:, entry: health_entry(season, status:), today:, data_dir:).call }

  after(:each) { FileUtils.rm_rf(data_dir) }

  def by_check(key)
    findings.select { |finding| finding.check_key == key }
  end

  def meeting(**attributes)
    FactoryBot.create(:meeting, season:, header_date: season.begin_date + 30.days, cancelled: false, results_acquired: false, **attributes)
  end

  # (season folder used by the disk fixtures)
  def results_dir_season = season.id.to_s

  describe 'meetings.no_results.*' do
    it 'reports a past meeting without results nor source as an error, with its calendar as cancel target' do
      empty = meeting
      calendar = FactoryBot.create(:calendar, season:, meeting: empty, results_code: '150001', cancelled: false)
      list = by_check('meetings.no_results.unflagged')
      expect(list.map(&:subject_id)).to eq([empty.id])
      expect(list.first).to have_attributes(severity: 'error', subject_type: 'meeting', identity: "meeting:#{empty.id}")
      expect(list.first.payload).to include('mirs' => 0, 'mrrs' => 0, 'fin_event_id' => '150001',
                                            'cancel' => { 'meeting_id' => empty.id, 'calendar_id' => calendar.id })
      expect(by_check('meetings.no_results.source_on_disk')).to be_empty
    end

    it 'reports it as source on disk when its FIN event has a results source in results.new' do
      empty = meeting
      FactoryBot.create(:calendar, season:, meeting: empty, results_code: '150002')
      stub_const('SeasonBoardDiskFixtures::SEASON_DIR', season.id.to_s)
      path = write_json('results.new', 'trofeo-x.json', lt2_hash(fin_id: 150_002, results: true))
      list = by_check('meetings.no_results.source_on_disk')
      expect(list.map(&:subject_id)).to eq([empty.id])
      expect(list.first.payload['disk']).to include('base' => 'trofeo-x', 'review_path' => path, 'results' => true, 'sql_pending' => false)
      expect(by_check('meetings.no_results.unflagged')).to be_empty
    end

    it 'does not report a relay-only meeting, a cancelled one, nor one with a cancelled calendar' do
      relay_only = meeting
      health_add_mrr(relay_only)
      meeting(cancelled: true)
      flagged_calendar = meeting
      FactoryBot.create(:calendar, season:, meeting: flagged_calendar, cancelled: true)
      expect(by_check('meetings.no_results.unflagged').map(&:subject_id)).not_to include(relay_only.id, flagged_calendar.id)
      expect(by_check('meetings.no_results.unflagged')).to be_empty
    end

    context 'with a current season' do
      let(:season) { FactoryBot.create(:season, begin_date: Date.current - 60.days, end_date: Date.current + 200.days) }
      let(:status) { :current }

      it 'reports only the meetings older than 14 days, as warnings, never the future ones' do
        old = meeting(header_date: today - 20.days)
        meeting(header_date: today - 5.days)
        meeting(header_date: today + 10.days)
        list = by_check('meetings.no_results.unflagged')
        expect(list.map(&:subject_id)).to eq([old.id])
        expect(list.first.severity).to eq('warning')
      end
    end
  end

  describe 'meetings.cancel_mismatch' do
    it 'reports a cancelled calendar with a meeting not cancelled (warning), targeting the meeting' do
      target = meeting
      FactoryBot.create(:calendar, season:, meeting: target, cancelled: true)
      list = by_check('meetings.cancel_mismatch')
      expect(list.map(&:subject_id)).to eq([target.id])
      expect(list.first.severity).to eq('warning')
      expect(list.first.payload['cancel']).to eq('meeting_id' => target.id)
    end

    it 'reports a cancelled meeting with results as an error, without cancel target' do
      cancelled = meeting(cancelled: true)
      health_add_mir(cancelled)
      FactoryBot.create(:calendar, season:, meeting: cancelled, cancelled: true)
      list = by_check('meetings.cancel_mismatch')
      expect(list.map(&:subject_id)).to eq([cancelled.id])
      expect(list.first).to have_attributes(severity: 'error')
      expect(list.first.payload).to include('cancelled_with_results' => true, 'mirs' => 1)
      expect(list.first.payload).not_to have_key('cancel')
    end

    it 'targets the calendar when the meeting is cancelled but its calendar is not' do
      cancelled = meeting(cancelled: true)
      calendar = FactoryBot.create(:calendar, season:, meeting: cancelled, cancelled: false)
      expect(by_check('meetings.cancel_mismatch').first.payload['cancel']).to eq('calendar_id' => calendar.id)
    end
  end

  describe 'calendars.unlinked' do
    it 'reports the calendars (not cancelled) without meeting or with a dangling meeting id, and duplicate FIN ids' do
      blank = FactoryBot.create(:calendar_with_blank_meeting, season:, results_code: '150010', cancelled: false)
      FactoryBot.create(:calendar_with_blank_meeting, season:, cancelled: true)
      dangling = FactoryBot.create(:calendar_with_blank_meeting, season:, cancelled: false)
      dangling.update_columns(meeting_id: 999_999_999) # rubocop:disable Rails/SkipsModelValidations
      linked = FactoryBot.create(:calendar, season:, meeting: meeting, results_code: '150010')

      list = by_check('calendars.unlinked')
      singles = list.select { |finding| finding.subject_type == 'calendar' }
      expect(singles.map(&:subject_id)).to contain_exactly(blank.id, dangling.id)
      expect(singles.find { |f| f.subject_id == dangling.id }.payload).to include('dangling_meeting' => true,
                                                                                  'cancel' => { 'calendar_id' => dangling.id })
      duplicate = list.find { |finding| finding.subject_type == 'calendars' }
      expect(duplicate).to have_attributes(identity: "calendars:#{[blank.id, linked.id].sort.join(',')}", severity: 'error',
                                           title_key: 'finding_duplicate')
      expect(duplicate.title).to include('150010')
    end
  end

  describe 'calendars.unlinked with a same-code meeting' do
    it 'reports a missing link (warning, meeting ids as evidence, no cancel target) instead of a meeting never imported' do
      existing = meeting
      calendar = FactoryBot.create(:calendar_with_blank_meeting, season:, cancelled: false, meeting_code: existing.code)
      found = by_check('calendars.unlinked').find { |finding| finding.subject_id == calendar.id }
      expect(found).to have_attributes(severity: 'warning', title_key: 'finding_same_code')
      expect(found.payload).to include('same_code_meeting_ids' => [existing.id])
      expect(found.payload).not_to have_key('cancel')
      expect(found.title).to include("meeting #{existing.id}")
    end
  end

  describe 'meetings.no_events & meetings.results_flag' do
    it 'reports the meetings without events (warning when past) and the results flag still off' do
      no_events = meeting
      with_results = meeting
      health_add_mir(with_results)
      expect(by_check('meetings.no_events').map(&:subject_id)).to eq([no_events.id])
      expect(by_check('meetings.no_events').first.severity).to eq('warning')
      flag = by_check('meetings.results_flag')
      expect(flag.map(&:identity)).to eq(["season:#{season.id}"]) # (one finding per season)
      expect(flag.first.payload).to include('count' => 1, 'meeting_ids' => [with_results.id], 'rake' => { 'season_id' => season.id })
      expect(Health::Registry.fetch('meetings.results_flag').rake_command(flag.first.payload['rake']))
        .to eq("bin/rails season_board:backfill season=#{season.id}")
    end

    it 'flags a future meeting without events as info' do
      future = meeting(header_date: today + 30.days)
      expect(by_check('meetings.no_events').find { |f| f.subject_id == future.id }.severity).to eq('info')
    end
  end

  it 'loads the facts with three queries and no disk scan when no meeting needs one' do
    meeting.tap { |m| health_add_mir(m) }
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(SAVEPOINT|RELEASE|BEGIN|COMMIT)/i) }
    allow(SeasonBoard::DiskIndex).to receive(:new).and_call_original
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { findings }
    expect(queries).to eq(3)
    expect(SeasonBoard::DiskIndex).not_to have_received(:new)
  end
end
