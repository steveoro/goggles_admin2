# frozen_string_literal: true

module Outbox
  #
  # = Outbox::Summary
  #
  # Counters of the Outbox registry for the dashboard inbox (Outbox::InboxSource) and the page header:
  # read only, one grouped query plus the oldest pending row.
  #
  # == Usage
  #   summary = Outbox::Summary.call   # => nil when the ops DB is not available
  #   summary.pending          # => 3     (state 'pending')
  #   summary.held             # => 1
  #   summary.in_doubt         # => 0
  #   summary.sent_unverified  # => 2     (state 'sent': pushed, outcome not known yet)
  #   summary.oldest_pending   # => Ops::SqlScript (lowest seq in 'pending'), or nil
  #   summary.to_h
  #
  class Summary
    Result = Data.define(:pending, :held, :in_doubt, :sent_unverified, :oldest_pending) do
      # Scripts still to push (pending, held, in doubt).
      def waiting = pending + held + in_doubt
      def empty? = waiting.zero? && sent_unverified.zero?
    end

    def self.call
      Ops.safely do
        next unless Ops.available?

        counts = Ops::SqlScript.where(state: %w[pending held in_doubt sent]).group(:state).count
        Result.new(pending: counts.fetch('pending', 0), held: counts.fetch('held', 0), in_doubt: counts.fetch('in_doubt', 0),
                   sent_unverified: counts.fetch('sent', 0), oldest_pending: Ops::SqlScript.pending.ordered.first)
      end
    end
  end
end
