# frozen_string_literal: true

module Import
  #
  # = DiffCalculator
  #
  # Utility class for calculating differences between model instances and their
  # database counterparts. Returns only the attributes that have changed.
  #
  # Extracted from MacroCommitter for reusability across import strategies.
  #
  # @author Steve A.
  #
  class DiffCalculator
    # Compares a Model row with its corresponding DB row, returning changed attributes.
    #
    # Safe to call even for new model rows: it returns the "compacted" hash of attributes
    # that can be used for an INSERT statement (skips timestamps and lock_version; row IDs
    # are kept in the output hash so that it can be manually checked by reading subsequent
    # rows in any resulting SQL file).
    #
    # An attribute of the model row will be considered as an appliable change if it
    # is not blank and differs from the value stored in the database.
    # (This method won't overwrite existing DB columns with nulls or blanks)
    #
    # == Params:
    # - <tt>model_row</tt>: the row Model instance to be processed;
    #
    # - <tt>db_row</tt>: the existing DB-stored row corresponding to the Model row instance above;
    #   (default: +nil+ => will try to use the model row ID)
    #
    # == Returns
    # A Hash of changed attributes (column => value), selected from the given
    # model row. If the model row doesn't have an ID, all its attributes will be returned.
    #
    def self.compute(model_row, db_row = nil)
      if model_row.id.blank? || model_row.id.to_i.zero?
        excluded_columns = %w[lock_version created_at updated_at]
        return model_row.attributes.reject { |col, val| excluded_columns.include?(col) || val.nil? }
      end

      db_row ||= model_row.class.find_by(id: model_row.id)
      # Force Calendars to be always updated:
      excluded_columns = model_row.is_a?(GogglesDb::Calendar) ? %w[id lock_version created_at] : %w[id lock_version created_at updated_at]
      model_row.attributes.reject do |column, value|
        value.blank? || value == db_row&.send(column) || excluded_columns.include?(column)
      end
    end
  end
end
