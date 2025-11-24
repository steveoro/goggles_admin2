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

      def prepare_model(city_hash)
        attributes = sanitize_attributes(city_hash, GogglesDb::City)
        GogglesDb::City.new(attributes)
      end

      # Commit a City entity (nested within swimming pool data).
      # Returns city_id or nil.
      def commit(city_hash)
        return nil unless city_hash

        city_id = city_hash['city_id'] || city_hash['id']

        # If city already exists, return its ID
        return city_id if city_id.present? && city_id.positive?

        # Create new city
        model = prepare_model(city_hash)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:cities_created] += 1
        Rails.logger.info("[Main] Created City ID=#{model.id}, #{model.name}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        stats[:errors] << "City error: #{error_details}"
        logger.log_validation_error(
          entity_type: 'City',
          entity_key: city_hash['name'],
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR committing city: #{error_details}")
        raise
      end

      private

      # Local copy of attribute sanitization to keep behavior identical while
      # we refactor out of Main.
      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.slice(*column_names).except('id').stringify_keys
      end
    end
  end
end
