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
    class Swimmer
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_reader :stats, :logger, :sql_log

      def initialize(stats:, logger:, sql_log:)
        @stats = stats
        @logger = logger
        @sql_log = sql_log
      end

      def prepare_model(swimmer_hash)
        attributes = normalize_attributes(swimmer_hash)
        GogglesDb::Swimmer.new(attributes)
      end

      # Commit a Swimmer entity.
      # Returns swimmer_id or nil.
      def commit(swimmer_hash)
        swimmer_id = swimmer_hash['swimmer_id']
        normalized_attributes = normalize_attributes(swimmer_hash)
        model = nil

        # If swimmer already has a DB ID, it's matched - just verify or update if needed
        if swimmer_id.present? && swimmer_id.to_i.positive?
          swimmer = GogglesDb::Swimmer.find_by(id: swimmer_id)
          if swimmer && attributes_changed?(swimmer, normalized_attributes)
            swimmer.update!(normalized_attributes)
            sql_log << SqlMaker.new(row: swimmer).log_update
            stats[:swimmers_updated] += 1
            Rails.logger.info("[Main] Updated Swimmer ID=#{swimmer_id}")
          end
          return swimmer_id
        end

        # Fallback: try to match an existing swimmer by complete_name + year_of_birth
        existing = nil
        complete_name = normalized_attributes['complete_name']
        year_of_birth = normalized_attributes['year_of_birth']
        existing = GogglesDb::Swimmer.find_by(complete_name: complete_name, year_of_birth: year_of_birth) if complete_name.present? && year_of_birth.present?

        # Secondary fallback: match by last_name + first_name + year_of_birth
        if existing.nil? && normalized_attributes['last_name'].present? &&
           normalized_attributes['first_name'].present? && year_of_birth.present?
          existing = GogglesDb::Swimmer.find_by(
            last_name: normalized_attributes['last_name'],
            first_name: normalized_attributes['first_name'],
            year_of_birth: year_of_birth
          )
        end

        if existing
          if attributes_changed?(existing, normalized_attributes)
            existing.update!(normalized_attributes)
            sql_log << SqlMaker.new(row: existing).log_update
            stats[:swimmers_updated] += 1
            Rails.logger.info("[Main] Updated Swimmer ID=#{existing.id} (matched by name/year)")
          end
          return existing.id
        end

        # Create new swimmer (no existing match found)
        model = prepare_model(swimmer_hash)
        model.save!
        sql_log << SqlMaker.new(row: model).log_insert
        stats[:swimmers_created] += 1
        Rails.logger.info("[Main] Created Swimmer ID=#{model.id}, name=#{model.complete_name}")
        model.id
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record || model
        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        stats[:errors] << "Swimmer error (#{swimmer_hash['key']}): #{error_details}"
        logger.log_validation_error(
          entity_type: 'Swimmer',
          entity_key: swimmer_hash['key'] || complete_name,
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR committing swimmer: #{error_details}")
        raise
      end

      private

      def normalize_attributes(swimmer_hash)
        normalized = swimmer_hash.deep_dup.with_indifferent_access
        gender_code = normalized.delete('gender_type_code') || normalized.delete(:gender_type_code)
        normalized['gender_type_id'] ||= GogglesDb::GenderType.find_by(code: gender_code)&.id if gender_code.present?
        normalized['complete_name'] ||= build_complete_name(normalized)
        normalized['year_guessed'] = BOOLEAN_TYPE.cast(normalized['year_guessed']) if normalized.key?('year_guessed')

        sanitize_attributes(normalized, GogglesDb::Swimmer)
      end

      def build_complete_name(swimmer_hash)
        swimmer_hash['complete_name'].presence || [swimmer_hash['last_name'], swimmer_hash['first_name']].compact_blank.join(' ')
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
