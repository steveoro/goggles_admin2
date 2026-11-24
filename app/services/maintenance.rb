# frozen_string_literal: true

#
# = Maintenance
#
# The maintenance operations (phase 11, docs/plans/11-operations-health-mitigations.md): fixes that can be triggered
# from the UI, always through the same path: prefilled form => dry run (Maintenance::Operation#plan, never writes) =>
# apply locally (LocalDb::SqlRunner) => script registered in the SQL Outbox (Outbox::Writer) => health re-run.
#
# == Main entry points
# - Maintenance::Registry                      # the operations (Maintenance::Operations::*)
# - Maintenance::Executor.new(run:).call       # runs an Ops::OperationRun (preview / apply / script_only)
# - Maintenance::RunJob                        # the job, enqueued only by the operations controllers
# - Maintenance::OutputCapture.capture { }     # what the strategies print, kept with the dry run
#
module Maintenance
  # Ops setting turning the Fix buttons and the applies off (rollback switch; default on).
  ENABLED_SETTING = 'operations.enabled'

  module_function

  # False only when the ops setting 'operations.enabled' is stored as false.
  def enabled?
    Ops.safely(true) { !Ops.available? || Ops::Setting.fetch(ENABLED_SETTING, true) != false }
  end
end
