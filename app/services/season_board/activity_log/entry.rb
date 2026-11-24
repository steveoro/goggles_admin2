# frozen_string_literal: true

module SeasonBoard
  class ActivityLog
    # Read-only view of a single log entry.
    # (label and heartbeat_at are optional, phase 15: entries written before have neither.)
    Entry = Data.define(:fin_event_id, :kind, :origin, :status, :queued_at, :started_at, :finished_at, :url, :message,
                        :label, :heartbeat_at) do
      def initialize(label: nil, heartbeat_at: nil, **) = super

      STATUSES.each { |st| define_method(:"#{st}?") { status == st } }

      # True for a queued/running entry that has exceeded its staleness threshold
      # (a running entry with a recent heartbeat never is).
      def stale?(now = Time.current) # rubocop:disable Metrics/CyclomaticComplexity
        case status
        when :running
          return false if heartbeat_at.present? && heartbeat_at >= now - HEARTBEAT_STALE_AFTER

          (started_at || queued_at).nil? || (started_at || queued_at) < now - RUNNING_STALE_AFTER
        when :queued then queued_at.nil? || queued_at < now - QUEUED_STALE_AFTER
        else false
        end
      end

      # True for a queued/running entry that is not stale.
      def busy?(now = Time.current)
        (queued? || running?) && !stale?(now)
      end

      # True for the entry of a Sources crawl or extraction (key 'src:<sha1>', no FIN id).
      def source? = ActivityLog.source_key?(fin_event_id)

      # Most recent timestamp of the entry (or nil).
      def last_timestamp
        [queued_at, started_at, finished_at].compact.max
      end
    end
  end
end
