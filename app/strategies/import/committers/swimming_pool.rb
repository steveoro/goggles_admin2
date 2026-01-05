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
      # -----------------------------------------------------------------------

      # Commit a SwimmingPool entity (nested within session data).
      # Returns the committed row ID or raises an error.
      def commit(pool_hash)
        pool_id = pool_hash['swimming_pool_id'] || pool_hash['id']

        # Reuse existing row:
        existing_row = GogglesDb::SwimmingPool.find_by(id: pool_id) if pool_id.to_i.positive?
        attributes = normalize_attributes(pool_hash)

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:pools_updated] += 1
            logger.log_success(entity_type: 'SwimmingPool', entity_id: pool_id, action: 'updated',
                               entity_key: existing_row.nick_name)
            Rails.logger.info("[SwimmingPool] Updated ID=#{existing_row.id}")
          end
          return pool_id.to_i
        end

        # Create new row:
        model_row = GogglesDb::SwimmingPool.new(attributes)

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "SwimmingPool error (#{model_row.name}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'SwimmingPool',
            entity_key: model_row.name,
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[SwimmingPool] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:pools_created] += 1
        logger.log_success(entity_type: 'SwimmingPool', entity_id: model_row.id, action: 'created',
                           entity_key: model_row.description)
        Rails.logger.info("[SwimmingPool] Created ID=#{model_row.id}, #{model_row.description}")
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      # Normalizes pool attributes, mirroring Main#normalize_swimming_pool_attributes.
      def normalize_attributes(pool_hash)
        normalized = pool_hash.deep_dup.with_indifferent_access
        if normalized['pool_type_id'].blank? && normalized['pool_type_code'].present?
          normalized['pool_type_id'] =
            GogglesDb::PoolType.find_by(code: normalized['pool_type_code'])&.id
        end

        %w[multiple_pools garden bar restaurant gym child_area read_only].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        sanitize_attributes(normalized, GogglesDb::SwimmingPool)
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
        has_id = model.id.present?
        # Note that for nested entities like City or SwimmingPool, the attributes may
        # have NOT been filled-in by the solvers strategy classes, so we'll prevent
        # clearing out existing values if the id is present but the attribute is nil/blank.

        new_attributes.except('id', :id).any? do |key, value|
          # When updating an existing row, ignore nil/blank values to avoid
          # unintentionally clearing columns when the input only carries an id.
          next false if has_id && (value.nil? || value == '')

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
