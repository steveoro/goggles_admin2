# frozen_string_literal: true

module Import
  module Committers
    #
    # = Team
    #
    # Commits Team entities to the production DB, mirroring the behavior
    # previously implemented inside Import::Committers::Main#commit_team
    # (including matching semantics to avoid duplicates).
    #
    # Maintains an internal ID mapping (team_key → team_id) for efficient
    # lookups during later phases.
    #
    class Team
      attr_reader :stats, :logger, :sql_log, :id_by_key

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
        @id_by_key = {} # team_key → team_id mapping
      end

      # Store team_id in mapping for later lookup
      def store_id(team_key, team_id)
        return unless team_key.present? && team_id

        @id_by_key[team_key] = team_id
      end

      # Lookup team_id from mapping by key
      def lookup_id(team_key)
        return nil if team_key.blank?

        @id_by_key[team_key]
      end

      def prepare_model(team_hash)
        attributes = normalize_attributes(team_hash)
        GogglesDb::Team.new(attributes)
      end

      # Commit a Team entity and store ID in mapping.
      # Returns team_id or nil.
      def commit(team_hash)
        team_key = team_hash['key']
        team_id = team_hash['team_id']
        normalized_attributes = normalize_attributes(team_hash)
        model = nil

        # If team already has a DB ID, it's matched - just verify or update if needed
        if team_id.present? && team_id.to_i.positive?
          team = GogglesDb::Team.find_by(id: team_id)
          if team && attributes_changed?(team, normalized_attributes)
            team.update!(normalized_attributes)
            sql_log << SqlMaker.new(row: team).log_update
            stats[:teams_updated] += 1
            logger.log_success(entity_type: 'Team', entity_id: team_id, action: 'updated',
                               entity_key: team.name)
            Rails.logger.info("[Team] Updated Team ID=#{team_id}")
          end
          store_id(team_key, team_id.to_i)
          return team_id.to_i
        end

        # Fallback: try to match an existing team by name when team_id is missing
        existing = nil
        team_name = normalized_attributes['name']
        existing = GogglesDb::Team.find_by(name: team_name) if team_name.present?

        if existing
          if attributes_changed?(existing, normalized_attributes)
            existing.update!(normalized_attributes)
            sql_log << SqlMaker.new(row: existing).log_update
            stats[:teams_updated] += 1
            logger.log_success(entity_type: 'Team', entity_id: existing.id, action: 'updated',
                               entity_key: existing.name)
            Rails.logger.info("[Team] Updated Team ID=#{existing.id} (matched by name)")
          end
          store_id(team_key, existing.id)
          return existing.id
        end

        # Create new team (team_id is nil or 0 and no existing match found)
        model = prepare_model(team_hash)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:teams_created] += 1
        logger.log_success(entity_type: 'Team', entity_id: model.id, action: 'created',
                           entity_key: model.name)
        Rails.logger.info("[Team] Created Team ID=#{model.id}, name=#{model.name}")
        store_id(team_key, model.id)
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        stats[:errors] << "Team error (#{team_hash['key']}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'Team',
          entity_key: team_hash['key'] || team_name,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR committing team: #{error_details}")
        raise
      end

      private

      def normalize_attributes(team_hash)
        normalized = team_hash.deep_dup.with_indifferent_access
        normalized['editable_name'] ||= normalized['name']
        sanitize_attributes(normalized, GogglesDb::Team)
      end

      # Local copy of attribute helpers to keep behavior identical while
      # we refactor out of Main.
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
