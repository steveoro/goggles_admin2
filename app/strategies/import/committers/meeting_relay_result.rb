# frozen_string_literal: true

module Import
  module Committers
    #
    # = MeetingRelayResult
    #
    # Commits MeetingRelayResult entities to the production DB.
    # Converts from DataImportMeetingRelayResult temporary records.
    #
    class MeetingRelayResult
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end
      # -----------------------------------------------------------------------

      # Commit a MeetingRelayResult from a data_import record.
      # @param data_import_mrr [GogglesDb::DataImportMeetingRelayResult] the temp record
      # @param program_id [Integer] the resolved meeting_program_id
      # @param season_id [Integer] the season_id for resolving team_affiliation_id
      # Returns the committed row ID or raises an error.
      def commit(data_import_mrr, program_id:, season_id: nil)
        mrr_id = data_import_mrr.meeting_relay_result_id
        model = nil

        # Guard clause: skip if missing required keys
        unless program_id && data_import_mrr.team_id
          msg = "MRR error: missing required keys (program=#{program_id}, team=#{data_import_mrr.team_id})"
          stats[:errors] << msg
          raise StandardError, msg
        end

        attributes = normalize_attributes(data_import_mrr, program_id: program_id, season_id: season_id)

        # If MRR already has a DB ID (matched), update if needed
        if mrr_id.present? && mrr_id.to_i.positive?
          existing = GogglesDb::MeetingRelayResult.find_by(id: mrr_id)
          if existing
            if attributes_changed?(existing, attributes)
              existing.update!(attributes)
              sql_log << SqlMaker.new(row: existing).log_update
              stats[:mrrs_updated] += 1
              logger.log_success(entity_type: 'MRR', entity_id: mrr_id, action: 'updated')
              Rails.logger.info("[MRR] Updated ID=#{mrr_id}")
            end
            return mrr_id
          end
        end

        # Create new MRR
        model = GogglesDb::MeetingRelayResult.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:mrrs_created] += 1
        logger.log_success(entity_type: 'MRR', entity_id: model.id, action: 'created')
        Rails.logger.info("[MRR] Created ID=#{model.id}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        entity_key = data_import_mrr.import_key
        stats[:errors] << "MRR error (#{entity_key}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'MeetingRelayResult',
          entity_key: entity_key,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[MRR] ERROR: #{error_details}")
        raise
      end
      # -----------------------------------------------------------------------

      private

      # Resolve team_affiliation_id from team_id and season_id
      def resolve_team_affiliation_id(team_id, season_id)
        return nil unless team_id && season_id

        affiliation = GogglesDb::TeamAffiliation.find_by(
          team_id: team_id,
          season_id: season_id
        )
        affiliation&.id
      end
      # -----------------------------------------------------------------------

      def normalize_attributes(data_import_mrr, program_id:, season_id: nil)
        # Resolve team_affiliation_id from team_id and season_id
        team_affiliation_id = resolve_team_affiliation_id(data_import_mrr.team_id, season_id)

        {
          'meeting_program_id' => program_id,
          'team_id' => data_import_mrr.team_id,
          'team_affiliation_id' => team_affiliation_id,
          'rank' => integer_or_nil(data_import_mrr.rank),
          'minutes' => integer_or_nil(data_import_mrr.minutes),
          'seconds' => integer_or_nil(data_import_mrr.seconds),
          'hundredths' => integer_or_nil(data_import_mrr.hundredths),
          'standard_points' => decimal_or_nil(data_import_mrr.standard_points),
          'meeting_points' => decimal_or_nil(data_import_mrr.meeting_points),
          'out_of_race' => data_import_mrr.out_of_race || false,
          'disqualified' => data_import_mrr.disqualified || false,
          'disqualification_code_type_id' => data_import_mrr.disqualification_code_type_id,
          'reaction_time' => decimal_or_nil(data_import_mrr.reaction_time)
        }.compact
      end
      # -----------------------------------------------------------------------

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
      # -----------------------------------------------------------------------
    end
  end
end
