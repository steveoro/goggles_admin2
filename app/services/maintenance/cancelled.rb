# frozen_string_literal: true

module Maintenance
  # Raised while a run is planning when the operator asked to cancel it (Ops::OperationRun#cancel_requested_at): the
  # Executor refuses the run with reason 'cancelled'. Never rescued by Maintenance::Operation#plan.
  class Cancelled < StandardError; end
end
