# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::IndividualResultOverwriteReconciler do
  let(:swimmer_id) { 39_198 }
  let(:team_id) { 42 }
  let(:import_program_key) { '1-50SL-M55-F' }
  let(:imported_timing) { Timing.new(minutes: 0, seconds: 36, hundredths: 5) }
  let(:import_rows) do
    [
      instance_double(
        GogglesDb::DataImportMeetingIndividualResult,
        swimmer_id: swimmer_id,
        team_id: team_id,
        meeting_program_id: 100,
        meeting_program_key: import_program_key,
        meeting_individual_result_id: nil,
        import_key: 'import-1-50SL-M55-M',
        to_timing: imported_timing,
        minutes: 0,
        seconds: 36,
        hundredths: 5
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
  let(:program) do
    instance_double(
      GogglesDb::MeetingProgram,
      meeting_event: event,
      category_type: category,
      gender_type: gender
    )
  end
  let(:candidate) do
    instance_double(
      GogglesDb::MeetingIndividualResult,
      id: 900,
      meeting_program_id: 200,
      swimmer_id: swimmer_id,
      team_id: team_id,
      rank: 3,
      minutes: 0,
      seconds: 36,
      hundredths: 5,
      disqualified: false,
      disqualification_notes: nil,
      swimmer: swimmer,
      team: team,
      meeting_program: program,
      laps: [],
      to_timing: '36.05'
    )
  end

  before(:each) do
    allow(GogglesDb::MeetingIndividualResult).to receive(:joins).and_return(scope)
    allow(scope).to receive_messages(where: scope, includes: [candidate])
    allow(GogglesDb::DataImportLap).to receive(:where).and_return(double(count: 0))
  end

  describe '#discover' do
    it 'finds an existing result in a program absent from the imported set' do
      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result).to include(hash_including(
                                  'id' => 900,
                                  'meeting_program_id' => 200,
                                  'swimmer_id' => swimmer_id,
                                  'team_id' => team_id,
                                  'reason' => 'Not present in imported source'
                                ))
    end

    it 'selects non-zero timing candidates by default' do
      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result.first['selected']).to be true
    end

    it 'defaults merge to true when a single matching target exists' do
      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result.first['merge']).to be true
      expect(result.first['merge_target_import_key']).to eq('import-1-50SL-M55-M')
      expect(result.first['merge_target_program_key']).to eq(import_program_key)
      expect(result.first['merge_available']).to be true
      expect(result.first['merge_ambiguous']).to be false
    end

    it 'does not offer merge when no matching imported result exists' do
      allow(import_rows.first).to receive(:to_timing).and_return(Timing.new(minutes: 0, seconds: 37, hundredths: 0))

      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result.first['merge']).to be false
      expect(result.first['merge_available']).to be false
    end

    it 'marks merge as ambiguous when more than one matching imported result exists' do
      second_match = instance_double(
        GogglesDb::DataImportMeetingIndividualResult,
        swimmer_id: swimmer_id,
        team_id: team_id,
        meeting_program_id: 101,
        meeting_program_key: '1-100SL-M55-M',
        meeting_individual_result_id: nil,
        import_key: 'import-1-100SL-M55-M',
        to_timing: imported_timing,
        minutes: 0,
        seconds: 36,
        hundredths: 5
      )
      rows = import_rows + [second_match]

      result = described_class.new(meeting_id: 19_854, import_rows: rows).discover

      expect(result.first['merge']).to be false
      expect(result.first['merge_available']).to be false
      expect(result.first['merge_ambiguous']).to be true
    end

    it 'deselects zero timing candidates by default' do
      allow(candidate).to receive_messages(seconds: 0, hundredths: 0)

      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result.first['selected']).to be false
      expect(result.first['merge']).to be false
    end

    it 'deselects disqualified candidates by default' do
      allow(candidate).to receive_messages(disqualified: true)

      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result.first['selected']).to be false
      expect(result.first['merge']).to be false
    end

    it 'deselects candidates with disqualification notes by default' do
      allow(candidate).to receive_messages(disqualification_notes: 'DSQ - false start')

      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result.first['selected']).to be false
      expect(result.first['merge']).to be false
    end

    it 'does not select an existing result whose program is imported' do
      allow(candidate).to receive(:meeting_program_id).and_return(100)

      expect(described_class.new(meeting_id: 19_854, import_rows:).discover).to be_empty
    end

    it 'ignores imported rows without all stable IDs' do
      incomplete = instance_double(
        GogglesDb::DataImportMeetingIndividualResult,
        swimmer_id: swimmer_id,
        team_id: team_id,
        meeting_program_id: nil,
        meeting_program_key: nil,
        meeting_individual_result_id: nil,
        import_key: 'incomplete',
        to_timing: Timing.new,
        minutes: 0,
        seconds: 0,
        hundredths: 0
      )

      expect(described_class.new(meeting_id: 19_854, import_rows: [incomplete]).discover).to be_empty
    end
  end

  describe '.update_selection' do
    it 'turns merge on when a candidate is selected' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      snapshot = described_class.snapshot(candidates)

      updated = described_class.update_selection(snapshot:, candidate_id: 900, selected: false)
      expect(updated['candidates'].first['merge']).to be false

      reselected = described_class.update_selection(snapshot: updated, candidate_id: 900, selected: true)
      expect(reselected['candidates'].first['merge']).to be true
    end
  end

  describe '.update_merge_selection' do
    it 'toggles merge off while keeping the candidate selected' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      snapshot = described_class.snapshot(candidates)

      updated = described_class.update_merge_selection(snapshot:, candidate_id: 900, merge: false)

      expect(updated['candidates'].first['merge']).to be false
      expect(updated['candidates'].first['selected']).to be true
    end

    it 'rejects merge when the candidate has no unique target' do
      snapshot = described_class.snapshot([{ 'id' => 900, 'merge_target_import_key' => nil, 'selected' => true }])

      expect do
        described_class.update_merge_selection(snapshot:, candidate_id: 900, merge: true)
      end.to raise_error(ArgumentError, /Cannot enable merge/)
    end
  end

  describe '.validate_snapshot!' do
    it 'accepts a current snapshot and returns candidate IDs' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      snapshot = described_class.snapshot(candidates)

      expect(described_class.validate_snapshot!(meeting_id: 19_854, import_rows:, snapshot:)).to eq([900])
    end

    it 'returns no IDs for an ignored candidate' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      candidates.first['selected'] = false
      snapshot = described_class.snapshot(candidates)

      expect(described_class.validate_snapshot!(meeting_id: 19_854, import_rows:, snapshot:)).to eq([])
    end

    it 'updates one candidate selection without rediscovery' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      snapshot = described_class.snapshot(candidates)

      updated = described_class.update_selection(snapshot:, candidate_id: 900, selected: false)

      expect(updated['candidates'].first['selected']).to be false
      expect(snapshot['candidates'].first['selected']).to be true
    end

    it 'rejects a candidate that is no longer present in the current discovery set' do
      snapshot = described_class.snapshot([{ 'id' => 901, 'meeting_program_id' => 200, 'swimmer_id' => swimmer_id, 'team_id' => team_id }])

      expect do
        described_class.validate_snapshot!(meeting_id: 19_854, import_rows:, snapshot:)
      end.to raise_error(ArgumentError, /Stale individual-result overwrite snapshot/)
    end
  end

  describe '.commit_plan_for' do
    it 'splits selected candidates into delete IDs and merge targets' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      snapshot = described_class.snapshot(candidates)

      plan = described_class.commit_plan_for(meeting_id: 19_854, import_rows:, snapshot:)

      expect(plan['delete_ids']).to be_empty
      expect(plan['merge_targets']).to have_key(900)
      expect(plan['merge_targets'][900]['import_key']).to eq('import-1-50SL-M55-M')
    end

    it 'puts a selected candidate into delete_ids when merge is disabled' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      candidates.first['merge'] = false
      snapshot = described_class.snapshot(candidates)

      plan = described_class.commit_plan_for(meeting_id: 19_854, import_rows:, snapshot:)

      expect(plan['delete_ids']).to eq([900])
      expect(plan['merge_targets']).to be_empty
    end

    it 'falls back to delete when a merge target is no longer available' do
      candidates = described_class.new(meeting_id: 19_854, import_rows:).discover
      candidates.first['merge'] = true
      candidates.first['merge_target_import_key'] = 'stale-import-key'
      snapshot = described_class.snapshot(candidates)

      # Same swimmer/team, but a different timing so the merge target cannot be rediscovered
      stale_rows = [
        instance_double(
          GogglesDb::DataImportMeetingIndividualResult,
          swimmer_id: swimmer_id,
          team_id: team_id,
          meeting_program_id: 100,
          meeting_program_key: '1-50SL-M55-F',
          meeting_individual_result_id: nil,
          import_key: 'import-1-50SL-M55-F',
          to_timing: Timing.new(minutes: 0, seconds: 37, hundredths: 0),
          minutes: 0,
          seconds: 37,
          hundredths: 0
        )
      ]

      plan = described_class.commit_plan_for(meeting_id: 19_854, import_rows: stale_rows, snapshot:)

      expect(plan['delete_ids']).to eq([900])
      expect(plan['merge_targets']).to be_empty
    end
  end
end
