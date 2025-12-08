# frozen_string_literal: true

module Import
  module Committers
    #
    # = Swimmer
    #
    # Commits Swimmer entities to the production DB, mirroring the behavior
    # previously implemented inside Import::Committers::Main#commit_swimmer
    # (including matching semantics against name + year).
    #
    # Maintains an internal ID mapping (swimmer_key → swimmer_id) for efficient
    # lookups during Phase 5/6 commit, avoiding repeated DB queries.
    #
    class Swimmer
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_reader :stats, :logger, :sql_log, :id_by_key

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
        @id_by_key = {} # swimmer_key → swimmer_id mapping
      end
      # -----------------------------------------------------------------------

      # Store swimmer_id in mapping for later lookup
      def store_id(swimmer_key, swimmer_id)
        return unless swimmer_key.present? && swimmer_id

        @id_by_key[swimmer_key] = swimmer_id
      end
      # -----------------------------------------------------------------------

      # Resolve swimmer_id from swimmer_key using mapping
      # Tries partial key matching if direct lookup fails
      def resolve_id(swimmer_key)
        return nil if swimmer_key.blank?

        # 1. Direct lookup from commit mapping
        swimmer_id = @id_by_key[swimmer_key]
        return swimmer_id if swimmer_id

        # 2. Try partial key matching (without gender prefix)
        # Keys format: "F|ROSSI|Maria|1959"
        partial_key = swimmer_key.split('|')[1..].join('|')

        @id_by_key.each do |key, id|
          key_partial = key.split('|')[1..].join('|')
          return id if key_partial == partial_key
        end

        nil
      end
      # -----------------------------------------------------------------------

      # Commit a Swimmer entity and store ID in mapping.
      # Returns the committed row ID or raises an error.
      def commit(swimmer_hash)
        swimmer_key = swimmer_hash['key'] || swimmer_hash['swimmer_key']
        # Prevent invalid mappings due to nil key components:
        raise StandardError, 'Null swimmer_key found in datafile object!' if swimmer_key.blank?

        swimmer_id = swimmer_hash['swimmer_id']
        attributes = normalize_attributes(swimmer_hash)

        # Reuse existing row:
        existing_row = GogglesDb::Swimmer.find_by(id: swimmer_id) if swimmer_id.to_i.positive?

        if existing_row
          if attributes_changed?(existing_row, attributes)
            existing_row.update!(attributes)
            sql_log << SqlMaker.new(row: existing_row).log_update
            stats[:swimmers_updated] += 1
            logger.log_success(entity_type: 'Swimmer', entity_id: swimmer_id, action: 'updated',
                               entity_key: swimmer_key)
            Rails.logger.info("[Swimmer] Updated ID=#{swimmer_id}")
          end
          store_id(swimmer_key, swimmer_id.to_i)
          return swimmer_id.to_i
        end

        # Create new row:
        model_row = GogglesDb::Swimmer.new(attributes)

        # Check validation before saving
        unless model_row.valid?
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
          stats[:errors] << "Swimmer error (swimmer_key=#{swimmer_key}): #{error_details}"
          logger.log_validation_error(
            entity_type: 'Swimmer',
            entity_key: "swimmer_key=#{swimmer_key}",
            entity_id: model_row&.id,
            model_row: model_row,
            error: error_details
          )
          Rails.logger.error("[Swimmer] ERROR creating: #{error_details}")
          raise StandardError, "Invalid #{model_row.class} row: #{error_details}"
        end

        model_row.save!
        sql_log << SqlMaker.new(row: model_row).log_insert
        stats[:swimmers_created] += 1
        logger.log_success(entity_type: 'Swimmer', entity_id: model_row.id, action: 'created',
                           entity_key: model_row.complete_name)
        Rails.logger.info("[Swimmer] Created ID=#{model_row.id}, #{model_row.complete_name}")
        store_id(swimmer_key, model_row.id)
        model_row.id
      end
      # -----------------------------------------------------------------------

      private

      def normalize_attributes(swimmer_hash)
        normalized = swimmer_hash.deep_dup.with_indifferent_access
        gender_code = normalized.delete('gender_type_code') || normalized.delete(:gender_type_code)
        normalized['gender_type_id'] ||= GogglesDb::GenderType.find_by(code: gender_code)&.id if gender_code.present?
        normalized['complete_name'] ||= build_complete_name(normalized)
        normalized['year_guessed'] = BOOLEAN_TYPE.cast(normalized['year_guessed']) if normalized.key?('year_guessed')

        sanitize_attributes(normalized, GogglesDb::Swimmer)
      end
      # -----------------------------------------------------------------------

      def build_complete_name(swimmer_hash)
        swimmer_hash['complete_name'].presence || [swimmer_hash['last_name'], swimmer_hash['first_name']].compact_blank.join(' ')
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
