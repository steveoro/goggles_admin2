# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::DbSyncProbe
  #
  # "DB sync" between the local DB and the configured API: the verdict of the last stored check
  # (Ops::DbFingerprint, written by Drift::Check). Never calls the network while evaluated.
  #
  # Levels: green => :ok, amber => :warn (also a green check older than Ops::DbFingerprint::STALE_AFTER),
  # red => :error, unknown => :unknown (never checked, API unreachable, no credentials, an API without the
  # 'db_fingerprint' capability, ops DB not ready). Action: the /db_sync page.
  #
  # RefreshJob does not write anything for this probe: #refresh! only enqueues a DriftCheckJob, and only when the
  # last check of that job (not a gate's own light check) is missing or older than DUE_AFTER (the job is also
  # recurring every 30 minutes).
  #
  class DbSyncProbe < Probe
    # The full check runs every 30 minutes: ask for a run only past this age.
    DUE_AFTER = 45.minutes

    def self.mode
      :snapshot
    end

    def self.label_key
      'db_sync.pill.label'
    end

    # (No ops snapshot: the probe reads the Ops::DbFingerprint rows.)
    def snapshot
      nil
    end

    # True when the last job check is missing or older than DUE_AFTER (or +max_age+, when longer).
    def refresh_due?(max_age)
      return false if target_url.blank? || !Ops.available?

      last = Ops.safely { Ops::DbFingerprint.latest_job_check(target_url) }
      last.nil? || last.taken_at < now - [max_age, DUE_AFTER].max
    end

    # Enqueues a DriftCheckJob for the target API (no network call here).
    def refresh!
      return if target_url.blank?

      DriftCheckJob.perform_later(trigger: 'schedule', base_url: target_url)
    end

    protected

    def evaluate
      return result(:unknown, detail: I18n.t('db_sync.pill.ops_unavailable')) unless Ops.available?

      fingerprint = Ops::DbFingerprint.latest(target_url)
      return result(:unknown, detail: I18n.t('db_sync.pill.never'), action: db_sync_action) unless fingerprint

      reasons = fingerprint.reason_list(now:).first(3).map { |reason| Drift::ReasonText.call(reason) }
      detail = [I18n.t("db_sync.verdicts.#{fingerprint.effective_verdict(now:)}"), *reasons].join(' · ')
      result(fingerprint.level(now:), detail:, checked_at: fingerprint.taken_at, action: db_sync_action)
    end

    private

    def target_url
      @target_url ||= (api_url.presence || Shell::APITarget.configured_url).to_s.delete_suffix('/')
    end

    def db_sync_action
      { label: I18n.t('db_sync.pill.open'), path: url_helpers.db_sync_path }
    end
  end
end
