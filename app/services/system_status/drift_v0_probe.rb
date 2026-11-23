# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::DriftV0Probe
  #
  # Drift v0 ("DB sync") between the local DB and the configured API, from Drift::V0Status: the
  # 'drift_v0:<base_url>' snapshot written by DriftCheckJob plus the live count of the unacknowledged
  # remote writes (local ops DB). Never calls the network while evaluated.
  #
  # Levels: :ok, :warn (recent remote rows missing locally, or remote-only writes since the last
  # acknowledgement; action: the /remote_writes page) or :unknown (never checked, stale, no credentials,
  # unreachable, ...). :error is reserved for phase 08 (fingerprints).
  #
  # The snapshot is not written by RefreshJob: #refresh! only enqueues DriftCheckJob, and only when the
  # snapshot is missing or older than DUE_AFTER (the job is also recurring every 30 minutes).
  #
  class DriftV0Probe < Probe
    # The snapshot is refreshed by DriftCheckJob every 30 minutes: ask for a run only past this age.
    DUE_AFTER = 45.minutes

    def self.mode
      :snapshot
    end

    def snapshot_key
      Drift::LatestUpdatesCheck.key_for(target_url)
    end

    # True when the drift snapshot is missing or older than DUE_AFTER (or +max_age+, when longer).
    def refresh_due?(max_age)
      return false if target_url.blank?

      snapshot.nil? || snapshot.taken_at < now - [max_age, DUE_AFTER].max
    end

    # Enqueues a DriftCheckJob for the target API (no network call here).
    def refresh!
      return if target_url.blank?

      DriftCheckJob.perform_later(base_url: target_url)
    end

    protected

    def evaluate
      status = Drift::V0Status.for(target_url, now:)
      checked_at = status.checked_at
      action = status.warn? ? remote_writes_action : nil
      result(status.level, detail: status.details.join(' · '), checked_at:, action:)
    end

    private

    def target_url
      @target_url ||= (api_url.presence || Shell::APITarget.configured_url).to_s.delete_suffix('/')
    end

    def remote_writes_action
      { label: I18n.t('shell.status.actions.remote_writes'), path: url_helpers.remote_writes_path }
    end
  end
end
