# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::RestoreJob
  #
  # Wizard steps 6-7 (DbRestore::Restorer): drops and reloads the local MySQL DB from the confirmed dump, then the
  # post-steps; also "Resume from load", "Load safety snapshot" and the post-steps after a terminal load.
  #
  # - Enqueued ONLY by DbRestoreController (one call site, used by the typed confirmation and the progress page
  #   buttons: operator clicks), never by a scheduler, a callback or another job (spec-asserted).
  # - No retries (no retry_on / discard_on): a restore is never re-run by itself. Never raises.
  # - The only job class that runs while DbRestore::Lock is held (DbRestore::JobGuard::EXEMPT).
  # - Queue 'maintenance' (its worker is never paused by the restore); concurrency key 'local_db_writer' in the group
  #   'local_db_writer', shared with DataFixCommitJob and Maintenance::RunJob in apply mode (Solid Queue scopes a key
  #   by its group, the job class name by default).
  #
  class RestoreJob < ApplicationJob
    queue_as :maintenance

    limits_concurrency key: 'local_db_writer', group: 'local_db_writer', to: 1, duration: 3.hours

    # == Params
    # - run_id: Ops::RestoreRun id; mode: one of DbRestore::Restorer::MODES.
    def perform(run_id:, mode: 'load')
      run = Ops.safely { Ops::RestoreRun.find_by(id: run_id) }
      return unless run

      DbRestore::Restorer.new(run:, mode:, job_id:).call
    rescue StandardError => e
      Rails.logger.error(DbRestore.scrub("[DbRestore::RestoreJob] run #{run_id} (#{mode}): #{e.class}: #{e.message}"))
      false
    end
  end
end
