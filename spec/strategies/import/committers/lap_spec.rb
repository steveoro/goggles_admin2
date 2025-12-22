# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Committers::Lap do
  let(:stats) do
    {
      laps_created: 0,
      laps_updated: 0,
      errors: []
    }
  end
  let(:logger) { Import::PhaseCommitLogger.new(log_path: '/tmp/test.log') }
  let(:sql_log) { [] }
  let(:committer) { described_class.new(stats: stats, logger: logger, sql_log: sql_log) }

  describe '#initialize' do
    it 'accepts stats, logger, and sql_log' do
      expect(committer.stats).to eq(stats)
      expect(committer.logger).to eq(logger)
      expect(committer.sql_log).to eq(sql_log)
    end
  end

  describe '#commit' do
    context 'when required keys are missing' do
      let(:data_import_lap) { FactoryBot.build(:data_import_lap, :length_50) }

      it 'returns nil when MIR ID is nil' do
        invalid_mir = FactoryBot.build(
          :data_import_meeting_individual_result,
          meeting_individual_result_id: nil,
          meeting_program_id: nil,
          swimmer_id: nil,
          team_id: nil
        )

        result = committer.commit(data_import_lap, data_import_mir: invalid_mir)

        expect(result).to be_nil
        expect(stats[:errors]).not_to be_empty
        expect(stats[:errors].first).to include('missing required keys')
      end

      it 'returns nil when length_in_meters is nil' do
        mir = GogglesDb::MeetingIndividualResult.first
        data_import_mir = FactoryBot.build(
          :data_import_meeting_individual_result,
          meeting_individual_result_id: mir.id,
          meeting_program_id: mir.meeting_program_id,
          swimmer_id: mir.swimmer_id,
          team_id: mir.team_id
        )
        invalid_lap = FactoryBot.build(:data_import_lap, length_in_meters: nil)

        result = committer.commit(invalid_lap, data_import_mir: data_import_mir)

        expect(result).to be_nil
        expect(stats[:errors]).not_to be_empty
      end
    end

    context 'with valid data' do
      let(:mir) { GogglesDb::MeetingIndividualResult.joins(:meeting_program).first }
      let(:data_import_mir) do
        FactoryBot.build(
          :data_import_meeting_individual_result,
          meeting_individual_result_id: mir.id,
          meeting_program_id: mir.meeting_program_id,
          swimmer_id: mir.swimmer_id,
          team_id: mir.team_id
        )
      end
      let(:unique_length) { 777 } # Use unique length to avoid conflicts

      let(:data_import_lap) do
        FactoryBot.build(
          :data_import_lap,
          length_in_meters: unique_length,
          minutes: 0,
          seconds: 28,
          hundredths: 50,
          minutes_from_start: 0,
          seconds_from_start: 28,
          hundredths_from_start: 50,
          reaction_time: 0.5
        )
      end

      after(:each) do
        GogglesDb::Lap.where(meeting_individual_result_id: mir.id, length_in_meters: unique_length).destroy_all
      end

      it 'creates a new lap and returns its ID' do
        GogglesDb::Lap.where(meeting_individual_result_id: mir.id, length_in_meters: unique_length).destroy_all

        result = committer.commit(data_import_lap, data_import_mir: data_import_mir)

        expect(result).to be_a(Integer)
        expect(result).to be > 0
        expect(stats[:laps_created]).to eq(1)
        expect(stats[:errors]).to be_empty

        created_lap = GogglesDb::Lap.find(result)
        expect(created_lap.length_in_meters).to eq(unique_length)
        expect(created_lap.seconds).to eq(28)
      end

      it 'finds existing lap by MIR ID + length and returns its ID' do
        # First create a new lap via the committer
        GogglesDb::Lap.where(meeting_individual_result_id: mir.id, length_in_meters: unique_length).destroy_all
        first_result = committer.commit(data_import_lap, data_import_mir: data_import_mir)
        expect(first_result).to be_a(Integer)

        # Reset stats for second commit
        stats[:laps_created] = 0

        # Second commit should find and return existing lap
        second_result = committer.commit(data_import_lap, data_import_mir: data_import_mir)

        expect(second_result).to eq(first_result)
        expect(stats[:laps_created]).to eq(0) # No new lap created
      end
    end
  end
end
