# frozen_string_literal: true

module Drift
  #
  # = Drift::Check
  #
  # One DB sync check, stored as an Ops::DbFingerprint: local fingerprint, remote fingerprint (only when the API
  # reports the 'db_fingerprint' capability, with the background admin JWT), Outbox facts, remote-only writes, then
  # Drift::Verdict. Read-only on both DBs: the only write is the ops row (plus an event when the verdict changes).
  #
  # Called by DriftCheckJob (schedule, manual "Check now", post_push) in full mode, and by Drift::Gate (light mode)
  # when the last check is too old. When the remote side can't be compared (no capability, no background JWT) the
  # local side is read in light mode only (max ids: a few ms instead of the full COUNT(*) scans) and the row says so.
  #
  # == Usage
  #   fingerprint = Drift::Check.call(trigger: 'gate', mode: 'light')   # => Ops::DbFingerprint (nil without the ops DB)
  #
  class Check
    attr_reader :trigger, :mode, :tables, :base_url

    def self.call(**options)
      new(**options).call
    end

    # == Params:
    # - trigger: one of Ops::DbFingerprint::TRIGGERS; mode: 'full' or 'light';
    # - tables: subset of Drift::Tables (default: all); base_url: API base URL (default: the configured one).
    def initialize(trigger: 'schedule', mode: 'full', tables: nil, base_url: nil)
      @trigger = Ops::DbFingerprint::TRIGGERS.include?(trigger.to_s) ? trigger.to_s : 'schedule'
      @mode = Ops::DbFingerprint::MODES.include?(mode.to_s) ? mode.to_s : 'full'
      @tables = Drift::Tables.normalize(tables)
      @base_url = (base_url.presence || APIProxy.configured_base_url).to_s.strip.delete_suffix('/')
    end

    def light? = mode == 'light'

    # Returns the stored Ops::DbFingerprint, or nil when the ops DB is not available.
    def call
      return unless Ops.available?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      capabilities = APICapabilities.new(base_url:)
      jwt = Ops::BackgroundCredentials.jwt
      @mode = 'light' unless capabilities.supports?(:db_fingerprint) && jwt.present?
      local = Drift::Fingerprint.local(tables:, light: light?)
      remote = remote_fingerprint(capabilities, jwt)
      outbox = Drift::Verdict::OutboxFacts.current(base_url)
      writes = remote_writes_count
      result = Drift::Verdict.call(local:, remote:, outbox:, remote_writes: writes, acknowledged_at: acknowledged_at)
      store!(local:, remote:, capabilities:, outbox:, writes:, result:, duration: Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
    end

    private

    def remote_fingerprint(capabilities, jwt)
      return Drift::Fingerprint::Remote.new(status: 'no_capability', payload: {}, error: nil) unless capabilities.supports?(:db_fingerprint)

      Drift::Fingerprint.remote(base_url:, jwt:, tables:, light: light?)
    end

    # Successful remote-only data writes (not the import queue actions of the Outbox) since the last green check
    # or acknowledgement, whichever is later.
    def remote_writes_count
      since = [Ops::DbFingerprint.last_green_at(base_url), acknowledged_at].compact.max
      Ops::RemoteWrite.for_base_url(base_url).succeeded.since(since).where.not('endpoint LIKE ?', 'import_queue%').count
    end

    def acknowledged_at
      return @acknowledged_at if defined?(@acknowledged_at)

      @acknowledged_at = Ops::RemoteWrite.acknowledged_at
    end

    def store!(local:, remote:, capabilities:, outbox:, writes:, result:, duration:) # rubocop:disable Metrics/ParameterLists
      previous = Ops::DbFingerprint.latest(base_url)
      fingerprint = Ops::DbFingerprint.create!(
        taken_at: Time.current, trigger:, mode:, api_base_url: base_url,
        target_env: remote.payload['environment'].presence || capabilities.environment, api_version: capabilities.version,
        schema_version_local: local['schema_version'], schema_version_remote: remote.payload['schema_version'],
        local:, remote: remote.payload, verdict: result.verdict, reasons: result.reasons,
        pending_scripts_count: outbox.unapplied, remote_writes_count: writes, duration: duration.round(2),
        error: remote.error.presence
      )
      Ops::DbFingerprint.prune!
      record_change(previous, fingerprint)
      fingerprint
    end

    # One event when the verdict changes (the activity feed shows each transition, not each check).
    def record_change(previous, fingerprint)
      return if previous && previous.verdict == fingerprint.verdict

      level = { 'green' => 'success', 'amber' => 'warning', 'red' => 'error' }.fetch(fingerprint.verdict, 'info')
      Ops.record_event!(kind: 'drift.verdict_changed', level:, actor: trigger == 'manual' ? 'operator' : 'job',
                        subject_type: 'db_fingerprint', subject_key: fingerprint.id,
                        data: { 'from' => previous&.verdict, 'to' => fingerprint.verdict, 'url' => base_url,
                                'codes' => fingerprint.reasons.pluck('code').uniq.first(5) },
                        link_path: Rails.application.routes.url_helpers.db_sync_path)
    end
  end
end
