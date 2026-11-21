# frozen_string_literal: true

module Ops
  #
  # = Ops::Snapshot
  #
  # Last computed value for a key (ops DB, table 'snapshots'), e.g. 'api.status:<base_url>'.
  #
  class Snapshot < ApplicationRecord
    self.table_name = 'snapshots'

    validates :key, presence: true, uniqueness: true
    validates :taken_at, presence: true
    validate :payload_present

    # Upserts the snapshot for +key+, setting taken_at to now. Returns the record.
    def self.write!(key, payload, source: nil)
      row = find_or_initialize_by(key: key.to_s)
      row.update!(payload:, source:, taken_at: Time.current)
      row
    end

    # Returns the record for +key+ (payload, taken_at, source) or nil.
    def self.read(key)
      find_by(key: key.to_s)
    end

    private

    # (An empty Hash/Array is a valid payload, nil is not.)
    def payload_present
      errors.add(:payload, :blank) if payload.nil?
    end
  end
end
