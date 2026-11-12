# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SeasonBoard::DbIndex do
  subject(:index) { described_class.new(season_id: season.id) }

  let(:season) { FactoryBot.create(:season) }
  let(:other_season) { FactoryBot.create(:season) }

  # Meeting with 2 MIRs & 1 MRR
  let(:meeting_with_results) do
    mir = FactoryBot.create(:meeting_individual_result)
    FactoryBot.create(:meeting_individual_result, meeting_program: mir.meeting_program)
    session = mir.meeting_program.meeting_event.meeting_session
    relay_event = FactoryBot.create(:meeting_event_relay, meeting_session: session)
    FactoryBot.create(:meeting_relay_result, meeting_program: FactoryBot.create(:meeting_program_relay, meeting_event: relay_event))
    session.meeting
  end
  let(:meeting_without_results) { FactoryBot.create(:meeting, season:, results_acquired: false, manifest: true) }

  let!(:cal_with_results) do
    FactoryBot.create(:calendar, season:, meeting: meeting_with_results, results_code: '150091',
                                 results_link: 'https://www.federnuoto.it/x#/risultati/150091:a.html')
  end
  let!(:cal_structure) { FactoryBot.create(:calendar, season:, meeting: meeting_without_results, results_code: '150092') }
  let!(:cal_unlinked) { FactoryBot.create(:calendar_with_blank_meeting, season:, results_code: '150093', cancelled: true) }
  let!(:cal_blank_code) { FactoryBot.create(:calendar, season:, meeting: FactoryBot.create(:meeting, season:)) }
  let!(:cal_not_in_snapshot) { FactoryBot.create(:calendar_with_blank_meeting, season:, results_code: '149999') }

  before(:each) do
    FactoryBot.create(:calendar, season: other_season, results_code: '150091')
  end

  def count_queries(&)
    count = 0
    callback = lambda do |_name, _start, _finish, _id, payload|
      count += 1 unless payload[:name] == 'SCHEMA' || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record', &)
    count
  end

  it 'indexes the season calendars by FIN id (results_code)' do
    expect(index.calendars.map(&:id)).to eq([cal_with_results, cal_structure, cal_unlinked, cal_blank_code, cal_not_in_snapshot].map(&:id))
    expect(index.calendars_by_fin_id.keys).to contain_exactly('150091', '150092', '150093', '149999')
    expect(index.calendar_for(150_091)).to have_attributes(
      id: cal_with_results.id, meeting_id: meeting_with_results.id, meeting_code: cal_with_results.meeting_code,
      cancelled: false, results_link: 'https://www.federnuoto.it/x#/risultati/150091:a.html'
    )
    expect(index.calendar_for('150093')).to have_attributes(meeting_id: nil, meeting: nil, cancelled: true)
    expect(index.calendar_for('150093')).not_to be_linked
  end

  it 'loads the meeting facts with the MIR/MRR counts' do
    expect(index.calendar_for('150091').meeting).to have_attributes(
      id: meeting_with_results.id, description: meeting_with_results.description,
      header_date: meeting_with_results.header_date, mir_count: 2, mrr_count: 1, cancelled: false
    )
    expect(index.calendar_for('150091').meeting).to be_results
    expect(index.meeting(meeting_without_results.id)).to have_attributes(
      mir_count: 0, mrr_count: 0, results_acquired: false, manifest: true
    )
    expect(index.meeting(meeting_without_results.id)).not_to be_results
    expect(index.counts_for(meeting_with_results.id)).to eq(mir: 2, mrr: 1)
    expect(index.counts_for(0)).to eq(mir: 0, mrr: 0)
  end

  it 'considers results_acquired as results even without counts' do
    meeting_without_results.update_columns(results_acquired: true) # rubocop:disable Rails/SkipsModelValidations
    expect(index.meeting(meeting_without_results.id)).to be_results
  end

  it 'lists as orphans the calendars without FIN id or not in the snapshot' do
    expect(index.orphans(%w[150091 150092 150093]).map(&:id)).to contain_exactly(cal_blank_code.id, cal_not_in_snapshot.id)
  end

  it 'prefers the linked calendar on a duplicated FIN id & reports it' do
    FactoryBot.create(:calendar_with_blank_meeting, season:, results_code: '150092')
    expect(index.calendar_for('150092').id).to eq(cal_structure.id)
    expect(index.duplicate_fin_event_ids).to eq(['150092'])
  end

  it 'loads everything with 2 queries, regardless of the number of calendars' do
    3.times { FactoryBot.create(:calendar, season:, results_code: SecureRandom.hex(3)) }
    queries = count_queries do
      described_class.new(season_id: season.id).tap do |idx|
        idx.calendars_by_fin_id
        idx.meetings
        idx.calendars.each { |cal| idx.counts_for(cal.meeting_id) }
        idx.orphans([])
      end
    end
    expect(queries).to eq(2)
  end

  it 'issues a single query when no calendar is linked to a meeting' do
    empty_season = FactoryBot.create(:season)
    FactoryBot.create(:calendar_with_blank_meeting, season: empty_season, results_code: '1')
    queries = count_queries { described_class.new(season_id: empty_season.id).calendars }
    expect(queries).to eq(1)
  end
end
