# frozen_string_literal: true

module Shell
  #
  # = Shell::StatusController
  #
  # Renders the top bar status frame (<tt>turbo-frame#shell-status</tt>, lazy-loaded by Shell::TopBarComponent)
  # with one pill per SystemStatus::Registry probe.
  #
  # Reads only local data (session, local files, local queue DB, ops snapshots): no API call. When a snapshot
  # is missing or older than 2 minutes it enqueues SystemStatus::RefreshJob (a read-only probe refresh).
  # Reachable from API-offline sessions.
  #
  class StatusController < ApplicationController
    # GET /shell/status
    def show
      probe_options = { offline: api_offline_session?, api_url: Shell::APITarget.configured_url }
      @results = SystemStatus::Registry.results(**probe_options)
      request_refresh(probe_options)
      render(layout: false)
    end

    protected

    # The status frame must work in API-offline sessions too.
    def api_offline_allowed?
      true
    end

    private

    def request_refresh(probe_options)
      return unless Ops.available? && SystemStatus::Registry.refresh_due?(**probe_options)

      SystemStatus::RefreshJob.perform_later
    rescue StandardError => e
      logger.warn("[Shell::StatusController] refresh not enqueued: #{e.class}: #{e.message}")
    end
  end
end
