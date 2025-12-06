# frozen_string_literal: true

module Import
  module Committers
    #
    # = TeamAffiliation
    #
    # Commits TeamAffiliation entities to the production DB, mirroring the
    # behavior previously implemented inside Import::Committers::Main#commit_team_affiliation.
    #
    # Maintains an internal ID mapping (team_id → team_affiliation_id) for efficient
    # lookups during later phases, avoiding repeated DB queries within a transaction.
    #
    class TeamAffiliation
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_accessor :season_id
      attr_reader :stats, :logger, :sql_log, :id_by_team

      def initialize(stats:, logger:, sql_log:, season_id: nil)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
        @season_id = season_id
        @id_by_team = {} # team_id → team_affiliation_id mapping
      end

      # Set season_id (can be set after initialization when known)

      # Store team_affiliation_id in mapping for later lookup
      def store_id(team_id, team_affiliation_id)
        return unless team_id && team_affiliation_id

        @id_by_team[team_id.to_i] = team_affiliation_id
      end

      # Lookup team_affiliation_id from mapping by team_id
      def lookup_id(team_id)
        return nil unless team_id

        @id_by_team[team_id.to_i]
      end

      # Resolve team_affiliation_id from team_id
      # First checks mapping, then falls back to DB query
      # Does NOT create on-demand - use create_on_demand for that
      def resolve_id(team_id)
        return nil unless team_id && @season_id

        # 1. Check mapping first (populated during Phase 2)
        cached_id = lookup_id(team_id)
        return cached_id if cached_id

        # 2. Fallback to DB query (for pre-existing affiliations)
        affiliation = GogglesDb::TeamAffiliation.find_by(
          team_id: team_id,
          season_id: @season_id
        )
        if affiliation
          store_id(team_id, affiliation.id)
          return affiliation.id
        end

        nil
      end

      # Create a team_affiliation on-demand
      # Used when a team needs an affiliation for badge creation
      def create_on_demand(team_id)
        return nil unless team_id && @season_id

        team = GogglesDb::Team.find_by(id: team_id)
        return nil unless team

        affiliation = GogglesDb::TeamAffiliation.create!(
          team_id: team_id,
          season_id: @season_id,
          name: team.editable_name || team.name,
          number: "AUTO-#{team_id}"
        )
        sql_log << SqlMaker.new(row: affiliation).log_insert
        stats[:affiliations_created] += 1
        store_id(team_id, affiliation.id)
        Rails.logger.info("[TeamAffiliation] Created on-demand ID=#{affiliation.id}, team_id=#{team_id}")
        affiliation.id
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
          entity_key: "team_id=#{team_id},season_id=#{hash_season_id}",
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[TeamAffiliation] ERROR creating on-demand: #{error_details}")
        raise
      end

      # Resolve and create on-demand if needed
      def resolve_or_create(team_id)
        affiliation_id = resolve_id(team_id)
        return affiliation_id if affiliation_id

        create_on_demand(team_id)
      end

      def prepare_model(affiliation_hash)
        team_id = affiliation_hash['team_id'] || affiliation_hash[:team_id]
        season_id = affiliation_hash['season_id'] || affiliation_hash[:season_id]
        team = GogglesDb::Team.find_by(id: team_id)
        attributes = normalize_attributes(affiliation_hash, team_id: team_id, season_id: season_id, team: team)
        GogglesDb::TeamAffiliation.new(attributes)
      end

      # Commit a TeamAffiliation entity and store ID in mapping.
      # Returns team_affiliation_id or nil.
      def commit(affiliation_hash)
        team_affiliation_id = affiliation_hash['team_affiliation_id'] || affiliation_hash[:team_affiliation_id]
        team_id = affiliation_hash['team_id'] || affiliation_hash[:team_id]
        hash_season_id = affiliation_hash['season_id'] || affiliation_hash[:season_id]
        model = nil

        # Guard clause: skip if missing required keys
        return unless team_id && hash_season_id

        # If team_affiliation_id exists, it's already in DB - store and skip
        if team_affiliation_id.present?
          store_id(team_id, team_affiliation_id.to_i)
          Rails.logger.debug { "[TeamAffiliation] ID=#{team_affiliation_id} already exists, stored in mapping" }
          return team_affiliation_id.to_i
        end

        team = GogglesDb::Team.find_by(id: team_id)
        attributes = normalize_attributes(affiliation_hash, team_id: team_id, season_id: hash_season_id, team: team)

        # Fallback: reuse existing team affiliation when one already exists for the same team/season
        existing = GogglesDb::TeamAffiliation.find_by(team_id: team_id, season_id: hash_season_id)
        if existing
          if attributes_changed?(existing, attributes)
            existing.update!(attributes)
            sql_log << SqlMaker.new(row: existing).log_update
            Rails.logger.info("[TeamAffiliation] Updated ID=#{existing.id}, team_id=#{team_id}, season_id=#{hash_season_id}")
          end
          store_id(team_id, existing.id)
          return existing.id
        end

        # Create new affiliation (minimal data - just links team to season)
        model = GogglesDb::TeamAffiliation.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:affiliations_created] += 1
        store_id(team_id, model.id)
        Rails.logger.info("[TeamAffiliation] Created ID=#{model.id}, team_id=#{team_id}, season_id=#{hash_season_id}")
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
          entity_key: "team_id=#{team_id},season_id=#{hash_season_id}",
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[TeamAffiliation] ERROR creating: #{error_details}")
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
