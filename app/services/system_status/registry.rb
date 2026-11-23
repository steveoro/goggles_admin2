# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::Registry
  #
  # Ordered list of the status probes shown as pills in the top bar (Shell::StatusController) and
  # refreshed by SystemStatus::RefreshJob. Phase 05 extends PROBES (cable, ops DB, watcher age, ...).
  #
  class Registry
    # Probe class names, in display order:
    PROBES = %w[
      SystemStatus::APIProbe SystemStatus::CrawlerProbe SystemStatus::QueueProbe SystemStatus::FINWatchProbe
      SystemStatus::DriftV0Probe
    ].freeze

    # The status frame asks for a refresh when a snapshot is older than this:
    REFRESH_AFTER = 2.minutes

    class << self
      # Probe classes, in order.
      def probes
        PROBES.map(&:constantize)
      end

      # Probe classes in :snapshot mode (refreshed by RefreshJob).
      def snapshot_probes
        probes.select(&:snapshot?)
      end

      # Results of all the probes (see Probe#initialize for the options). Never raises and never calls
      # the network: snapshot probes only read their snapshot.
      def results(**options)
        probes.map { |probe_class| probe_class.new(**options).call }
      end

      # True when the snapshot of any snapshot probe is missing or older than +max_age+.
      def refresh_due?(max_age: REFRESH_AFTER, **options)
        snapshot_probes.any? { |probe_class| probe_class.new(**options).refresh_due?(max_age) }
      end
    end
  end
end
