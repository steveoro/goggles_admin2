# frozen_string_literal: true

module Import
  #
  # = Import::Progress
  #
  # Progress sinks injected (keyword +progress:+) into the Data-Fix solvers, Import::Phase5Populator and
  # Import::Committers::Main. Each sink is a callable: <tt>sink.call(message, current, total)</tt>, never raising.
  #
  # - Cable: broadcasts on 'ImportStatusChannel' (the progress modal of the /data_fix and /push pages).
  #   Interactive requests ONLY: a background job must never use it (the channel would open the modal on
  #   every Data-Fix page of every operator).
  # - Null: discards everything (specs, rebuilders, verdict computations).
  # - Ops: throttled writes (about once per +interval+ seconds, plus the last step) to an ops DB row
  #   (Ops::CommitReport, Ops::PipelineRun) through its #record_progress!(message:, current:, total:).
  #   Never raises; a failed write is just logged.
  #
  module Progress
    # ActionCable sink for interactive requests (today's behaviour of every broadcast_progress).
    class Cable
      CHANNEL = 'ImportStatusChannel'

      def call(message, current, total)
        ActionCable.server.broadcast(CHANNEL, { msg: message, progress: current, total: total })
      rescue StandardError => e
        Rails.logger.warn("[Import::Progress::Cable] Failed to broadcast progress: #{e.message}")
      end
    end

    # No-op sink.
    class Null
      def call(_message, _current, _total) = nil
    end

    # Throttled ops-row sink (for jobs). The record must respond to #record_progress!(message:, current:, total:).
    class Ops
      DEFAULT_INTERVAL = 1.0 # seconds

      attr_reader :record, :interval

      def initialize(record, interval: DEFAULT_INTERVAL, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @record = record
        @interval = interval.to_f
        @clock = clock
        @last_written_at = nil
      end

      def call(message, current, total)
        return if record.nil?

        now = @clock.call
        last_step = total.to_i.positive? && current.to_i >= total.to_i
        return if !last_step && @last_written_at && (now - @last_written_at) < interval

        @last_written_at = now
        ::Ops.safely { record.record_progress!(message: message.to_s.truncate(500), current: current.to_i, total: total.to_i) }
      end
    end

    # Default sink for the interactive callers.
    def self.default
      Cable.new
    end
  end
end
