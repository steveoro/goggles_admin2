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

      # @param team_affiliation_committer [Import::Committers::TeamAffiliation] for affiliation ID lookups
      # @param categories_cache [PdfResults::CategoriesCache] for category lookups during on-demand creation
      def initialize(stats:, logger:, sql_log:, team_affiliation_committer: nil, categories_cache: nil, season_id: nil, meeting_id: nil)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
        @team_affiliation_committer = team_affiliation_committer
        @categories_cache = categories_cache
        @season_id = season_id
        @meeting_id = meeting_id
        @id_by_key = {} # "swimmer_id|team_id" → badge_id mapping
      end

      # Set season_id (can be set after initialization when known)
      attr_writer :categories_cache, :team_affiliation_committer

      # Generate consistent badge key for mapping
      def badge_key(swimmer_id, team_id)
        "#{swimmer_id}|#{team_id}"
      end

      # Store badge_id in mapping for later lookup
      def store_id(swimmer_id, team_id, badge_id)
        return unless swimmer_id && team_id && badge_id

        key = badge_key(swimmer_id, team_id)
        @id_by_key[key] = badge_id
      end

      # Lookup badge_id from mapping
      def lookup_id(swimmer_id, team_id)
        return nil unless swimmer_id && team_id

        key = badge_key(swimmer_id, team_id)
        @id_by_key[key]
      end

      # Resolve badge_id from swimmer_id and team_id
      # First checks mapping, then falls back to DB query
      # Does NOT create on-demand - use resolve_or_create for that
      def resolve_id(swimmer_id, team_id)
        return nil unless swimmer_id && team_id && @season_id

        # 1. Check mapping first (populated during Phase 3 badge commit)
        cached_badge_id = lookup_id(swimmer_id, team_id)
        return cached_badge_id if cached_badge_id

        # 2. Fallback to DB query (for pre-existing badges)
        badge = GogglesDb::Badge.find_by(
          swimmer_id: swimmer_id,
          team_id: team_id,
          season_id: @season_id
        )
        if badge
          store_id(swimmer_id, team_id, badge.id)
          return badge.id
        end

        nil
      end

      # Resolve badge_id and create on-demand if not found
      def resolve_or_create(swimmer_id, team_id)
        badge_id = resolve_id(swimmer_id, team_id)
        return badge_id if badge_id

        create_on_demand(swimmer_id, team_id)
      end

      # Create a badge on-demand during Phase 6 commit
      # Used when a swimmer has results but no pre-existing badge
      def create_on_demand(swimmer_id, team_id)
        return nil unless swimmer_id && team_id && @season_id

        # Get team_affiliation_id from the TeamAffiliation committer's mapping (no DB query)
        team_affiliation_id = @team_affiliation_committer&.resolve_or_create(team_id)
        unless team_affiliation_id
          @stats[:errors] << "Badge error: Cannot create badge for swimmer_id=#{swimmer_id}, team_id=#{team_id} (no TeamAffiliation)"
          Rails.logger.warn("[Badge] Cannot create: TeamAffiliation not found for team_id=#{team_id}, season_id=#{@season_id}")
          return nil
        end

        # Find swimmer to compute category
        swimmer = GogglesDb::Swimmer.find_by(id: swimmer_id)
        unless swimmer
          Rails.logger.warn("[Badge] Cannot create: Swimmer not found for swimmer_id=#{swimmer_id}")
          return nil
        end

        # Compute category from swimmer's year of birth and meeting year
        meeting = GogglesDb::Meeting.find_by(id: @meeting_id)
        unless meeting
          Rails.logger.warn("[Badge] Cannot create: Meeting not found for meeting_id=#{@meeting_id}")
          return nil
        end

        meeting_year = meeting.header_date&.year || Date.current.year
        age = meeting_year - swimmer.year_of_birth.to_i

        # Use categories cache for efficient lookup (fallback to DB if cache unavailable)
        category_type = nil
        if @categories_cache
          result = @categories_cache.find_category_for_age(age, relay: false)
          _category_code, category_type = result if result
        end

        # Fallback to direct DB query if cache miss or unavailable
        category_type ||= GogglesDb::CategoryType
                          .where(season_id: @season_id, relay: false)
                          .where('age_begin <= ? AND age_end >= ?', age, age)
                          .where(undivided: false)
                          .first

        unless category_type
          @stats[:errors] << "Badge error: No category found for swimmer_id=#{swimmer_id}, age=#{age}"
          Rails.logger.warn("[Badge] Cannot create: No category found for age=#{age}, season_id=#{@season_id}")
          return nil
        end

        # Create the badge
        badge = GogglesDb::Badge.create!(
          swimmer_id: swimmer_id,
          team_id: team_id,
          season_id: @season_id,
          team_affiliation_id: team_affiliation_id,
          category_type_id: category_type.id,
          number: "AUTO-#{swimmer_id}-#{team_id}"
        )
        sql_log << SqlMaker.new(row: badge).log_insert
        stats[:badges_created] += 1
        store_id(swimmer_id, team_id, badge.id)
        logger.log_success(entity_type: 'Badge', entity_id: badge.id, action: 'created (on-demand)')
        Rails.logger.info("[Badge] Created on-demand ID=#{badge.id}, swimmer_id=#{swimmer_id}, team_id=#{team_id}")
        badge.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record
        error_details = model_row ? GogglesDb::ValidationErrorTools.recursive_error_for(model_row) : e.message
        stats[:errors] << "Badge error (swimmer_id=#{swimmer_id}, team_id=#{team_id}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'Badge',
          entity_key: "swimmer_id=#{swimmer_id},team_id=#{team_id},season_id=#{@season_id}",
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Badge] ERROR creating on-demand: #{error_details}")
        raise
      end

      # Commit a Badge entity from Phase 3 data and store ID in mapping.
      # Uses TeamAffiliation committer's mapping for affiliation ID (no DB query).
      # Returns badge_id or nil.
      def commit(badge_hash)
        badge_id = badge_hash['badge_id']
        swimmer_id = badge_hash['swimmer_id']
        team_id = badge_hash['team_id']
        hash_season_id = badge_hash['season_id']
        category_type_id = badge_hash['category_type_id']
        model = nil

        # Guard clause: skip if missing required keys
        unless swimmer_id && team_id && hash_season_id
          logger.log_error(
            message: "Can't create row: missing required keys.", entity_type: 'Badge',
            entity_key: "swimmer: #{badge_hash['swimmer_key']} / team: #{badge_hash['team_key']} / season: #{hash_season_id}"
          )
          return
        end

        # If badge_id exists, it's already in DB - store and skip
        if badge_id.present?
          store_id(swimmer_id, team_id, badge_id.to_i)
          Rails.logger.debug { "[Badge] ID=#{badge_id} already exists, stored in mapping" }
          return badge_id.to_i
        end

        # Get team_affiliation_id from the TeamAffiliation committer's mapping (no unreliable DB query)
        team_affiliation_id = @team_affiliation_committer&.lookup_id(team_id)
        team_affiliation_id ||= @team_affiliation_committer&.resolve_id(team_id)
        unless team_affiliation_id
          stats[:errors] << "Badge error: TeamAffiliation not found in mapping for team_id=#{team_id}, season_id=#{hash_season_id}"
          Rails.logger.error('[Badge] ERROR: TeamAffiliation not found in mapping for badge creation')
          return
        end

        attributes = normalize_attributes(
          badge_hash,
          swimmer_id: swimmer_id,
          team_id: team_id,
          season_id: hash_season_id,
          category_type_id: category_type_id,
          team_affiliation_id: team_affiliation_id
        )

        # Fallback: reuse existing badge when one already exists for the same swimmer/team/season
        existing_badge = GogglesDb::Badge.find_by(
          season_id: hash_season_id,
          swimmer_id: swimmer_id,
          team_id: team_id
        )

        if existing_badge
          if attributes_changed?(existing_badge, attributes)
            existing_badge.update!(attributes)
            sql_log << SqlMaker.new(row: existing_badge).log_update
            logger.log_success(entity_type: 'Badge', entity_id: existing_badge.id, action: 'updated')
            Rails.logger.info("[Badge] Updated ID=#{existing_badge.id}, swimmer_id=#{swimmer_id}, team_id=#{team_id}")
          end
          store_id(swimmer_id, team_id, existing_badge.id)
          return existing_badge.id
        end

        model = GogglesDb::Badge.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:badges_created] += 1
        store_id(swimmer_id, team_id, model.id)
        logger.log_success(entity_type: 'Badge', entity_id: model.id, action: 'created')
        Rails.logger.info("[Badge] Created ID=#{model.id}, swimmer_id=#{swimmer_id}, team_id=#{team_id}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        swimmer_key = badge_hash['swimmer_key'] || badge_hash[:swimmer_key]
        team_key = badge_hash['team_key'] || badge_hash[:team_key]
        stats[:errors] << "Badge error (swimmer_key=#{swimmer_key}, swimmer_id=#{swimmer_id}, team_id=#{team_id}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'Badge',
          entity_key: "swimmer_key=#{swimmer_key},swimmer_id=#{swimmer_id},team_id=#{team_id},team_key=#{team_key},season_id=#{hash_season_id}",
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Badge] ERROR creating: #{error_details}")
        raise
      end

      private

      def normalize_attributes(badge_hash, swimmer_id:, team_id:, season_id:, category_type_id:, team_affiliation_id:)
        normalized = badge_hash.deep_dup.with_indifferent_access
        normalized['swimmer_id'] = swimmer_id
        normalized['team_id'] = team_id
        normalized['season_id'] = season_id
        normalized['category_type_id'] ||= category_type_id
        normalized['team_affiliation_id'] = team_affiliation_id

        default_entry_time = GogglesDb::EntryTimeType.manual
        normalized['entry_time_type_id'] ||= default_entry_time&.id

        %w[off_gogglecup fees_due badge_due relays_due].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        sanitize_attributes(normalized, GogglesDb::Badge)
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
