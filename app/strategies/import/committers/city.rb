# frozen_string_literal: true

module Import
  module Committers
    #
    # = City
    #
    # Commits City entities (nested under swimming pool data) to the DB,
    # mirroring the behavior previously implemented inside
    # Import::Committers::Main#commit_city.
    #
    class City
      include LegacyPersistence

      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end
      # -----------------------------------------------------------------------

      # Builds the City model (existing row with updated attributes or new draft)
      # without persisting, mirroring the lookup/normalize logic used by #commit.
      # Used by Import::StructureValidator for preflight validation.
      def prepare_model(city_hash)
        city_id = city_hash['city_id'] || city_hash['id']
        attributes = normalize_attributes(city_hash)

        existing_row = find_existing_row(city_id, attributes)
        if existing_row
          existing_row.assign_attributes(attributes.except('id'))
          return existing_row
        end

        GogglesDb::City.new(attributes.except('id'))
      end
      # -----------------------------------------------------------------------

      # Commit a City entity (nested within swimming pool data).
      # Returns the committed row ID or raises an error.
      def commit(city_hash)
        city_id = city_hash['city_id'] || city_hash['id']
        attributes = normalize_attributes(city_hash)

        # Reuse existing row (by id, or by the unique (country_code, area, name)
        # tuple so that sessions sharing the same new city don't attempt a
        # second INSERT):
        existing_row = find_existing_row(city_id, attributes)

        if existing_row
          changes = changes_for_update(existing_row, attributes)
          if changes.any?
            existing_row.assign_attributes(changes)
            existing_row.save!
            sql_log << SqlMaker.new(row: existing_row).log_update(changes)
            stats[:cities_updated] += 1
            logger.log_success(entity_type: 'City', entity_id: existing_row.id, action: 'updated',
                               entity_key: existing_row.name)
            Rails.logger.info("[City] Updated ID=#{existing_row.id}")
          else
            logger.log_success(entity_type: 'City', entity_id: existing_row.id, action: 'reused',
                               entity_key: existing_row.name)
          end
          return existing_row.id
        end

        # Create new row:
        model_row = GogglesDb::City.new(attributes)

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "City error (#{model_row.name}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'City',
            entity_key: model_row.name,
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[City] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:cities_created] += 1
        logger.log_success(entity_type: 'City', entity_id: model_row.id, action: 'created',
                           entity_key: model_row.name)
        Rails.logger.info("[City] Created ID=#{model_row.id}, #{model_row.name}")
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      # Finds a reusable existing row by id, falling back to the unique
      # (country_code, area, name) index so that duplicate submissions of the
      # same new city resolve to the row already committed in this same
      # transaction. (Requires a name; other tuple components may be NULL.)
      def find_existing_row(city_id, attributes)
        row = GogglesDb::City.find_by(id: city_id) if city_id.to_i.positive?
        if row.nil? && attributes['name'].present?
          row = GogglesDb::City.find_by(country_code: attributes['country_code'],
                                        area: attributes['area'], name: attributes['name'])
        end
        row
      end
      # -----------------------------------------------------------------------

      def normalize_attributes(city_hash)
        normalized = city_hash.deep_dup.with_indifferent_access

        # Apply defaults only when creating a brand-new row (no id provided)
        unless normalized['id'].to_i.positive? || normalized['city_id'].to_i.positive?
          normalized['country_code'] ||= 'IT'
          normalized['country'] ||= 'Italia'
        end

        sanitize_attributes(normalized, GogglesDb::City)
      end
      # -----------------------------------------------------------------------

      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.stringify_keys.slice(*column_names)
      end
      # -----------------------------------------------------------------------

      # Checks if any attributes have changed, excluding the ID.
      # Returns false for nil/blank attributes if the ID is set
      def attributes_changed?(model, new_attributes)
        changes_for_update(model, new_attributes).any?
      end
      # -----------------------------------------------------------------------
    end
  end
end
