# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::SnapshotJob
  #
  # Wizard step 4: the safety snapshot of the current local DB (DbRestore::Snapshot: mariadb-dump of the MySQL
  # development DB + backup of the ops DB) for a 'snapshotting' Ops::RestoreRun; the run goes back to 'ready' with
  # step 'snapshot_done' (or 'snapshot_failed' and the error: the operator retries or skips the snapshot).
  # Enqueued only by DbRestoreController#snapshot (an operator click); no retries; never raises.
  #
  class SnapshotJob < ApplicationJob
    queue_as :maintenance

    def perform(run_id:)
      run = Ops.safely { Ops::RestoreRun.find_by(id: run_id) }
      return unless run&.snapshotting?

      run.update!(job_id:)
      run.step!(:snapshot)
      path = DbRestore::Snapshot.new(run:).call
      run.update!(status: 'ready', step: 'snapshot_done', error: nil)
      run.append_log!(I18n.t('db_restore.log.snapshot_done', path: File.basename(path)))
    rescue StandardError => e
      Rails.logger.error("[DbRestore::SnapshotJob] run #{run_id}: #{e.class}: #{e.message}")
      snapshot_failed(run, e)
    end

    private

    # The run goes back to 'ready' with the error (the operator retries or skips the snapshot).
    def snapshot_failed(run, error)
      message = error.is_a?(DbRestore::Refused) || error.is_a?(DbRestore::CommandFailed) ? error.message : "#{error.class}: #{error.message}"
      Ops.safely do
        run&.update!(status: 'ready', step: 'snapshot_failed', error_text: message)
        run&.append_log!(I18n.t('db_restore.log.failed', error: message.truncate(300)))
      end
    end
  end
end
