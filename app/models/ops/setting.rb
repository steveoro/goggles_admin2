# frozen_string_literal: true

module Ops
  #
  # = Ops::Setting
  #
  # Small key/value store (ops DB, table 'settings'); values are stored as JSON.
  # (Unrelated to the top-level ::Setting, which wraps the MySQL app parameters.)
  #
  class Setting < ApplicationRecord
    self.table_name = 'settings'

    DB_EPOCH_KEY = 'db_epoch'

    validates :key, presence: true, uniqueness: true

    # Returns the stored value for +key+, or +default+ when missing.
    def self.fetch(key, default = nil)
      row = find_by(key: key.to_s)
      row ? row.value : default
    end

    # Stores (upserts) +value+ under +key+; returns the value.
    def self.store!(key, value)
      row = find_or_initialize_by(key: key.to_s)
      row.update!(value:)
      value
    end

    # Integer epoch of the local DB contents: seeded to 1 by Ops::Database.prepare!,
    # bumped when the local DB is restored.
    def self.db_epoch
      fetch(DB_EPOCH_KEY, 1).to_i
    end
  end
end
