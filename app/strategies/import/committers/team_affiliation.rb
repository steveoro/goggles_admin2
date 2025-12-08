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
      attr_reader :stats, :logger, :sql_log, :id_by_key

      # Creates a new Team committer instance.
      #
      # == Options:
      # @param stats [Hash] statistics hash for tracking commit metrics
      # @param logger [Logger] logger instance for detailed logging
      # @param sql_log [Logger] logger instance for SQL query logging
      # @param team_committer [Import::Committers::Team] for team ID lookups
      # @param season_id [Integer] season ID for badge creation
      #
      def initialize(opts = {})
        raise 'You must specify a valid Import::Committers::Team instance!' unless opts[:team_committer].is_a?(Import::Committers::Team)
        raise 'You must specify a valid season_id! (Season must be already existing)' unless opts[:season_id].to_i.positive?

        @stats = opts[:stats]
        @logger = opts[:logger]
        @sql_log = opts[:sql_log]
        @team_committer = opts[:team_committer]
        @season_id = opts[:season_id]
        @id_by_key = {} # "team_key" → team_affiliation_id mapping
      end
      # -----------------------------------------------------------------------

      # Store team_affiliation_id in mapping for later lookup
      def store_id(team_key, team_affiliation_id)
        return unless team_key && team_affiliation_id

        @id_by_key[team_key] = team_affiliation_id
      end
      # -----------------------------------------------------------------------

      # Resolve team_affiliation_id from team_id
      # First checks mapping, then falls back to DB query
      def resolve_id(team_key)
        return nil unless team_key

        # 1. Check mapping first (populated during Phase 2)
        cached_id = @id_by_key[team_key]
        return cached_id if cached_id

        # 2. Fallback to DB query (for pre-existing affiliations)
        affiliation = GogglesDb::TeamAffiliation.find_by(
          team_id: @team_committer.resolve_id(team_key),
          season_id: @season_id
        )
        if affiliation
          store_id(team_key, affiliation.id)
          return affiliation.id
        end

        nil
      end
      # -----------------------------------------------------------------------

      # Commit a TeamAffiliation entity from Phase 2 data and store ID in mapping.
      # Returns the committed row ID or raises an error.
      def commit(affiliation_hash)
        team_affiliation_id = affiliation_hash['team_affiliation_id']
        # Prevent invalid mappings due to nil key components:
        raise StandardError, 'Null team_key found in datafile object!' if affiliation_hash['team_key'].blank?

        # If team_affiliation_id was resolved in previous phases, assume all dependencies are already set and fixed, so bail out:
        if team_affiliation_id.present?
          store_id(affiliation_hash['team_key'], team_affiliation_id.to_i)
          Rails.logger.debug { "[TeamAffiliation] ID=#{team_affiliation_id} found in datafile, caching and skipping update" }
          return team_affiliation_id.to_i
        end

        attributes = normalize_attributes(affiliation_hash)

        # Reuse existing row even if not set/recognized during phase 2:
        existing_row = if attributes['team_id'].to_i.positive?
                         GogglesDb::TeamAffiliation.find_by(
                           team_id:  attributes['team_id'].to_i,
                           season_id: attributes['season_id'] || @season_id,
                         )
                       end

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:affiliations_updated] += 1
            Rails.logger.info("[TeamAffiliation] Updated ID=#{existing_row.id}, team_id=#{attributes['team_id']}")
          end
          store_id(attributes['team_key'], existing_row.id)
          return existing_row.id
        end

        # Create new row:
        model_row = GogglesDb::TeamAffiliation.new(attributes)

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "TeamAffiliation error (team_id=#{attributes['team_id']}, team_key=#{attributes['team_key']}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'TeamAffiliation',
            entity_key: "team_id=#{attributes['team_id']}, team_key=#{attributes['team_key']}",
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[TeamAffiliation] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:affiliations_created] += 1
        store_id(attributes['team_key'], model_row.id)
        logger.log_success(entity_type: 'TeamAffiliation', entity_id: model_row.id, action: 'created')
        Rails.logger.info("[TeamAffiliation] Created ID=#{model_row.id}, team_id=#{model_row.team_id}")
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      def normalize_attributes(affiliation_hash)
        normalized = affiliation_hash.deep_dup.with_indifferent_access
        team_key = normalized['team_key'] # (already checked for presence in commit method)
        normalized['team_id'] ||= @team_committer.resolve_id(team_key)
        normalized['season_id'] ||= @season_id
        normalized['name'] ||= team_key # Best candidate: team.editable_name || team.name
        # (Needs something like team = GogglesDb::Team.find(normalized['team_id']), but that's an additional query
        #  for something we have already on phase 2 datafile -- better to extract it from there)

        %w[compute_gogglecup autofilled].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        sanitize_attributes(normalized, GogglesDb::TeamAffiliation)
      end
      # -----------------------------------------------------------------------

      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.slice(*column_names).except('id').stringify_keys
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
