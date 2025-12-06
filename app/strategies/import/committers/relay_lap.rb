# frozen_string_literal: true

module Import
  module Committers
    #
    # = RelayLap
    #
    # Commits RelayLap entities to the production DB.
    # Converts from DataImportRelayLap temporary records.
    #
    class RelayLap
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end

      # Commit a RelayLap from a data_import record.
      # @param data_import_relay_lap [GogglesDb::DataImportRelayLap] the temp record
      # @param mrs_id [Integer] the resolved meeting_relay_swimmer_id
      # @param mrr_id [Integer] the resolved meeting_relay_result_id
      # @param swimmer_id [Integer] swimmer_id from parent MRS (required for relay_laps)
      # @param team_id [Integer] team_id from parent MRR (required for relay_laps)
      # @param mrs_length [Integer] length_in_meters from parent MRS (to detect sub-laps)
      # Returns relay_lap_id or nil.
      def commit(data_import_relay_lap, mrs_id:, mrr_id:, swimmer_id:, team_id:, mrs_length:)
        model = nil
        lap_length = data_import_relay_lap.length_in_meters

        # Guard clause: skip if missing required keys
        unless mrs_id && lap_length
          stats[:errors] << "RelayLap error: missing required keys (mrs=#{mrs_id}, length=#{lap_length})"
          return nil
        end

        # Skip if lap length equals MRS fraction length (no sub-fractional timing)
        # RelayLaps are only for intermediate timings within a swimmer's fraction
        # e.g., in 4x100m, each 50m split; in 4x50m, there are no sub-laps
        if lap_length.to_i >= mrs_length.to_i
          # DEBUG: VERBOSE
          # Rails.logger.debug { "[RelayLap] Skipping: lap_length=#{lap_length} >= mrs_length=#{mrs_length} (no sub-lap)" }
          return nil
        end

        attributes = normalize_attributes(
          data_import_relay_lap,
          mrs_id: mrs_id,
          mrr_id: mrr_id,
          swimmer_id: swimmer_id,
          team_id: team_id
        )

        # Create new relay lap (no matching logic - always new)
        model = GogglesDb::RelayLap.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:relay_laps_created] += 1
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        entity_key = data_import_relay_lap.import_key
        stats[:errors] << "RelayLap error (#{entity_key}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'RelayLap',
          entity_key: entity_key,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[RelayLap] ERROR: #{error_details}")
        raise
      end

      private

      def normalize_attributes(data_import_relay_lap, mrs_id:, mrr_id:, swimmer_id:, team_id:)
        {
          'meeting_relay_swimmer_id' => mrs_id,
          'meeting_relay_result_id' => mrr_id,
          'length_in_meters' => integer_or_nil(data_import_relay_lap.length_in_meters),
          'swimmer_id' => swimmer_id,
          'team_id' => team_id,
          'minutes' => integer_or_nil(data_import_relay_lap.minutes),
          'seconds' => integer_or_nil(data_import_relay_lap.seconds),
          'hundredths' => integer_or_nil(data_import_relay_lap.hundredths),
          'minutes_from_start' => integer_or_nil(data_import_relay_lap.minutes_from_start),
          'seconds_from_start' => integer_or_nil(data_import_relay_lap.seconds_from_start),
          'hundredths_from_start' => integer_or_nil(data_import_relay_lap.hundredths_from_start),
          'reaction_time' => decimal_or_nil(data_import_relay_lap.reaction_time),
          'position' => integer_or_nil(data_import_relay_lap.position)
        }.compact
      end

      def integer_or_nil(value)
        return nil if value.blank?

        value.to_i
      end

      def decimal_or_nil(value)
        return nil if value.blank?

        value.to_d
      end
    end
  end
end
