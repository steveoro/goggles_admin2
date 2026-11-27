# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::ResultOutcomePlanner do
  let(:source_path) { "/tmp/outcome-planner-#{SecureRandom.hex(4)}.json" }
  let(:row) do
    GogglesDb::DataImportMeetingIndividualResult.create!(
      import_key: 'target-import', phase_file_path: source_path,
      meeting_program_key: '1-50SL-M30-M', swimmer_id: 1, team_id: 1,
      minutes: 0, seconds: 30, hundredths: 0
    )
  end
  let(:base_candidate) do
    {
      'id' => 900, 'meeting_program_key' => '1-50SL-M25-M', 'merge_target_import_key' => row.import_key,
      'merge_target_program_key' => row.meeting_program_key, 'merge_target_timing_exact' => true,
      'selected' => true, 'merge' => false
    }
  end

  before(:each) { row }

  def planner_for(candidate, overwrite_enabled: true)
    reconciler = instance_double(DataFix::IndividualResultOverwriteReconciler, discover: [candidate])
    allow(DataFix::IndividualResultOverwriteReconciler).to receive(:new).and_return(reconciler)
    described_class.new(source_path:, meeting_id: 1, season_id: 1, overwrite_enabled:, overwrite_candidates: [candidate])
  end

  it 'explains an unbound correct-category row as an in-place reassignment' do
    planner = planner_for(base_candidate.merge('merge_target_state' => 'target_unbound'))

    expect(planner.outcome_for(row.import_key)).to include('outcome' => 'reassign', 'source_mir_id' => 900)
    expect(planner.candidate_outcomes[900]).to eq(:candidate_reassign)
    expect(planner.counts[:physical_creates]).to eq(0)
    expect(planner.counts[:net_mir_delta]).to eq(0)
  end

  it 'explains a true merge target only when merge is selected' do
    planner = planner_for(base_candidate.merge('merge_target_state' => 'target_bound', 'merge' => true))

    expect(planner.outcome_for(row.import_key)['outcome']).to eq('merge_target')
    expect(planner.candidate_outcomes[900]).to eq(:candidate_merge)
  end

  it 'counts a bound-target replacement as a create when merge is off' do
    planner = planner_for(base_candidate.merge('merge_target_state' => 'target_bound', 'merge' => false))

    expect(planner.outcome_for(row.import_key)['outcome']).to eq('create')
    expect(planner.counts[:physical_creates]).to eq(1)
    expect(planner.counts[:net_mir_delta]).to eq(0) # one create, one plain deletion
  end

  it 'marks ignored reconciliation rows as duplicate risk' do
    ignored = base_candidate.merge('merge_target_state' => 'target_unbound', 'selected' => false)
    planner = planner_for(ignored)

    expect(planner.outcome_for(row.import_key)['outcome']).to eq('duplicate_risk')
    expect(planner.warnings).to include(I18n.t('data_import.data_fix.outcome_warning_ignored_correction', mir_id: 900))
  end
end
