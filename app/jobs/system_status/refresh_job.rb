# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::RefreshJob
  #
  # Read-only refresh of the snapshot status probes (API ping, crawler status): each probe's #refresh!
  # writes its ops snapshot ('api.status:<base_url>', 'system_status.<key>'), read later by the
  # top bar status frame. It never commits, pushes or applies anything.
  #
  # Recurring every 5 minutes (config/recurring.yml, 'system_status_refresh') and enqueued by
  # Shell::StatusController when a snapshot is older than 2 minutes. Snapshots refreshed less than
  # SKIP_IF_FRESHER_THAN ago are skipped unless <tt>force: true</tt>.
  # Does nothing when the ops DB is not available.
  #
  class RefreshJob < ApplicationJob
    queue_as :default

    # One refresh at a time; duplicates enqueued meanwhile (e.g. several open pages) are dropped:
    limits_concurrency key: 'system_status_refresh', to: 1, duration: 5.minutes, on_conflict: :discard

    SKIP_IF_FRESHER_THAN = 1.minute

    # Returns the list of refreshed probe keys.
    def perform(force: false)
      return [] unless Ops.available?

      Registry.snapshot_probes.filter_map do |probe_class|
        probe = probe_class.new
        next if !force && !probe.refresh_due?(SKIP_IF_FRESHER_THAN)

        refresh(probe)
      end
    end

    private

    def refresh(probe)
      probe.refresh!
      probe.key
    rescue StandardError => e
      Rails.logger.warn("[SystemStatus::RefreshJob] #{probe.class.name}: #{e.class}: #{e.message}")
      nil
    end
  end
end
