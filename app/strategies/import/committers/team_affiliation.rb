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
    class TeamAffiliation # rubocop:disable Metrics/ClassLength
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
        @id_by_link = {} # "team_id|season_id" → team_affiliation_id mapping
      end
      # -----------------------------------------------------------------------

      # Store team_affiliation_id in mapping for later lookup
      def store_id(team_key, team_affiliation_id, team_id: nil, season_id: nil)
        return unless team_affiliation_id

        @id_by_key[team_key] = team_affiliation_id if team_key.present?

        team_id = team_id.to_i
        season_id = season_id.to_i
        return unless team_id.positive? && season_id.positive?

        @id_by_link[link_key(team_id, season_id)] = team_affiliation_id
      end
      # -----------------------------------------------------------------------

      # Resolve team_affiliation_id from team_id
      # First checks mapping, then falls back to DB query
      def resolve_id(team_key, team_id: nil, season_id: nil)
        resolved_team_id = team_id.to_i.positive? ? team_id.to_i : @team_committer.resolve_id(team_key)
        resolved_season_id = season_id.to_i.positive? ? season_id.to_i : @season_id
        return nil unless resolved_team_id.to_i.positive? && resolved_season_id.to_i.positive?

        # 1. Check mapping by team+season first (canonical key)
        cached_id = @id_by_link[link_key(resolved_team_id, resolved_season_id)]
        return cached_id if cached_id

        # 2. Check fallback mapping by team_key
        cached_key_id = @id_by_key[team_key]
        if cached_key_id
          cached_row = GogglesDb::TeamAffiliation.find_by(id: cached_key_id)
          if cached_row&.team_id == resolved_team_id && cached_row&.season_id == resolved_season_id
            store_id(team_key, cached_key_id, team_id: resolved_team_id, season_id: resolved_season_id)
            return cached_key_id
          end
        end

        # 3. Fallback to DB query (for pre-existing affiliations)
        affiliation = GogglesDb::TeamAffiliation.find_by(
          team_id: resolved_team_id,
          season_id: resolved_season_id
        )
        if affiliation
          store_id(team_key, affiliation.id, team_id: affiliation.team_id, season_id: affiliation.season_id)
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

        attributes = normalize_attributes(affiliation_hash)

        # If team_affiliation_id is provided and points to a valid DB row, treat DB links as canonical:
        if team_affiliation_id.to_i.positive?
          row_by_id = GogglesDb::TeamAffiliation.find_by(id: team_affiliation_id.to_i)
          if row_by_id && stale_links?(row_by_id) == false
            if row_by_id.team_id != attributes['team_id'].to_i || row_by_id.season_id != attributes['season_id'].to_i
              increment_counter(:affiliation_links_auto_fixed)
              logger.log_operation(
                action: 'Canonicalized TeamAffiliation links from DB',
                details: "team_key='#{attributes['team_key']}', id=#{row_by_id.id}, team_id=#{row_by_id.team_id}, season_id=#{row_by_id.season_id}"
              )
            end
            store_id(attributes['team_key'], row_by_id.id, team_id: row_by_id.team_id, season_id: row_by_id.season_id)
            Rails.logger.debug { "[TeamAffiliation] ID=#{row_by_id.id} confirmed from DB, links canonicalized" }
            return row_by_id.id
          end

          # Keep going when the referenced row is missing or stale: we'll resolve/create by canonical links.
          increment_counter(:affiliation_links_auto_fixed)
          Rails.logger.warn("[TeamAffiliation] Incoming ID=#{team_affiliation_id} is missing or stale, re-resolving by team_id+season_id")
        end

        # Reuse existing row even if not set/recognized during phase 2:
        existing_row = if attributes['team_id'].to_i.positive?
                         GogglesDb::TeamAffiliation.find_by(
                           team_id: attributes['team_id'].to_i,
                           season_id: attributes['season_id'] || @season_id
                         )
                       end

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:affiliations_updated] += 1
            Rails.logger.info("[TeamAffiliation] Updated ID=#{existing_row.id}, team_id=#{attributes['team_id']}")
          end
          store_id(attributes['team_key'], existing_row.id,
                   team_id: existing_row.team_id, season_id: existing_row.season_id)
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
        store_id(attributes['team_key'], model_row.id,
                 team_id: model_row.team_id, season_id: model_row.season_id)
        logger.log_success(entity_type: 'TeamAffiliation', entity_id: model_row.id, action: 'created')
        Rails.logger.info("[TeamAffiliation] Created ID=#{model_row.id}, team_id=#{model_row.team_id}")
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      def link_key(team_id, season_id)
        "#{team_id}|#{season_id}"
      end
      # -----------------------------------------------------------------------

      def stale_links?(affiliation_row)
        return true unless affiliation_row

        GogglesDb::Team.exists?(id: affiliation_row.team_id) == false ||
          GogglesDb::Season.exists?(id: affiliation_row.season_id) == false
      end
      # -----------------------------------------------------------------------

      def increment_counter(key)
        stats[key] ||= 0
        stats[key] += 1
      end
      # -----------------------------------------------------------------------

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
