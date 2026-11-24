# frozen_string_literal: true

require 'digest'

module Maintenance
  #
  # = Maintenance::Plan
  #
  # Immutable result of Maintenance::Operation#plan (the dry run): it never writes.
  #
  # == Members
  # - operation_key, params (Hash with String keys), label (one line, e.g. "Merge badge 12 into 34");
  # - season_id (season of the subject, nil when cross-season), subjects (Array of { 'type' =>, 'id' => });
  # - console (captured stdout), summary (Hash shown as facts), warnings / errors (Arrays of Strings);
  # - sql_lines (Array of Strings: the exact script lines, joined with "\r\n" when written);
  # - health_group (Ops::HealthRun::GROUPS key re-run after an apply, or nil).
  #
  # #digest ignores the comment and blank lines, because scripts embed timestamps (duplicate_result_cleaner.rb,
  # fix.rake): a preview and an apply on the same data give the same digest. Each element is split on its line
  # breaks first, so a statement behind a leading comment line in the same element still counts.
  #
  Plan = Data.define(:operation_key, :params, :label, :season_id, :subjects, :console, :summary,
                     :warnings, :errors, :sql_lines, :health_group) do
    # The single lines that are neither blank nor SQL comments.
    def significant_lines
      sql_lines.flat_map { |line| line.to_s.split(/\r?\n/) }.reject { |line| line.strip.empty? || line.lstrip.start_with?('--') }
    end

    def digest = Digest::SHA256.hexdigest(significant_lines.join("\n"))

    # Number of statements changing rows.
    def write_statements_count = significant_lines.count { |line| self.class::WRITE_REGEXP.match?(line) }

    # True when nothing would change.
    def empty? = write_statements_count.zero?

    def blocked? = errors.any?

    # The script text, as written to the Outbox and run locally.
    def sql_text = "#{sql_lines.join("\r\n")}\r\n"
  end

  # A line starting a statement that changes rows.
  Plan::WRITE_REGEXP = /\A\s*(INSERT|UPDATE|DELETE|REPLACE)\b/i
end
