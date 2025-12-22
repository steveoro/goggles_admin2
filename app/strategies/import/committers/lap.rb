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
      # @param data_import_mir [GogglesDb::DataImportMeetingIndividualResult] parent MIR record
      # Returns the committed row ID or raises an error.
      def commit(data_import_lap, data_import_mir:)
        mir_id = data_import_mir.meeting_individual_result_id
        lap_length = data_import_lap.length_in_meters
        model = nil

        # Guard clause: skip if missing required keys
        unless mir_id && lap_length
          stats[:errors] << "Lap error: missing required keys (mir=#{mir_id}, length=#{lap_length})"
          return nil
        end

        attributes = normalize_attributes(data_import_lap, data_import_mir:)

        # Match by parent MIR ID + lap distance
        existing = GogglesDb::Lap.find_by(
          meeting_individual_result_id: mir_id,
          length_in_meters: lap_length
        )

        if existing
          if attributes_changed?(existing, attributes)
            existing.update!(attributes)
            sql_log << SqlMaker.new(row: existing).log_update
            stats[:laps_updated] += 1
            logger.log_success(entity_type: 'Lap', entity_id: existing.id, action: 'updated')
            Rails.logger.info("[Lap] Updated ID=#{existing.id}")
          end
          return existing.id
        end

        # Create new lap
        model = GogglesDb::Lap.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:laps_created] += 1
        logger.log_success(entity_type: 'Lap', entity_id: model.id, action: 'created')
        Rails.logger.info("[Lap] Created ID=#{model.id}")
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

      # Check if any attribute values differ between existing record and new attributes
      def attributes_changed?(existing, attributes)
        attributes.any? do |key, value|
          existing_value = existing.send(key)
          # Compare as strings to handle type differences (e.g., Integer vs String)
          existing_value.to_s != value.to_s
        end
      end

      def normalize_attributes(data_import_lap, data_import_mir:)
        {
          'meeting_program_id' => data_import_mir.meeting_program_id,
          'meeting_individual_result_id' => data_import_mir.meeting_individual_result_id,
          'length_in_meters' => integer_or_nil(data_import_lap.length_in_meters),
          'swimmer_id' => data_import_mir.swimmer_id,
          'team_id' => data_import_mir.team_id,
          'minutes' => integer_or_nil(data_import_lap.minutes),
          'seconds' => integer_or_nil(data_import_lap.seconds),
          'hundredths' => integer_or_nil(data_import_lap.hundredths),
          'minutes_from_start' => integer_or_nil(data_import_lap.minutes_from_start),
          'seconds_from_start' => integer_or_nil(data_import_lap.seconds_from_start),
          'hundredths_from_start' => integer_or_nil(data_import_lap.hundredths_from_start),
          'reaction_time' => decimal_or_nil(data_import_lap.reaction_time),
          'position' => nil # # Currently not stored in data_import_* tables: integer_or_nil(data_import_lap.position)
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
