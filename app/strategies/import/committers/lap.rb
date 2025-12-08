# frozen_string_literal: true

module Import
  module Committers
    #
    # = Lap
    #
    # Commits Lap entities to the production DB.
    # Converts from DataImportLap temporary records.
    #
    class Lap
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end

      # Commit a Lap from a data_import record.
      # @param data_import_lap [GogglesDb::DataImportLap] the temp record
      # @param mir_id [Integer] the resolved meeting_individual_result_id
      # Returns the committed row ID or raises an error.
      def commit(data_import_lap, mir_id:)
        model = nil

        # Guard clause: skip if missing required keys
        unless mir_id && data_import_lap.length_in_meters
          stats[:errors] << "Lap error: missing required keys (mir=#{mir_id}, length=#{data_import_lap.length_in_meters})"
          return nil
        end

        attributes = normalize_attributes(data_import_lap, mir_id: mir_id)

        # Create new lap (no matching logic for laps - they're always new)
        model = GogglesDb::Lap.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:laps_created] += 1
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        entity_key = data_import_lap.import_key
        stats[:errors] << "Lap error (#{entity_key}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'Lap',
          entity_key: entity_key,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Lap] ERROR: #{error_details}")
        raise
      end

      private

      def normalize_attributes(data_import_lap, mir_id:)
        {
          'meeting_individual_result_id' => mir_id,
          'length_in_meters' => integer_or_nil(data_import_lap.length_in_meters),
          'swimmer_id' => data_import_lap.swimmer_id,
          'team_id' => data_import_lap.team_id,
          'minutes' => integer_or_nil(data_import_lap.minutes),
          'seconds' => integer_or_nil(data_import_lap.seconds),
          'hundredths' => integer_or_nil(data_import_lap.hundredths),
          'minutes_from_start' => integer_or_nil(data_import_lap.minutes_from_start),
          'seconds_from_start' => integer_or_nil(data_import_lap.seconds_from_start),
          'hundredths_from_start' => integer_or_nil(data_import_lap.hundredths_from_start),
          'reaction_time' => decimal_or_nil(data_import_lap.reaction_time),
          'position' => integer_or_nil(data_import_lap.position)
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
