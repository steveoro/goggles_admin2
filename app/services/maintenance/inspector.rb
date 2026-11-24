# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::Inspector
  #
  # A read-only check (phase 13, Maintenance::Inspectors::*): the console report of a 'check:*' rake task as a dry run
  # that is never applied (no SQL, no Outbox script). Listed apart on /operations; its run page shows the report only.
  # The rake caller prints #plan's console unchanged (see Maintenance::RakeTasks).
  #
  # Subclasses implement #build_plan (the checker calls; what they print is the console) and may put the facts the
  # rake caller needs (counts, exit conditions) in the plan summary.
  #
  class Inspector < Operation
    self.confirmation = :one_click
    self.outbox_kind = nil
    self.health_group = nil
    self.fixes = [].freeze

    def self.inspector? = true

    # (never written)
    def file_base = nil

    protected

    # A plan holding only +console+ and +summary+ (and the errors of a missing input).
    def report_plan(summary: {}, subjects: [], errors: [])
      blank_plan(summary:, subjects:, errors:)
    end
  end
end
