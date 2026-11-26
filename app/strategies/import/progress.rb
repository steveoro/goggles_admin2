# frozen_string_literal: true

require 'securerandom'

module Import
  #
  # = Import::Progress
  #
  # Progress sinks injected (keyword +progress:+) into DataFix::Pipeline, the Data-Fix solvers, Import::Phase5Populator
  # and Import::Committers::Main. Each sink is a callable: <tt>sink.call(message, current, total)</tt>, plus
  # <tt>sink.done</tt> (end of the operation); neither ever raises.
  #
  # - Cable: broadcasts on 'ImportStatusChannel', shown by the progress strip under the top bar
  #   (Shell::ProgressStripComponent) of the operator's open pages. Created ONLY by
  #   DataFix::BaseController#progress_sink (interactive requests): a background job or a rake task must never use it
  #   (the strip would show on every page of every operator).
  # - Null: discards everything; the default of every constructor (.default), so a caller that passes no sink
  #   broadcasts nothing.
  # - Ops: throttled writes (about once per +interval+ seconds, plus the last step) to an ops DB row
  #   (Ops::CommitReport, Ops::PipelineRun) through its #record_progress!(message:, current:, total:).
  #   Never raises; a failed write is just logged.
  #
  module Progress
    # ActionCable sink for interactive requests (DataFix::BaseController#progress_sink: one per request).
    #
    # One operation at a time, with its own +op+ id:
    # - a tick: <tt>{ op:, seq:, scope:, msg:, progress:, total: }</tt> (+seq+ counts from 1 in each operation);
    # - the end: <tt>{ op:, state: 'done' }</tt>, sent by #done only when the operation sent a tick (a request that
    #   built nothing broadcasts nothing). #done closes the operation: a later tick starts a new one (new +op+, +seq+
    #   from 1), since the strip ignores every message of a finished op.
    class Cable
      CHANNEL = 'ImportStatusChannel'

      attr_reader :op, :scope, :seq

      # == Params:
      # - scope: what the operation works on (the source base name for Data-Fix), shown by the strip; optional.
      def initialize(scope: nil)
        @scope = scope.to_s.presence
        start_operation
      end

      def call(message, current, total)
        @seq += 1
        broadcast({ op:, seq:, scope:, msg: message, progress: current, total: })
      end

      # Ends the operation: one 'done' message, only after a tick; then the next tick starts a new operation.
      def done
        return unless open?

        broadcast({ op:, state: 'done' })
        start_operation
      end

      # True while the current operation has sent a tick and no 'done' yet.
      def open?
        seq.positive?
      end

      private

      def start_operation
        @op = SecureRandom.hex(8)
        @seq = 0
      end

      def broadcast(payload)
        ActionCable.server.broadcast(CHANNEL, payload)
      rescue StandardError => e
        Rails.logger.warn("[Import::Progress::Cable] Failed to broadcast progress: #{e.message}")
      end
    end

    # No-op sink.
    class Null
      def call(_message, _current, _total) = nil

      def done = nil
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

      # (the run row's own status tells the end: nothing to write)
      def done = nil
    end

    # Default sink of every constructor taking a +progress:+ keyword: Null (only DataFix::BaseController#progress_sink
    # creates a Cable).
    def self.default
      Null.new
    end
  end
end
