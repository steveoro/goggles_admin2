# frozen_string_literal: true

module Kpi
  #
  # = Kpi::StripComponent
  #
  # The dashboard KPI strip: the four counters of the configured API (API uses, import queues, issues, users) from
  # the 'kpi:<api_url>' ops snapshot written by KpiRefreshJob (never from the API itself), each with its age, plus
  # the time of the last refresh run. Each tile links to its grid (not in an API-offline session).
  #
  # Value states (see KpiRefreshJob for the payload): a counter absent from 'values' is never shown as 0; it shows
  # "unreachable" (status 'unreachable'), "sign in to refresh" ('no_credentials' / 'unauthorized'), "unavailable"
  # (its own fetch failed) or "no data yet" (no snapshot for this API URL).
  #
  class StripComponent < ViewComponent::Base
    # Counter key => [label key, icon, grid route helper, route params], in display order.
    # The import queues counter counts the rows still to process (KpiRefreshJob: done=false), so its tile opens the
    # list filtered the same way (the applied SQL batch rows stay on the server 14 days).
    COUNTERS = {
      'api_uses' => ['dashboard.kpis.api_uses', 'fa-chart-line', :stats_path],
      'import_queues' => ['dashboard.kpis.import_queues', 'fa-list-check', :api_import_queues_path, { import_queues_grid: { done: 'NO' } }],
      'issues' => ['dashboard.kpis.issues', 'fa-bug', :api_issues_path],
      'users' => ['dashboard.kpis.users', 'fa-users', :api_users_path]
    }.freeze

    # Snapshot status => state shown by the tiles.
    STATUS_STATES = { 'unreachable' => :unreachable, 'no_credentials' => :sign_in, 'unauthorized' => :sign_in }.freeze

    # == Params:
    # - snapshot: the Ops::Snapshot of the API (KpiRefreshJob.read), or nil;
    # - url: the configured API base URL; offline: true in an API-offline session (tiles without links);
    # - now: reference time.
    def initialize(snapshot:, url:, offline: false, now: Time.current)
      super()
      @snapshot = snapshot
      @payload = snapshot&.payload.is_a?(Hash) ? snapshot.payload : nil
      @url = url
      @offline = offline
      @now = now
    end

    # One Kpi::TileComponent per counter.
    def tiles
      COUNTERS.map do |key, (label_key, icon, route, route_params)|
        value = values[key]
        TileComponent.new(key:, label: t(label_key), icon:, value: value.is_a?(Integer) ? value : nil,
                          fetched_at: parse_time(fetched_at[key]), state: state_for(key, value),
                          path: @offline ? nil : helpers.public_send(route, **route_params.to_h))
      end
    end

    protected

    def snapshot? = @payload.present?

    # "as of 10:15 (4 minutes ago)" for the last run, or nil.
    def as_of_text
      return unless snapshot?

      t('dashboard.kpis.as_of', time: l(@snapshot.taken_at.localtime, format: :short), ago: helpers.time_ago_in_words(@snapshot.taken_at))
    end

    # Status note of the last run (nil when it went fine).
    def status_text
      return unless snapshot?

      status = @payload['status'].to_s
      t("dashboard.kpis.status.#{status}", default: status) unless status == 'ok'
    end

    def no_data_text
      t('dashboard.kpis.no_data', url: @url.presence || t('dashboard.kpis.no_url'))
    end

    private

    def values
      @values ||= @payload&.dig('values').is_a?(Hash) ? @payload['values'] : {}
    end

    def fetched_at
      @fetched_at ||= @payload&.dig('fetched_at').is_a?(Hash) ? @payload['fetched_at'] : {}
    end

    def errors
      @errors ||= @payload&.dig('errors').is_a?(Hash) ? @payload['errors'] : {}
    end

    # nil (current value) or the state to show for the counter.
    def state_for(key, value)
      return :no_data unless snapshot?

      status_state = STATUS_STATES[@payload['status'].to_s]
      return status_state if status_state
      return :unavailable if errors.key?(key) || !value.is_a?(Integer)

      nil
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
