# frozen_string_literal: true

module Import
  module Committers
    # Legacy-compatible persistence helpers used by phased committers.
    #
    # Mirrors MacroCommitter.difference_with_db semantics:
    # - never overwrite DB values with blank/nil payload values on updates
    # - update only changed columns
    # - special-case Calendar by keeping updated_at in the diff set
    module LegacyPersistence
      # Returns attributes that can be used for insertion, excluding lock_version, created_at, and updated_at.
      def insertable_attributes(model_row)
        excluded_columns = %w[lock_version created_at updated_at]
        model_row.attributes.reject { |column, value| excluded_columns.include?(column.to_s) || value.nil? }
      end

      # Returns attributes that have changed, excluding lock_version, created_at, and updated_at.
      # For Calendar, updated_at is kept in the diff set.
      def changes_for_update(db_row, new_attributes)
        excluded_columns = if db_row.is_a?(GogglesDb::Calendar)
                             %w[id lock_version created_at]
                           else
                             %w[id lock_version created_at updated_at]
                           end

        new_attributes.stringify_keys.reject do |column, value|
          normalized_value = normalize_literal_value(value)
          normalized_value.blank? || excluded_columns.include?(column) ||
            cast_for_compare(db_row, column, normalized_value) == safe_read_attribute(db_row, column)
        end
      end

      private

      # Coerces common string literals from import payloads before type casting / comparison.
      def normalize_literal_value(value)
        return value unless value.is_a?(String)

        case value.strip.downcase
        when 'null', 'nil' then nil
        when 'false' then false
        when 'true' then true
        else value
        end
      end

      # Safely reads an attribute from a model row, returning nil if the attribute doesn't exist.
      def safe_read_attribute(model_row, column)
        model_row.public_send(column)
      rescue NoMethodError
        nil
      end

      # Casts a value to the appropriate type for comparison with a database row.
      def cast_for_compare(model_row, column, value)
        value = normalize_literal_value(value)
        return value unless model_row.respond_to?(:has_attribute?) && model_row.has_attribute?(column)

        model_row.class.type_for_attribute(column.to_s).cast(value)
      rescue StandardError
        value
      end
    end
  end
end
