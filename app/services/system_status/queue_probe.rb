# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::QueueProbe
  #
  # Liveness of the Solid Queue processes (supervisor, dispatcher, workers), read inline from the local
  # queue DB: a dead queue could never refresh its own snapshot.
  #
  # :ok when at least one process sent a heartbeat in the last HEARTBEAT_WINDOW, :error otherwise;
  # :unknown when Solid Queue is not the Active Job adapter (e.g. the test environment) or the queue DB
  # can't be read (missing file or tables). Never raises.
  #
  class QueueProbe < Probe
    HEARTBEAT_WINDOW = 5.minutes

    # Number of Solid Queue processes with a heartbeat after +since+ (queue DB read).
    def self.live_process_count(since:)
      SolidQueue::Process.where(last_heartbeat_at: since..).count
    end

    protected

    def evaluate
      return result(:unknown, detail: detail_text(:not_in_use)) unless solid_queue_adapter?

      count = self.class.live_process_count(since: now - HEARTBEAT_WINDOW)
      if count.positive?
        result(:ok, detail: detail_text(:ok, count:), checked_at: now)
      else
        result(:error, detail: detail_text(:dead), checked_at: now)
      end
    end

    private

    def solid_queue_adapter?
      Rails.application.config.active_job.queue_adapter.to_s == 'solid_queue' && defined?(SolidQueue::Process)
    end
  end
end
