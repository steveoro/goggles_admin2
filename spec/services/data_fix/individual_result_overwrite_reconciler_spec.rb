# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::IndividualResultOverwriteReconciler do
  let(:swimmer_id) { 39_198 }
  let(:team_id) { 42 }
  let(:import_program_key) { '1-50SL-M60-M' }
  let(:imported_timing) { Timing.new(minutes: 0, seconds: 36, hundredths: 5) }
  let(:import_rows) do
    [
      instance_double(
        GogglesDb::DataImportMeetingIndividualResult,
        swimmer_id: swimmer_id, team_id: team_id, meeting_program_id: 100,
        meeting_program_key: import_program_key, meeting_individual_result_id: nil,
        import_key: 'import-target', to_timing: imported_timing,
        minutes: 0, seconds: 36, hundredths: 5, phase_file_path: '/tmp/source.json'
      )
    ]
  end
  let(:scope) { instance_double(ActiveRecord::Relation) }
  let(:swimmer) { instance_double(GogglesDb::Swimmer, complete_name: 'Guerra Cristiano', year_of_birth: 1970) }
  let(:team) { instance_double(GogglesDb::Team, editable_name: 'SAN MARINO MASTER', name: 'SAN MARINO MASTER') }
  let(:event_type) { instance_double(GogglesDb::EventType, code: '50SL') }
  let(:session) { instance_double(GogglesDb::MeetingSession, session_order: 1) }
  let(:event) { instance_double(GogglesDb::MeetingEvent, event_type: event_type, meeting_session: session) }
  let(:category) { instance_double(GogglesDb::CategoryType, code: 'M55') }
  let(:gender) { instance_double(GogglesDb::GenderType, code: 'M') }
  let(:program) { instance_double(GogglesDb::MeetingProgram, meeting_event: event, category_type: category, gender_type: gender) }
  let(:candidate) do
    instance_double(
      GogglesDb::MeetingIndividualResult,
      id: 900, meeting_program_id: 200, swimmer_id: swimmer_id, team_id: team_id, rank: 3,
      minutes: 0, seconds: 36, hundredths: 5, disqualified: false, disqualification_notes: nil,
      swimmer: swimmer, team: team, meeting_program: program, laps: [], to_timing: '36.05'
    )
  end

  before(:each) do
    allow(GogglesDb::MeetingIndividualResult).to receive(:joins).and_return(scope)
    allow(scope).to receive_messages(where: scope, includes: [candidate])
    allow(GogglesDb::DataImportLap).to receive(:where).and_return(double(count: 0))
  end

  describe '#discover' do
    it 'finds an exact category correction that can be reassigned in place' do
      result = described_class.new(meeting_id: 19_854, import_rows:).discover.first

      expect(result).to include(
        'id' => 900,
        'reconciliation_kind' => 'category_correction_exact',
        'target_state' => 'target_unbound',
        'merge_target_import_key' => 'import-target',
        'merge_target_program_key' => import_program_key,
        'merge_target_timing_exact' => true
      )
      expect(result['merge']).to be(false) # merge is meaningful only when the correct target already exists
    end

    it 'does not pair a row from another event even with identical timing' do
      allow(import_rows.first).to receive(:meeting_program_key).and_return('1-100SL-M60-M')
      result = described_class.new(meeting_id: 19_854, import_rows:).discover.first

      expect(result['merge_target_import_key']).to be_nil
      expect(result['reconciliation_kind']).to eq('absent')
    end

    it 'does not pair a row from another gender' do
      allow(import_rows.first).to receive(:meeting_program_key).and_return('1-50SL-M60-F')
      result = described_class.new(meeting_id: 19_854, import_rows:).discover.first

      expect(result['merge_target_import_key']).to be_nil
    end

    it 'classifies a unique timing-change pair as a reassignment with lap replacement' do
      allow(import_rows.first).to receive(:to_timing).and_return(Timing.new(minutes: 0, seconds: 37, hundredths: 0))
      result = described_class.new(meeting_id: 19_854, import_rows:).discover.first

      expect(result['reconciliation_kind']).to eq('category_correction_timing_change')
      expect(result['merge_target_timing_exact']).to be(false)
    end

    it 'marks duplicate same-identity imported rows as ambiguous' do
      second = instance_double(
        GogglesDb::DataImportMeetingIndividualResult,
        swimmer_id: swimmer_id, team_id: team_id, meeting_program_id: 101,
        meeting_program_key: '1-50SL-M65-M', meeting_individual_result_id: nil,
        import_key: 'import-target-2', to_timing: imported_timing,
        minutes: 0, seconds: 36, hundredths: 5, phase_file_path: '/tmp/source.json'
      )
      result = described_class.new(meeting_id: 19_854, import_rows: import_rows + [second]).discover.first

      expect(result['merge_ambiguous']).to be(true)
      expect(result['reconciliation_kind']).to eq('ambiguous')
    end

    it 'deselects zero timing candidates by default' do
      allow(candidate).to receive_messages(seconds: 0, hundredths: 0)
      expect(described_class.new(meeting_id: 19_854, import_rows:).discover.first['selected']).to be(false)
    end

    it 'deselects disqualified candidates by default' do
      allow(candidate).to receive_messages(disqualified: true)
      expect(described_class.new(meeting_id: 19_854, import_rows:).discover.first['selected']).to be(false)
    end

    it 'does not select an existing result whose program is imported' do
      allow(candidate).to receive(:meeting_program_id).and_return(100)
      expect(described_class.new(meeting_id: 19_854, import_rows:).discover).to be_empty
    end

    it 'uses stable swimmer/team IDs even when the imported program does not exist yet' do
      allow(import_rows.first).to receive(:meeting_program_id).and_return(nil)
      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result.pluck('id')).to include(900)
    end
  end

  describe '.update_selection' do
    it 'does not turn merge on for an in-place reassignment target' do
      snapshot = described_class.snapshot(described_class.new(meeting_id: 19_854, import_rows:).discover)
      updated = described_class.update_selection(snapshot:, candidate_id: 900, selected: false)
      reselected = described_class.update_selection(snapshot: updated, candidate_id: 900, selected: true)

      expect(reselected['version']).to eq(3)
      expect(reselected['candidates'].first['merge']).to be(false)
    end
  end

  describe '.update_merge_selection' do
    it 'rejects merge for a target that will be reassigned instead' do
      snapshot = described_class.snapshot(described_class.new(meeting_id: 19_854, import_rows:).discover)

      expect do
        described_class.update_merge_selection(snapshot:, candidate_id: 900, merge: true)
      end.to raise_error(ArgumentError, /Cannot enable merge/)
    end
  end

  describe '.validate_snapshot!' do
    it 'accepts a current snapshot and returns candidate IDs' do
      snapshot = described_class.snapshot(described_class.new(meeting_id: 19_854, import_rows:).discover)
      expect(described_class.validate_snapshot!(meeting_id: 19_854, import_rows:, snapshot:)).to eq([900])
    end

    it 'rejects a candidate that is no longer present in the current discovery set' do
      snapshot = described_class.snapshot([{ 'id' => 901, 'meeting_program_id' => 200, 'swimmer_id' => swimmer_id, 'team_id' => team_id }])
      expect do
        described_class.validate_snapshot!(meeting_id: 19_854, import_rows:, snapshot:)
      end.to raise_error(ArgumentError, /Stale individual-result overwrite snapshot/)
    end
  end

  describe '.commit_plan_for' do
    it 'plans an unbound exact correction as an in-place reassignment' do
      snapshot = described_class.snapshot(described_class.new(meeting_id: 19_854, import_rows:).discover)
      plan = described_class.commit_plan_for(meeting_id: 19_854, import_rows:, snapshot:)

      expect(plan['delete_ids']).to be_empty
      expect(plan['merge_targets']).to be_empty
      expect(plan['reassign_targets']).to have_key(900)
      expect(plan['reassign_targets'][900]).to include('import_key' => 'import-target', 'timing_exact' => true)
    end

    it 'plans an absent candidate as a plain deletion' do
      allow(import_rows.first).to receive(:meeting_program_key).and_return('1-100SL-M60-M')
      snapshot = described_class.snapshot(described_class.new(meeting_id: 19_854, import_rows:).discover)
      plan = described_class.commit_plan_for(meeting_id: 19_854, import_rows:, snapshot:)

      expect(plan['delete_ids']).to eq([900])
      expect(plan['reassign_targets']).to be_empty
    end

    it 'fails closed when a planned target drifts' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      snapshot = described_class.snapshot(candidates)
      allow(import_rows.first).to receive(:import_key).and_return('drifted-target-key')

      expect do
        described_class.commit_plan_for(meeting_id: 19_854, import_rows:, snapshot:)
      end.to raise_error(ArgumentError, /Stale individual-result overwrite target/)
    end
  end
end
