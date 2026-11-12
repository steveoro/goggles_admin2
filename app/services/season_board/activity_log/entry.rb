# frozen_string_literal: true

module SeasonBoard
  class ActivityLog
    # Read-only view of a single log entry.
    Entry = Data.define(:fin_event_id, :kind, :origin, :status, :queued_at, :started_at, :finished_at, :url, :message) do
      STATUSES.each { |st| define_method(:"#{st}?") { status == st } }

      # True for a queued/running entry that has exceeded its staleness threshold.
      def stale?(now = Time.current)
        case status
        when :running then (started_at || queued_at).nil? || (started_at || queued_at) < now - RUNNING_STALE_AFTER
        when :queued then queued_at.nil? || queued_at < now - QUEUED_STALE_AFTER
        else false
        end
      end

      # True for a queued/running entry that is not stale.
      def busy?(now = Time.current)
        (queued? || running?) && !stale?(now)
      end

      # Most recent timestamp of the entry (or nil).
      def last_timestamp
        [queued_at, started_at, finished_at].compact.max
      end
    end
  end
end
