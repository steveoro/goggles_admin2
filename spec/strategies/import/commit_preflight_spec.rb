# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::CommitPreflight do
  let(:tmp_dir) { Dir.mktmpdir('preflight-') }
  let(:pipeline) { pipeline_from_fixture('clean_fin', dir: tmp_dir) }
  let(:category_code) { GogglesDb::CategoryType.where(season_id: 242, relay: false).pick(:code) }

  after(:each) { FileUtils.rm_rf(tmp_dir) }

  def write_later_phases(programs:, events: [{ 'key' => '50SL', 'session_order' => 1 }])
    PhaseFileManager.new(pipeline.phase_path(4)).write!(data: { 'sessions' => [{ 'session_order' => 1, 'events' => events }] }, meta: {})
    PhaseFileManager.new(pipeline.phase_path(5)).write_payload!('name' => 'phase5', 'programs' => programs)
    pipeline.reload!
  end

  def program(event_key: '50SL', category: category_code, gender: 'M', relay: false)
    { 'session_order' => 1, 'event_key' => event_key, 'event_code' => event_key, 'category_code' => category, 'gender_code' => gender,
      'relay' => relay }
  end

  def codes(rows) = rows.pluck(:code)

  it 'passes a consistent source' do
    write_later_phases(programs: [program])
    result = described_class.new(pipeline:).call
    expect(result).to be_ok
    expect(result.warnings).to be_empty
  end

  it 'reports the programs whose event is missing from phase 4 (Main would skip them)' do
    write_later_phases(programs: [program, program(event_key: '100RA')])
    result = described_class.new(pipeline:).call
    expect(codes(result.errors)).to eq(['program_event_missing'])
    expect(result.errors.first).to include(count: 1, phase: 4, details: ['1-100RA'])
  end

  it 'reports the unresolvable individual categories and genders (relays only warned)' do
    write_later_phases(programs: [program(category: 'ZZZ'), program(gender: '?'), program(category: 'WHAT', relay: true)],
                       events: [{ 'key' => '50SL', 'session_order' => 1 }])
    result = described_class.new(pipeline:).call
    expect(codes(result.errors)).to contain_exactly('category_unresolved', 'gender_unresolved')
    expect(codes(result.warnings)).to eq(['relay_category_unresolved'])
  end

  it 'reports a FIN event already linked to another meeting' do
    write_later_phases(programs: [program])
    calendar = FactoryBot.create(:calendar, season_id: 242)
    calendar.update_columns(results_code: '990001', meeting_id: 1) # rubocop:disable Rails/SkipsModelValidations
    expect(codes(described_class.new(pipeline:).call.errors)).to eq(['fin_link_conflict'])
  end

  describe 'the exact-name check' do
    before(:each) { write_later_phases(programs: [program]) }

    it 'is an error when a new team or swimmer would duplicate an existing row, a warning with create_anyway' do
      team = FactoryBot.create(:team, name: 'Fixture Team 009', editable_name: 'Fixture Team 009')
      FactoryBot.create(:swimmer, complete_name: 'FIXTUREZQ064 PIPELINE', last_name: 'FIXTUREZQ064', first_name: 'PIPELINE',
                                  year_of_birth: 1980, gender_type: GogglesDb::GenderType.male)

      result = described_class.new(pipeline:).call
      expect(codes(result.errors)).to contain_exactly('existing_team_name', 'existing_swimmer_name')
      expect(result.errors.find { |row| row[:code] == 'existing_team_name' }[:message]).to include("team #{team.id}")

      relaxed = described_class.new(pipeline:, create_anyway: true).call
      expect(relaxed).to be_ok
      expect(codes(relaxed.warnings)).to contain_exactly('existing_team_name', 'existing_swimmer_name')
    end
  end

  it 'warns about a team score without a Phase 2 team' do
    write_later_phases(programs: [program])
    data = pipeline.phase_data(2).merge('team_scores' => [{ 'team_key' => 'Gone Team', 'rank' => 1 }])
    PhaseFileManager.new(pipeline.phase_path(2)).write!(data:, meta: {})
    result = described_class.new(pipeline: pipeline.reload!).call
    expect(codes(result.warnings)).to eq(['team_score_without_team'])
  end

  it 'reports a stale overwrite selection' do
    write_later_phases(programs: [program])
    payload = JSON.parse(File.read(pipeline.phase_path(5)))
    snapshot = { 'version' => 2, 'candidates' => [{ 'id' => 1, 'selected' => true }] }
    payload['_meta'] = { 'individual_result_overwrite' => { 'enabled' => true, 'snapshot' => snapshot } }
    File.write(pipeline.phase_path(5), JSON.generate(payload))
    expect(codes(described_class.new(pipeline: pipeline.reload!).call.errors)).to eq(['overwrite_snapshot_invalid'])
  end
end
