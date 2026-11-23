# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::APIProbe
  #
  # Reachability of the configured API server, from the 'api.status:<base_url>' snapshot
  # (SystemStatus::APISnapshot). In an API-offline session the result is :error from the session alone.
  # #refresh! (RefreshJob only) pings the server's public 'status' endpoint.
  #
  class APIProbe < Probe
    # Ping timeouts (seconds): RefreshJob runs on the single-thread 'default' worker, so a hung API
    # must not hold it for RestClient's default 60 s.
    PING_TIMEOUTS = { open_timeout: 3, timeout: 5 }.freeze

    def self.mode
      :snapshot
    end

    def snapshot_key
      APISnapshot.key_for(target_url)
    end

    def snapshot
      return @snapshot if defined?(@snapshot)

      @snapshot = target_url.present? ? APISnapshot.read(target_url) : nil
    end

    # Pings the API (no JWT) and stores the outcome. Returns the Ops::Snapshot or nil.
    def refresh!
      return if target_url.blank?

      APISnapshot.write!(target_url, APIProxy.ping(target_url, **PING_TIMEOUTS), source: 'system_status')
    end

    protected

    def evaluate
      return result(:error, detail: detail_text(:offline), action: settings_action) if offline
      return result(:unknown, detail: detail_text(:never)) if snapshot.nil?

      checked_at = snapshot.taken_at
      return result(:unknown, detail: detail_text(:stale, time: format_time(checked_at)), checked_at:) if stale?(checked_at)

      payload = snapshot.payload.is_a?(Hash) ? snapshot.payload : {}
      payload['reachable'] ? reachable_result(payload, checked_at) : unreachable_result(payload, checked_at)
    end

    private

    # Any answer below 500 means the server is up (e.g. a 401 for rejected sign-in credentials).
    def reachable_result(payload, checked_at)
      return result(:warn, detail: detail_text(:answered, code: payload['code'], error: payload['error']), checked_at:) if payload['code'].to_i >= 500

      detail = payload['version'].present? ? detail_text(:ok, version: payload['version']) : detail_text(:reachable)
      result(:ok, detail:, checked_at:)
    end

    def unreachable_result(payload, checked_at)
      result(:error, detail: detail_text(:unreachable, error: payload['error']), checked_at:, action: settings_action)
    end

    def target_url
      @target_url ||= (api_url.presence || Shell::APITarget.configured_url).to_s.delete_suffix('/')
    end

    def settings_action
      { label: I18n.t('shell.status.actions.settings'), path: url_helpers.settings_path }
    end
  end
end
