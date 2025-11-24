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
    class Badge
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end

      def prepare_model(badge_hash)
        swimmer_id = badge_hash['swimmer_id']
        team_id = badge_hash['team_id']
        season_id = badge_hash['season_id']
        category_type_id = badge_hash['category_type_id']
        team_affiliation = GogglesDb::TeamAffiliation.find_by(team_id: team_id, season_id: season_id)
        return nil unless team_affiliation

        attributes = normalize_attributes(
          badge_hash,
          swimmer_id: swimmer_id,
          team_id: team_id,
          season_id: season_id,
          category_type_id: category_type_id,
          team_affiliation_id: team_affiliation.id
        )
        GogglesDb::Badge.new(attributes)
      end

      # Commit a Badge entity.
      # Returns badge_id or nil.
      def commit(badge_hash)
        badge_id = badge_hash['badge_id']
        swimmer_id = badge_hash['swimmer_id']
        team_id = badge_hash['team_id']
        season_id = badge_hash['season_id']
        category_type_id = badge_hash['category_type_id']
        model = nil

        # Guard clause: skip if missing required keys
        return unless swimmer_id && team_id && season_id

        # If badge_id exists, it's already in DB - skip
        if badge_id.present?
          Rails.logger.debug { "[Main] Badge ID=#{badge_id} already exists, skipping" }
          return badge_id
        end

        # Find the team_affiliation (should have been created in Phase 2)
        team_affiliation = GogglesDb::TeamAffiliation.find_by(team_id: team_id, season_id: season_id)
        unless team_affiliation
          stats[:errors] << "Badge error: TeamAffiliation not found for team_id=#{team_id}, season_id=#{season_id}"
          Rails.logger.error('[Main] ERROR: TeamAffiliation not found for badge creation')
          return
        end

        attributes = normalize_attributes(
          badge_hash,
          swimmer_id: swimmer_id,
          team_id: team_id,
          season_id: season_id,
          category_type_id: category_type_id,
          team_affiliation_id: team_affiliation.id
        )

        # Fallback: reuse existing badge when one already exists for the same swimmer/team/season
        existing_badge = GogglesDb::Badge.find_by(
          season_id: season_id,
          swimmer_id: swimmer_id,
          team_id: team_id
        )

        if existing_badge
          if attributes_changed?(existing_badge, attributes)
            existing_badge.update!(attributes)
            sql_log << SqlMaker.new(row: existing_badge).log_update
            Rails.logger.info("[Main] Updated Badge ID=#{existing_badge.id}, swimmer_id=#{swimmer_id}, team_id=#{team_id}, category_id=#{category_type_id}")
          end
          return existing_badge.id
        end

        model = GogglesDb::Badge.new(attributes)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:badges_created] += 1
        Rails.logger.info("[Main] Created Badge ID=#{model.id}, swimmer_id=#{swimmer_id}, team_id=#{team_id}, category_id=#{category_type_id}")
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
          entity_key: "swimmer_key=#{swimmer_key},swimmer_id=#{swimmer_id},team_id=#{team_id},team_key=#{team_key},season_id=#{season_id}",
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR creating badge: #{error_details}")
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
