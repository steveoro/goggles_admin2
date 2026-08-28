# frozen_string_literal: true

# rubocop:disable Rails/SkipsModelValidations
#
# Intentionally skips AR validations in the test setup: we need to create
# intentionally broken result rows (null swimmer, missing badge, ...) that the
# strategy is supposed to detect and/or repair.

require 'rails_helper'

RSpec.describe Fix::NullSwimmersInMeeting do
  # == Helpers ===============================================================

  def create_meeting_program_individual(meeting)
    meeting_session = meeting.meeting_sessions.first
    meeting_session ||= FactoryBot.create(:meeting_session, meeting:)
    FactoryBot.create(
      :meeting_program_individual,
      meeting_event: FactoryBot.create(
        :meeting_event_individual,
        meeting_session:
      )
    )
  end

  def create_meeting_program_relay(meeting)
    meeting_session = meeting.meeting_sessions.first
    meeting_session ||= FactoryBot.create(:meeting_session, meeting:)
    FactoryBot.create(
      :meeting_program_relay,
      meeting_event: FactoryBot.create(
        :meeting_event_relay,
        meeting_session:
      )
    )
  end

  # == #initialize ===========================================================

  describe '#initialize' do
    let(:meeting) { FactoryBot.create(:meeting) }

    context 'with a valid Meeting' do
      it 'creates an instance' do
        expect(described_class.new(meeting:)).to be_a(described_class)
      end

      it 'stores the meeting' do
        fixer = described_class.new(meeting:)
        expect(fixer.meeting).to eq(meeting)
      end
    end

    context 'with invalid arguments' do
      it 'raises ArgumentError when meeting is missing' do
        expect { described_class.new }.to raise_error(ArgumentError, /meeting must be a Meeting/)
      end

      it 'raises ArgumentError when meeting is not a Meeting' do
        expect { described_class.new(meeting: 'not a meeting') }.to raise_error(ArgumentError, /meeting must be a Meeting/)
      end
    end
  end

  # == #scan =================================================================

  describe '#scan' do
    context 'with a fixable MIR and a fixable child Lap' do
      subject(:fixer) { described_class.new(meeting:) }

      let(:mir) { FactoryBot.create(:meeting_individual_result_with_laps) }
      let(:meeting) { mir.meeting }

      before(:each) do
        mir.update_column(:swimmer_id, nil)
        mir.laps.update_all(swimmer_id: nil)
      end

      it 'reports the MIR as fixable' do
        expect(fixer.scan[:mirs][:fixable]).to eq(1)
      end

      it 'reports the child Lap as fixable' do
        expect(fixer.scan[:laps][:fixable]).to eq(mir.laps.count)
      end

      it 'has no unfixable MIRs' do
        expect(fixer.scan[:mirs][:unfixable]).to be_zero
      end
    end

    context 'with a fixable MRS and a fixable child RelayLap' do
      subject(:fixer) { described_class.new(meeting:) }

      let(:mrs) { FactoryBot.create(:meeting_relay_swimmer) }
      let(:meeting) { mrs.meeting }
      let(:other_swimmer) { FactoryBot.create(:swimmer) }

      before(:each) do
        FactoryBot.create(
          :relay_lap,
          meeting_relay_swimmer: mrs,
          meeting_relay_result: mrs.meeting_relay_result,
          swimmer: other_swimmer,
          team: mrs.meeting_relay_result.team
        )
        mrs.update_column(:swimmer_id, nil)
      end

      it 'reports the MRS as fixable' do
        expect(fixer.scan[:mrss][:fixable]).to eq(1)
      end

      it 'reports the child RelayLap as fixable' do
        expect(fixer.scan[:relay_laps][:fixable]).to eq(1)
      end
    end

    context 'with unfixable MIRs' do
      subject(:fixer) { described_class.new(meeting:) }

      let(:meeting) { FactoryBot.create(:meeting) }
      let!(:meeting_program) { create_meeting_program_individual(meeting) }

      let!(:mir_no_badge) do
        mir = FactoryBot.create(:meeting_individual_result, meeting_program:)
        mir.update_columns(badge_id: nil, swimmer_id: nil)
        mir
      end
      let!(:mir_missing_badge) do
        mir = FactoryBot.create(:meeting_individual_result, meeting_program:)
        mir.update_columns(badge_id: -1, swimmer_id: nil)
        mir
      end
      let!(:mir_null_badge_swimmer) do
        mir = FactoryBot.create(:meeting_individual_result, meeting_program:)
        mir.update_column(:swimmer_id, nil)
        mir.badge.update_column(:swimmer_id, nil)
        mir
      end

      it 'reports zero fixable MIRs' do
        expect(fixer.scan[:mirs][:fixable]).to be_zero
      end

      it 'reports the right number of unfixable MIRs' do
        expect(fixer.scan[:mirs][:unfixable]).to eq(3)
      end

      it 'reports one MIR with no badge' do
        expect(fixer.scan[:mirs][:no_badge]).to eq(1)
      end

      it 'reports one MIR with a missing badge' do
        expect(fixer.scan[:mirs][:missing_badge]).to eq(1)
      end

      it 'reports one MIR with a badge that has a null swimmer' do
        expect(fixer.scan[:mirs][:null_badge_swimmer]).to eq(1)
      end

      it 'includes unfixable details' do
        expect(fixer.scan[:mirs][:details]).to include(a_string_matching(/MIR #{mir_no_badge.id}: no badge/))
        expect(fixer.scan[:mirs][:details]).to include(a_string_matching(/MIR #{mir_missing_badge.id}: missing badge/))
        expect(fixer.scan[:mirs][:details]).to include(a_string_matching(/MIR #{mir_null_badge_swimmer.id}: badge .* has null swimmer/))
      end
    end

    context 'with a clean meeting (no null swimmers)' do
      subject(:fixer) { described_class.new(meeting:) }

      let(:meeting) { FactoryBot.create(:meeting) }
      let!(:meeting_program) { create_meeting_program_individual(meeting) }

      before(:each) do
        FactoryBot.create(:meeting_individual_result, meeting_program:)
      end

      it 'reports zero fixable and unfixable rows' do
        expect(fixer.scan[:mirs][:fixable]).to be_zero
        expect(fixer.scan[:mirs][:unfixable]).to be_zero
        expect(fixer.scan[:mrss][:fixable]).to be_zero
        expect(fixer.scan[:mrss][:unfixable]).to be_zero
        expect(fixer.scan[:laps][:fixable]).to be_zero
        expect(fixer.scan[:relay_laps][:fixable]).to be_zero
      end
    end
  end

  # == #fixable? =============================================================

  describe '#fixable?' do
    subject(:fixer) { described_class.new(meeting:) }

    let(:mir) { FactoryBot.create(:meeting_individual_result) }
    let(:meeting) { mir.meeting }

    before(:each) { mir.update_column(:swimmer_id, nil) }

    it 'returns true when there are fixable rows' do
      expect(fixer.fixable?).to be true
    end
  end

  # == #prepare ==============================================================

  describe '#prepare' do
    context 'with a fixable MIR, MRS and child rows' do
      subject(:sql_log) { described_class.new(meeting:).prepare }

      let(:mir) { FactoryBot.create(:meeting_individual_result_with_laps) }
      let(:meeting) { mir.meeting }
      let(:meeting_program_relay) { create_meeting_program_relay(meeting) }
      let(:meeting_relay_result) { FactoryBot.create(:meeting_relay_result, meeting_program: meeting_program_relay) }
      let(:mrs) { FactoryBot.create(:meeting_relay_swimmer, meeting_relay_result:) }

      before(:each) do
        mir.update_column(:swimmer_id, nil)
        mir.laps.update_all(swimmer_id: nil)

        FactoryBot.create(
          :relay_lap,
          meeting_relay_swimmer: mrs,
          meeting_relay_result:,
          swimmer: FactoryBot.create(:swimmer),
          team: meeting_relay_result.team
        )

        mrs.update_column(:swimmer_id, nil)
      end

      it 'includes all four UPDATE statements' do
        expect(sql_log).to include(a_string_matching(/UPDATE laps l/))
        expect(sql_log).to include(a_string_matching(/UPDATE meeting_individual_results mir/))
        expect(sql_log).to include(a_string_matching(/UPDATE relay_laps rl/))
        expect(sql_log).to include(a_string_matching(/UPDATE meeting_relay_swimmers mrs/))
      end

      it 'emits the statements in the correct order (children before parents)' do
        lap_index  = sql_log.index { |line| line.include?('UPDATE laps l') }
        mir_index  = sql_log.index { |line| line.include?('UPDATE meeting_individual_results mir') }
        rlap_index = sql_log.index { |line| line.include?('UPDATE relay_laps rl') }
        mrs_index  = sql_log.index { |line| line.include?('UPDATE meeting_relay_swimmers mrs') }

        expect(lap_index).to be < mir_index
        expect(rlap_index).to be < mrs_index
      end

      it 'filters by the correct meeting_id in each statement' do
        expect(sql_log.join).to include("ms.meeting_id = #{meeting.id}")
      end

      it 'only targets rows with null swimmer and valid badge' do
        joined = sql_log.join
        expect(joined).to include('mir.swimmer_id IS NULL')
        expect(joined).to include('mrs.swimmer_id IS NULL')
        expect(joined).to include('b.swimmer_id IS NOT NULL')
      end
    end

    context 'with no fixable rows' do
      subject(:sql_log) { described_class.new(meeting:).prepare }

      let(:meeting) { FactoryBot.create(:meeting) }

      it 'returns an empty SQL log' do
        expect(sql_log).to be_empty
      end
    end
  end

  # == #display_report =======================================================

  describe '#display_report' do
    subject(:fixer) { described_class.new(meeting:) }

    let(:mir) { FactoryBot.create(:meeting_individual_result) }
    let(:meeting) { mir.meeting }

    before(:each) { mir.update_column(:swimmer_id, nil) }

    it 'prints a report containing the meeting and fixable counts' do
      expect { fixer.display_report }.to output(/Meeting #{meeting.id}/).to_stdout
      expect { fixer.display_report }.to output(/MIRs: 1 fixable/).to_stdout
    end
  end
end
# rubocop:enable Rails/SkipsModelValidations
