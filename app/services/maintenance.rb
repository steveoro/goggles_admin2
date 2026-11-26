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
  # Ops setting turning the Fix buttons and the applies off (rollback switch; default on). Switched from the
  # dashboard system column and the /operations header (POST operations/switch, OperationsController#switch).
  ENABLED_SETTING = 'operations.enabled'
  # Event kind of every change of the setting (i18n 'ops.events.operations.switched').
  SWITCH_EVENT_KIND = 'operations.switched'

  module_function

  # False only when the ops setting 'operations.enabled' is stored as false.
  def enabled?
    Ops.safely(true) { !Ops.available? || Ops::Setting.fetch(ENABLED_SETTING, true) != false }
  end

  # The stored value as shown by the switch: true / false, or nil when the ops DB is missing or the read fails (the
  # switch is then shown disabled: unlike #enabled?, which stays on in those cases, it never guesses a position).
  def stored_enabled
    return nil unless Ops.available?

    Ops::Setting.fetch(ENABLED_SETTING, true) != false
  rescue StandardError => e
    Rails.logger.warn("[Maintenance] setting #{ENABLED_SETTING} unreadable: #{e.class}: #{e.message}")
    nil
  end

  # Stores the setting (true/false) and records an 'operations.switched' event. Returns the stored value, or nil
  # without the ops DB (or when the write fails).
  def store_enabled!(value, user_id: nil)
    value = ActiveModel::Type::Boolean.new.cast(value) == true
    Ops.safely do
      next unless Ops.available?

      Ops::Setting.store!(ENABLED_SETTING, value)
      Ops.record_event!(kind: SWITCH_EVENT_KIND, level: value ? 'info' : 'warning', actor: 'operator',
                        subject_type: 'setting', subject_key: ENABLED_SETTING,
                        data: { 'value' => value, 'user_id' => user_id }, link_path: '/operations')
      value
    end
  end
end
