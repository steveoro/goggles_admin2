# frozen_string_literal: true

module Ops
  #
  # = Ops::DbFingerprint
  #
  # One DB sync check (ops DB, table 'db_fingerprints'): the local and remote fingerprints (count, max id,
  # max updated_at per whitelisted table, see Drift::Tables) and the verdict computed from them (Drift::Verdict).
  # Written only by Drift::Check (DriftCheckJob, "Check now" on /db_sync, the gates); read by the DB sync pill
  # (SystemStatus::DbSyncProbe), Drift::IndicatorComponent, /db_sync, the inbox and Drift::Gate.
  # The status surfaces read these rows only: they never call the API.
  #
  # == Attributes
  # - taken_at; trigger (TRIGGERS); mode ('full': count + max id + max updated_at, 'light': max id only);
  # - api_base_url, target_env (the environment reported by the API), api_version;
  # - schema_version_local, schema_version_remote;
  # - local, remote: JSON fingerprints ({ 'tables' => { 'laps' => { 'count' =>, 'max_id' =>, 'max_updated_at' => } }, ... });
  # - verdict (VERDICTS); reasons: JSON Array of { 'code', 'table', 'local', 'remote' } (texts 'db_sync.reasons.<code>');
  # - pending_scripts_count (Outbox scripts not applied on the server yet), remote_writes_count; duration (s); error.
  #
  # Only the last KEEP rows are kept (#prune!).
  #
  class DbFingerprint < ApplicationRecord
    self.table_name = 'db_fingerprints'

    VERDICTS = %w[green amber red unknown].freeze
    TRIGGERS = %w[schedule manual gate post_push post_restore].freeze # ('post_restore': phase 14, DbRestore::PostSteps)
    MODES = %w[full light].freeze
    KEEP = 200
    # A check older than this is reported as amber ('stale') by the status surfaces.
    STALE_AFTER = 2.hours
    # Verdict => status level (SystemStatus::Result / Shell::StatusPillComponent).
    LEVELS = { 'green' => :ok, 'amber' => :warn, 'red' => :error, 'unknown' => :unknown }.freeze

    validates :taken_at, presence: true
    validates :verdict, inclusion: { in: VERDICTS }
    validates :trigger, inclusion: { in: TRIGGERS }
    validates :mode, inclusion: { in: MODES }

    scope :recent, -> { order(taken_at: :desc, id: :desc) }
    scope :for_base_url, ->(base_url) { where(api_base_url: normalize_url(base_url)) }
    scope :full, -> { where(mode: 'full') }
    # The checks run by DriftCheckJob (schedule, manual, post_push), not the gates' own light checks.
    scope :job_checks, -> { where.not(trigger: 'gate') }
    scope :green, -> { where(verdict: 'green') }

    class << self
      # The last check for +base_url+ (any mode), or nil.
      def latest(base_url)
        for_base_url(base_url).recent.first
      end

      # The last full check for +base_url+, or nil.
      def latest_full(base_url)
        for_base_url(base_url).full.recent.first
      end

      # The last check run by DriftCheckJob for +base_url+ (any mode), or nil.
      def latest_job_check(base_url)
        for_base_url(base_url).job_checks.recent.first
      end

      # Time of the last green check for +base_url+, or nil.
      def last_green_at(base_url)
        for_base_url(base_url).green.maximum(:taken_at)
      end

      # Deletes all but the last KEEP rows. Returns the number of deleted rows.
      def prune!(keep: KEEP)
        return 0 if count <= keep

        where.not(id: recent.limit(keep).pluck(:id)).delete_all
      end

      def normalize_url(base_url)
        base_url.to_s.strip.delete_suffix('/')
      end
    end

    def green? = verdict == 'green'
    def amber? = verdict == 'amber'
    def red? = verdict == 'red'
    def unknown? = verdict == 'unknown'
    def light? = mode == 'light'

    def stale?(now: Time.current)
      taken_at < now - STALE_AFTER
    end

    # The verdict as shown now: a green check older than STALE_AFTER reads amber.
    def effective_verdict(now: Time.current)
      green? && stale?(now:) ? 'amber' : verdict
    end

    # Status level of the effective verdict (:ok, :warn, :error, :unknown).
    def level(now: Time.current)
      LEVELS.fetch(effective_verdict(now:), :unknown)
    end

    # Reasons as Hashes with Symbol keys (code:, table:, local:, remote:), plus 'stale' when it applies now.
    def reason_list(now: Time.current)
      list = Array(reasons).filter_map do |reason|
        next unless reason.is_a?(Hash)

        { code: reason['code'].to_s, table: reason['table'], local: reason['local'], remote: reason['remote'] }
      end
      list.unshift({ code: 'stale', table: nil, local: taken_at.iso8601, remote: nil }) if green? && stale?(now:)
      list
    end

    # Per-table comparison rows for the /db_sync page:
    # [{ table:, local: { 'count', 'max_id', 'max_updated_at' }, remote: {...} }] (whitelist order).
    def table_rows
      local_tables = tables_of(local)
      remote_tables = tables_of(remote)
      names = Drift::Tables.all & (local_tables.keys | remote_tables.keys)
      names.map { |table| { table:, local: local_tables[table] || {}, remote: remote_tables[table] || {} } }
    end

    private

    def tables_of(fingerprint)
      tables = fingerprint.is_a?(Hash) ? fingerprint['tables'] : nil
      tables.is_a?(Hash) ? tables : {}
    end
  end
end
