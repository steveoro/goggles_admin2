# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Import::Committers::RelayLap do
  let(:stats) do
    {
      relay_laps_created: 0,
      relay_laps_updated: 0,
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
    # Use existing data from test DB
    let(:mrs) { GogglesDb::MeetingRelaySwimmer.joins(:meeting_relay_result).first }
    let(:mrr) { mrs.meeting_relay_result }

    context 'when required keys are missing' do
      let(:data_import_relay_lap) { FactoryBot.build(:data_import_relay_lap, :length_50) } # rubocop:disable Naming/VariableNumber

      it 'returns nil when MRS ID is nil' do
        result = committer.commit(
          data_import_relay_lap,
          mrs_id: nil,
          mrr_id: mrr.id,
          swimmer_id: mrs.swimmer_id,
          team_id: mrr.team_id,
          mrs_length: 50
        )

        expect(result).to be_nil
        expect(stats[:errors]).not_to be_empty
        expect(stats[:errors].first).to include('missing required keys')
      end

      it 'returns nil when mrs_length is nil (treated as skip, not error)' do
        # When mrs_length is nil, nil.to_i = 0, so lap_length >= 0 is true
        # The committer skips without adding to errors (legitimate skip, not error)
        result = committer.commit(
          data_import_relay_lap,
          mrs_id: mrs.id,
          mrr_id: mrr.id,
          swimmer_id: mrs.swimmer_id,
          team_id: mrr.team_id,
          mrs_length: nil
        )

        expect(result).to be_nil
        # This is a skip, not an error - no relay sub-lap needed
      end
    end

    context 'with valid data' do
      # RelayLaps are only for intermediate timings within a swimmer's fraction
      # lap_length must be < mrs_length (e.g., 50m sub-lap in a 100m fraction)
      let(:lap_length) { 50 }
      let(:mrs_fraction_length) { 100 } # Swimmer's total fraction length

      let(:data_import_relay_lap) do
        FactoryBot.build(
          :data_import_relay_lap,
          length_in_meters: lap_length,
          minutes: 0,
          seconds: 26,
          hundredths: 30,
          minutes_from_start: 0,
          seconds_from_start: 26,
          hundredths_from_start: 30,
          reaction_time: 0.4
        )
      end

      after(:each) do
        GogglesDb::RelayLap.where(meeting_relay_swimmer_id: mrs.id, length_in_meters: lap_length).destroy_all
      end

      it 'creates a new relay lap and returns its ID' do
        GogglesDb::RelayLap.where(meeting_relay_swimmer_id: mrs.id, length_in_meters: lap_length).destroy_all

        result = committer.commit(
          data_import_relay_lap,
          mrs_id: mrs.id,
          mrr_id: mrr.id,
          swimmer_id: mrs.swimmer_id,
          team_id: mrr.team_id,
          mrs_length: mrs_fraction_length
        )

        expect(result).to be_a(Integer)
        expect(result).to be > 0
        expect(stats[:relay_laps_created]).to eq(1)
        expect(stats[:errors]).to be_empty

        created_lap = GogglesDb::RelayLap.find(result)
        expect(created_lap.length_in_meters).to eq(lap_length)
        expect(created_lap.seconds).to eq(26)
      end

      it 'finds existing relay lap by MRS ID + length and returns its ID' do
        # Pre-create relay lap
        existing = GogglesDb::RelayLap.create!(
          meeting_relay_swimmer_id: mrs.id,
          meeting_relay_result_id: mrr.id,
          swimmer_id: mrs.swimmer_id,
          team_id: mrr.team_id,
          length_in_meters: lap_length,
          minutes: 0,
          seconds: 26,
          hundredths: 30
        )

        result = committer.commit(
          data_import_relay_lap,
          mrs_id: mrs.id,
          mrr_id: mrr.id,
          swimmer_id: mrs.swimmer_id,
          team_id: mrr.team_id,
          mrs_length: mrs_fraction_length
        )

        expect(result).to eq(existing.id)
      end

      it 'skips when lap_length >= mrs_length (no sub-lap needed)' do
        result = committer.commit(
          data_import_relay_lap,
          mrs_id: mrs.id,
          mrr_id: mrr.id,
          swimmer_id: mrs.swimmer_id,
          team_id: mrr.team_id,
          mrs_length: lap_length # Same as lap_length, should skip
        )

        expect(result).to be_nil
        expect(stats[:relay_laps_created]).to eq(0)
      end
    end
  end
end
