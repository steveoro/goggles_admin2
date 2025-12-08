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
      # -----------------------------------------------------------------------

      # Store team_id in mapping for later lookup
      def store_id(team_key, team_id)
        return unless team_key.present? && team_id

        @id_by_key[team_key] = team_id
      end
      # -----------------------------------------------------------------------

      # Resolve team_id from team_key using mapping
      # Tries partial key matching if direct lookup fails
      def resolve_id(team_key)
        return nil if team_key.blank?

        # 1. Check cached mapping first
        cached_id = @id_by_key[team_key]
        return cached_id if cached_id

        # 2. Fallback to DB query (using a LIKE scope on key/name)
        team = GogglesDb::Team.for_name(team_key).first
        if team
          logger.log_operation(
            action: 'Fallback query for unresolved Team key',
            details: "used name-LIKE query for team_key='#{team_key}' -> found id=#{team.id}, name=#{team.name}"
          )
          store_id(team_key, team.id)
          return team.id
        end

        nil
      end
      # -----------------------------------------------------------------------

      # Commit a Team entity and store ID in mapping.
      # Returns the committed row ID or raises an error.
      def commit(team_hash)
        team_key = team_hash['key'] # TODO: NORMALIZE field names (it should be "team_key", not "key")
        # Prevent invalid mappings due to nil key components:
        raise StandardError, 'Null team_key found in datafile object!' if team_key.blank?

        team_id = team_hash['team_id']
        attributes = normalize_attributes(team_hash)

        # Reuse existing row:
        existing_row = GogglesDb::Team.find_by(id: team_id) if team_id.to_i.positive?

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:teams_updated] += 1
            logger.log_success(entity_type: 'Team', entity_id: team_id, action: 'updated',
                               entity_key: team_key)
            Rails.logger.info("[Team] Team ID=#{team_id}")
          end
          store_id(team_key, team_id.to_i)
          return team_id.to_i
        end

        # Create new row:
        model_row = GogglesDb::Team.new(attributes)

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "Team error (team_key=#{attributes['team_key']}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'Team',
            entity_key: "team_key=#{attributes['team_key']}",
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[Team] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:teams_created] += 1
        logger.log_success(entity_type: 'Team', entity_id: model_row.id, action: 'created',
                           entity_key: model_row.name)
        Rails.logger.info("[Team] Created ID=#{model_row.id}, #{model_row.name}")
        store_id(team_key, model_row.id)
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      def normalize_attributes(team_hash)
        normalized = team_hash.deep_dup.with_indifferent_access
        normalized['editable_name'] ||= normalized['name']
        sanitize_attributes(normalized, GogglesDb::Team)
      end
      # -----------------------------------------------------------------------

      # Local copy of attribute helpers to keep behavior identical while
      # we refactor out of Main.
      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.stringify_keys.slice(*column_names)
      end
      # -----------------------------------------------------------------------

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
