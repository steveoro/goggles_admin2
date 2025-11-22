# frozen_string_literal: true

module Import
  module Committers
    #
    # = SwimmingPool
    #
    # Commits SwimmingPool entities (nested within session data) to the DB,
    # mirroring the behavior previously implemented inside
    # Import::Committers::Main#commit_swimming_pool and
    # #normalize_swimming_pool_attributes.
    #
    class SwimmingPool
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end

      # Commit a SwimmingPool entity (nested within session data).
      # Returns swimming_pool_id or nil.
      def commit(pool_hash)
        return nil unless pool_hash

        pool_id = pool_hash['swimming_pool_id'] || pool_hash['id']

        # If pool already exists, return its ID
        return pool_id if pool_id.present? && pool_id.positive?

        # Create new swimming pool
        normalized_pool = normalize_attributes(pool_hash, city_id: pool_hash['city_id'])

        new_pool = GogglesDb::SwimmingPool.create!(normalized_pool)
        sql_log << SqlMaker.new(row: new_pool).log_insert
        stats[:pools_created] += 1
        Rails.logger.info("[Main] Created SwimmingPool ID=#{new_pool.id}, #{new_pool.name}")
        new_pool.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        stats[:errors] << "SwimmingPool error: #{error_details}"
        logger.log_validation_error(
          entity_type: 'SwimmingPool',
          entity_key: pool_hash['name'],
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR committing pool: #{error_details}")
        raise
      end

      private

      # Normalizes pool attributes, mirroring Main#normalize_swimming_pool_attributes.
      def normalize_attributes(pool_hash, city_id:)
        normalized = pool_hash.deep_dup.with_indifferent_access
        normalized['city_id'] ||= city_id if city_id

        pool_type_code = normalized.delete('pool_type_code')
        normalized['pool_type_id'] = GogglesDb::PoolType.find_by(code: pool_type_code)&.id if normalized['pool_type_id'].blank? && pool_type_code.present?

        %w[multiple_pools garden bar restaurant gym child_area read_only].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        sanitize_attributes(normalized, GogglesDb::SwimmingPool)
      end

      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.slice(*column_names).except('id').stringify_keys
      end
    end
  end
end
