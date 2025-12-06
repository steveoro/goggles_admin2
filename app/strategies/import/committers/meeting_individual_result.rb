# frozen_string_literal: true

module Import
  module Committers
    #
    # = MeetingIndividualResult
    #
    # Commits MeetingIndividualResult entities to the production DB.
    # Converts from DataImportMeetingIndividualResult temporary records.
    #
    class MeetingIndividualResult
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end

      # Commit a MeetingIndividualResult from a data_import record.
      # @param data_import_mir [GogglesDb::DataImportMeetingIndividualResult] the temp record
      # @param program_id [Integer] the resolved meeting_program_id
      # @param swimmer_id [Integer] the resolved swimmer_id (passed explicitly)
      # @param badge_id [Integer] the resolved badge_id (passed explicitly)
      # @param season_id [Integer] the season_id for resolving team_affiliation_id
      # Returns mir_id or nil.
      def commit(data_import_mir, program_id:, swimmer_id:, badge_id:, season_id: nil)
        mir_id = data_import_mir.meeting_individual_result_id
        model = nil

        # Guard clause: skip if missing required keys
        unless program_id && swimmer_id && badge_id
          stats[:errors] << "MIR error: missing required keys (program=#{program_id}, swimmer=#{swimmer_id}, badge=#{badge_id})"
          return nil
        end

        attributes = normalize_attributes(data_import_mir, program_id: program_id, swimmer_id: swimmer_id, badge_id: badge_id, season_id: season_id)

        # If MIR already has a DB ID (matched), update if needed
        if mir_id.present? && mir_id.to_i.positive?
          existing = GogglesDb::MeetingIndividualResult.find_by(id: mir_id)
          if existing
            if attributes_changed?(existing, attributes)
              existing.update!(attributes)
              sql_log << SqlMaker.new(row: existing).log_update
              stats[:mirs_updated] += 1
              logger.log_success(entity_type: 'MIR', entity_id: mir_id, action: 'updated')
              Rails.logger.info("[MIR] Updated ID=#{mir_id}")
            end
            return mir_id
          end
        end

        # Create new MIR
        model = GogglesDb::MeetingIndividualResult.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:mirs_created] += 1
        logger.log_success(entity_type: 'MIR', entity_id: model.id, action: 'created')
        Rails.logger.info("[MIR] Created ID=#{model.id}, program=#{program_id}, swimmer=#{data_import_mir.swimmer_id}, rank=#{model.rank}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        entity_key = data_import_mir.import_key
        stats[:errors] << "MIR error (#{entity_key}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'MeetingIndividualResult',
          entity_key: entity_key,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[MIR] ERROR: #{error_details}")
        raise
      end

      private

      # Resolve team_affiliation_id from team_id and season_id
      # Must be called after badge_id is resolved (badge has season reference)
      def resolve_team_affiliation_id(team_id, season_id)
        return nil unless team_id && season_id

        affiliation = GogglesDb::TeamAffiliation.find_by(
          team_id: team_id,
          season_id: season_id
        )
        affiliation&.id
      end

      def normalize_attributes(data_import_mir, program_id:, swimmer_id:, badge_id:, season_id: nil)
        # Resolve team_affiliation_id from team_id and season_id
        team_affiliation_id = resolve_team_affiliation_id(data_import_mir.team_id, season_id)

        {
          'meeting_program_id' => program_id,
          'swimmer_id' => swimmer_id,
          'team_id' => data_import_mir.team_id,
          'team_affiliation_id' => team_affiliation_id,
          'badge_id' => badge_id,
          'rank' => integer_or_nil(data_import_mir.rank),
          'minutes' => integer_or_nil(data_import_mir.minutes),
          'seconds' => integer_or_nil(data_import_mir.seconds),
          'hundredths' => integer_or_nil(data_import_mir.hundredths),
          'standard_points' => decimal_or_nil(data_import_mir.standard_points),
          'meeting_points' => decimal_or_nil(data_import_mir.meeting_points),
          'out_of_race' => data_import_mir.out_of_race || false,
          'disqualified' => data_import_mir.disqualified || false,
          'disqualification_code_type_id' => data_import_mir.disqualification_code_type_id,
          'reaction_time' => decimal_or_nil(data_import_mir.reaction_time)
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

      def attributes_changed?(model, new_attributes)
        new_attributes.except('id', :id).any? do |key, value|
          model_value = begin
            model.send(key.to_sym)
          rescue NoMethodError
            nil
          end
          model_value != value
        end
      end
    end
  end
end
