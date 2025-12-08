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
      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end
      # -----------------------------------------------------------------------

      # Commit a City entity (nested within swimming pool data).
      # Returns the committed row ID or raises an error.
      def commit(city_hash)
        city_id = city_hash['city_id'] || city_hash['id']

        # Reuse existing row:
        existing_row = GogglesDb::City.find_by(id: city_id) if city_id.to_i.positive?
        attributes = normalize_attributes(city_hash)

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:cities_updated] += 1
            logger.log_success(entity_type: 'City', entity_id: city_id, action: 'updated',
                               entity_key: existing_row.name)
            Rails.logger.info("[City] Updated ID=#{city_id}")
          end
          return city_id.to_i
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

      def normalize_attributes(city_hash)
        normalized = city_hash.deep_dup.with_indifferent_access
        normalized['country_code'] ||= 'IT'
        normalized['country'] ||= 'Italia'

        sanitize_attributes(normalized, GogglesDb::City)
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
