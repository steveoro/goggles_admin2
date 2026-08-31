# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataFix::IndividualResultOverwriteReconciler do
  let(:swimmer_id) { 39_198 }
  let(:team_id) { 42 }
  let(:import_rows) do
    [
      instance_double(
        GogglesDb::DataImportMeetingIndividualResult,
        swimmer_id: swimmer_id,
        team_id: team_id,
        meeting_program_id: 100
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

    it 'deselects zero timing candidates by default' do
      allow(candidate).to receive_messages(seconds: 0, hundredths: 0)

      result = described_class.new(meeting_id: 19_854, import_rows:).discover

      expect(result.first['selected']).to be false
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
        meeting_program_id: nil
      )

      expect(described_class.new(meeting_id: 19_854, import_rows: [incomplete]).discover).to be_empty
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
end
