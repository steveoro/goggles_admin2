# frozen_string_literal: true

module Import
  module Committers
    #
    # = TeamAffiliation
    #
    # Commits TeamAffiliation entities to the production DB, mirroring the
    # behavior previously implemented inside Import::Committers::Main#commit_team_affiliation.
    #
    class TeamAffiliation
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end

      def prepare_model(affiliation_hash)
        team_id = affiliation_hash['team_id'] || affiliation_hash[:team_id]
        season_id = affiliation_hash['season_id'] || affiliation_hash[:season_id]
        team = GogglesDb::Team.find_by(id: team_id)
        attributes = normalize_attributes(affiliation_hash, team_id: team_id, season_id: season_id, team: team)
        GogglesDb::TeamAffiliation.new(attributes)
      end

      # Commit a TeamAffiliation entity.
      # Returns team_affiliation_id or nil (affiliation is implicit via existing row).
      def commit(affiliation_hash)
        team_affiliation_id = affiliation_hash['team_affiliation_id'] || affiliation_hash[:team_affiliation_id]
        team_id = affiliation_hash['team_id'] || affiliation_hash[:team_id]
        season_id = affiliation_hash['season_id'] || affiliation_hash[:season_id]
        model = nil

        # Guard clause: skip if missing required keys
        return unless team_id && season_id

        # If team_affiliation_id exists, it's already in DB - skip
        if team_affiliation_id.present?
          Rails.logger.debug { "[Main] TeamAffiliation ID=#{team_affiliation_id} already exists, skipping" }
          return team_affiliation_id
        end

        team = GogglesDb::Team.find_by(id: team_id)
        attributes = normalize_attributes(affiliation_hash, team_id: team_id, season_id: season_id, team: team)

        # Fallback: reuse existing team affiliation when one already exists for the same team/season
        existing = GogglesDb::TeamAffiliation.find_by(team_id: team_id, season_id: season_id)
        if existing
          if attributes_changed?(existing, attributes)
            existing.update!(attributes)
            sql_log << SqlMaker.new(row: existing).log_update
            Rails.logger.info("[Main] Updated TeamAffiliation ID=#{existing.id}, team_id=#{team_id}, season_id=#{season_id}")
          end
          return existing.id
        end

        # Create new affiliation (minimal data - just links team to season)
        model = GogglesDb::TeamAffiliation.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:affiliations_created] += 1
        Rails.logger.info("[Main] Created TeamAffiliation ID=#{model.id}, team_id=#{team_id}, season_id=#{season_id}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        stats[:errors] << "TeamAffiliation error (team_id=#{team_id}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'TeamAffiliation',
          entity_key: "team_id=#{team_id},season_id=#{season_id}",
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR creating affiliation: #{error_details}")
        raise
      end

      private

      def normalize_attributes(affiliation_hash, team_id:, season_id:, team:)
        normalized = affiliation_hash.deep_dup.with_indifferent_access
        normalized['team_id'] = team_id
        normalized['season_id'] = season_id
        normalized['name'] = normalized['name'].presence || team&.name
        if normalized.key?('compute_gogglecup') || normalized.key?(:compute_gogglecup)
          normalized['compute_gogglecup'] = BOOLEAN_TYPE.cast(normalized['compute_gogglecup'])
        end
        normalized['autofilled'] = BOOLEAN_TYPE.cast(normalized['autofilled']) if normalized.key?('autofilled') || normalized.key?(:autofilled)

        sanitized = sanitize_attributes(normalized, GogglesDb::TeamAffiliation)
        sanitized['name'] ||= team&.name || ''
        sanitized
      end

      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.slice(*column_names).except('id').stringify_keys
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
