# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::RunJob
  #
  # Runs one Ops::OperationRun (Maintenance::Executor) on the single-thread 'maintenance' worker (shared with the
  # read-only health runs, which it overtakes: priority 0).
  #
  # - Enqueued ONLY by the operations controllers after an operator click (Maintenance::RunsController#create for a
  #   dry run, #apply for an apply): never by a scheduler, a planner, a callback, a health run or another job
  #   (spec-asserted). Rake callers (phase 13) run the Executor inline instead.
  # - No retries (no retry_on / discard_on; ApplicationJob declares none): an apply is never re-run by itself.
  # - In apply mode it shares the concurrency key 'local_db_writer' (group 'local_db_writer') with the Data-Fix commit
  #   job, because both write the local primary DB: a commit queued while an operation applies waits, and vice versa.
  #   A dry run writes nothing: its key is per run (never waits).
  # - Inherits ApplicationJob, so the DB restore guard of phase 14 covers it.
  #
  class RunJob < ApplicationJob
    queue_as :maintenance
    queue_with_priority 0

    LOCAL_DB_WRITER = 'local_db_writer'

    limits_concurrency key: ->(run_id:, mode: 'apply') { mode.to_s == 'apply' ? LOCAL_DB_WRITER : "operation_preview_#{run_id}" },
                       group: LOCAL_DB_WRITER, to: 1, duration: 2.hours

    # == Params
    # - run_id: the queued Ops::OperationRun; mode: its mode (the concurrency key depends on it; a mismatch with the
    #   stored mode is refused).
    def perform(run_id:, mode: 'apply')
      run = Ops.safely { Ops::OperationRun.find_by(id: run_id) }
      return unless run
      return run.refuse!(:mode_mismatch) if run.queued? && run.mode != mode.to_s

      run.update_columns(job_id:) if run.queued? && run.job_id.blank? # rubocop:disable Rails/SkipsModelValidations
      Maintenance::Executor.new(run:).call
    end
  end
end
