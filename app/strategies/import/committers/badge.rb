# frozen_string_literal: true

module Import
  module Committers
    #
    # = Badge
    #
    # Commits Badge entities to the production DB, mirroring the behavior
    # previously implemented inside Import::Committers::Main#commit_badge,
    # including matching semantics and detailed validation logging.
    #
    # Maintains an internal ID mapping (swimmer_id|team_id → badge_id) for efficient
    # lookups during Phase 5/6 commit, avoiding repeated DB queries within a transaction.
    #
    # Uses a reference to TeamAffiliation committer for affiliation ID lookups,
    # avoiding unreliable DB queries for uncommitted data.
    #
    class Badge
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_accessor :season_id, :meeting_id
      attr_reader :stats, :logger, :sql_log, :id_by_key

      # Creates a new Badge committer instance.
      #
      # == Options:
      # @param stats [Hash] statistics hash for tracking commit metrics
      # @param logger [Logger] logger instance for detailed logging
      # @param sql_log [Logger] logger instance for SQL query logging
      # @param swimmer_committer [Import::Committers::SwimmerAffiliation] for swimmer affiliation ID lookups
      # @param team_committer [Import::Committers::Team] for team ID lookups
      # @param team_affiliation_committer [Import::Committers::TeamAffiliation] for affiliation ID lookups
      # @param categories_cache [PdfResults::CategoriesCache] for category lookups during on-demand creation
      # @param season_id [Integer] season ID for badge creation
      # @param meeting [GogglesDb::Meeting] Meeting instance referencing meeting dates for age computation
      #
      def initialize(opts = {})
        raise 'You must specify a valid Import::Committers::Swimmer instance!' unless opts[:swimmer_committer].is_a?(Import::Committers::Swimmer)
        raise 'You must specify a valid Import::Committers::Team instance!' unless opts[:team_committer].is_a?(Import::Committers::Team)
        unless opts[:team_affiliation_committer].is_a?(Import::Committers::TeamAffiliation)
          raise 'You must specify a valid Import::Committers::TeamAffiliation instance!'
        end
        raise 'You must specify a valid PdfResults::CategoriesCache!' unless opts[:categories_cache].is_a?(PdfResults::CategoriesCache)
        raise 'You must specify a valid season_id! (Season must be already existing)' unless opts[:season_id].to_i.positive?
        raise 'You must specify a valid instance of Meeting!' unless opts[:meeting].is_a?(GogglesDb::Meeting)

        @stats = opts[:stats]
        @logger = opts[:logger]
        @sql_log = opts[:sql_log]
        @team_committer = opts[:team_committer]
        @swimmer_committer = opts[:swimmer_committer]
        @team_affiliation_committer = opts[:team_affiliation_committer]
        @categories_cache = opts[:categories_cache]
        @season_id = opts[:season_id]
        @meeting = opts[:meeting]
        @id_by_key = {} # "swimmer_key|team_key" → badge_id mapping
      end
      # -----------------------------------------------------------------------

      # Set season_id (can be set after initialization when known)
      attr_writer :categories_cache, :team_affiliation_committer

      # Generate consistent badge key for mapping
      def badge_key(swimmer_key, team_key)
        "#{swimmer_key}|#{team_key}"
      end
      # -----------------------------------------------------------------------

      # Store badge_id in mapping for later lookup using combined keys as reference
      def store_id(swimmer_key, team_key, badge_id)
        return unless swimmer_key && team_key && badge_id

        @id_by_key[badge_key(swimmer_key, team_key)] = badge_id
      end
      # -----------------------------------------------------------------------

      # Resolve badge_id from swimmer_key and team_key
      # First checks mapping, then falls back to DB query
      def resolve_id(swimmer_key, team_key)
        return nil unless swimmer_key && team_key && @season_id

        # 1. Check mapping first (populated during Phase 3 badge commit)
        cached_id = @id_by_key[badge_key(swimmer_key, team_key)]
        return cached_id if cached_id

        # 2. Fallback to DB query (for pre-existing badges)
        badge = GogglesDb::Badge.find_by(
          swimmer_id: @swimmer_committer.resolve_id(swimmer_key),
          team_id: @team_committer.resolve_id(team_key),
          season_id: @season_id
        )
        if badge
          store_id(swimmer_key, team_key, badge.id)
          return badge.id
        end

        nil
      end
      # -----------------------------------------------------------------------

      # Returns the category_type_id for the given swimmer_key based on their age.
      # Assumes all swimmers have been already committed by the Swimmer committer.
      # Uses the categories cache to find the appropriate category type.
      def resolve_category_type_id(swimmer_key)
        swimmer_id = @swimmer_committer.resolve_id(swimmer_key)
        raise "Swimmer not found for key '#{swimmer_key}'" unless GogglesDb::Swimmer.exists?(id: swimmer_id)

        swimmer = GogglesDb::Swimmer.find(swimmer_id)
        age = swimmer.age(@meeting.header_date)

        _category_code, category_type = @categories_cache.find_category_for_age(age, relay: false)
        raise "Unable to retrieve category type for swimmer '#{swimmer_key}' (age: #{age})" unless category_type

        category_type.id
      end
      # -----------------------------------------------------------------------

      # Commit a Badge entity from Phase 3 data and store ID in mapping.
      # Uses TeamAffiliation committer's mapping for affiliation ID (no DB query).
      # Returns the committed row ID or raises an error.
      def commit(badge_hash)
        badge_id = badge_hash['badge_id']
        # Prevent invalid mappings due to nil key components:
        raise StandardError, 'Null swimmer_key or team_key in datafile object!' if badge_hash['swimmer_key'].blank? || badge_hash['team_key'].blank?

        # If badge_id was resolved in previous phases, assume categories and other dependencies are already set and fixed, so bail out:
        if badge_id.present?
          store_id(badge_hash['swimmer_key'], badge_hash['team_key'], badge_id.to_i)
          Rails.logger.debug { "[Badge] ID=#{badge_id} found in datafile, caching and skipping update" }
          return badge_id.to_i
        end

        attributes = normalize_attributes(badge_hash)

        # Search #2: even if not set/recognized during phase 3, look for an existing row by season, swimmer and team ids:
        existing_row = if attributes['swimmer_id'].to_i.positive? && attributes['team_id'].to_i.positive?
                           GogglesDb::Badge.find_by(
                             season_id: attributes['season_id'] || @season_id,
                             swimmer_id: attributes['swimmer_id'].to_i,
                             team_id: attributes['team_id'].to_i
                           )
                         end

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:badges_updated] += 1
            logger.log_success(entity_type: 'Badge', entity_id: existing_row.id, action: 'updated')
            Rails.logger.info("[Badge] Updated ID=#{existing_row.id}, swimmer_id=#{attributes['swimmer_id']}, team_id=#{attributes['team_id']}")
          end
          store_id(attributes['swimmer_key'], attributes['team_key'], existing_row.id)
          return existing_row.id
        end

        # Create new row:
        model_row = GogglesDb::Badge.new(attributes)

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "Badge error (swimmer_id=#{attributes['swimmer_id']}, swimmer_key=#{attributes['swimmer_key']}, team_id=#{attributes['team_id']}, team_key=#{attributes['team_key']}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'Badge',
            entity_key: "swimmer_id=#{attributes['swimmer_id']}, swimmer_key=#{attributes['swimmer_key']}, team_id=#{attributes['team_id']}, team_key=#{attributes['team_key']}",
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[Badge] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:badges_created] += 1
        store_id(attributes['swimmer_key'], attributes['team_key'], model_row.id)
        logger.log_success(entity_type: 'Badge', entity_id: model_row.id, action: 'created')
        Rails.logger.info("[Badge] Created ID=#{model_row.id}, swimmer_id=#{model_row.swimmer_id}, team_id=#{model_row.team_id}")
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      def normalize_attributes(badge_hash)
        normalized = badge_hash.deep_dup.with_indifferent_access
        swimmer_key = normalized['swimmer_key']
        normalized['swimmer_id'] ||= @swimmer_committer.resolve_id(swimmer_key)

        team_key = normalized['team_key']
        normalized['team_id'] ||= @team_committer.resolve_id(team_key)

        normalized['category_type_id'] ||= resolve_category_type_id(swimmer_key)
        normalized['team_affiliation_id'] ||= @team_affiliation_committer.resolve_id(team_key)

        normalized['season_id'] = @season_id
        normalized['entry_time_type_id'] ||= GogglesDb::EntryTimeType::LAST_RACE_ID

        %w[off_gogglecup fees_due badge_due relays_due].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        sanitize_attributes(normalized, GogglesDb::Badge)
      end
      # -----------------------------------------------------------------------

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
