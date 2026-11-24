# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::PostSteps
  #
  # Wizard step 7, right after a load (DbRestore::RestoreJob, lock held; also after a terminal db:rebuild). In order,
  # each one recorded as the run's step and log line, its result in run.outcome:
  #  1. reconnect: fresh MySQL connections for this process (the old ones point to the dropped DB);
  #  2. environment: ar_internal_metadata 'environment' back to the local one (a production dump says 'production',
  #     which makes Rails refuse destructive DB tasks);
  #  3. preserved: API URL and operator JWT re-applied (DbRestore::Preserver);
  #  4. maintenance: the maintenance flag off;
  #  5. migrations: engine migrations known locally but missing from the restored schema_migrations are REPORTED with
  #     the command to run (never run here);
  #  6. staging: DataFix::StagingPurger.purge_all! (the five data_import_* tables);
  #  7. stale: 'db_epoch' and 'data_fix.db_generation' bumped (Data-Fix verdicts and new-entity matches go stale; every
  #     process reconnects its MySQL pool, DbRestore::Reconnect);
  #  8. remote_writes: the remote-only writes logged before the dump time count as covered (the acknowledgement time
  #     of Ops::RemoteWrite moves forward to the dump time, never back);
  #  9. lock: DbRestore::Lock released (before the queues resume: a job claimed while the lock is held is skipped);
  # 10. queues: the queues paused by the restore resumed;
  # 11. drift: DriftCheckJob.perform_now(trigger: 'post_restore');
  # then the run is 'finished' and the 'db_restore.finished' event recorded.
  # A step that raises stops the sequence (the caller marks the run interrupted; the lock stays).
  #
  class PostSteps
    attr_reader :run

    def initialize(run:, queues: DbRestore::Queues.new, drift_job: DriftCheckJob)
      @run = run
      @queues = queues
      @drift_job = drift_job
    end

    def call
      run.update!(status: 'post_steps') unless run.post_steps?
      reconnect!
      reset_environment!
      reapply_preserved!
      maintenance_off!
      report_migrations!
      purge_staging!
      mark_stale!
      cover_remote_writes!
      release_lock!
      resume_queues!
      check_drift!
      finish!
    end

    private

    def connection
      ActiveRecord::Base.connection_pool.lease_connection
    end

    def reconnect!
      run.step!(:reconnect)
      ActiveRecord::Base.connection_pool.disconnect!
      connection.verify!
    end

    def reset_environment!
      run.step!(:environment)
      conn = connection
      updated = conn.update("UPDATE ar_internal_metadata SET value = #{conn.quote(Rails.env.to_s)}, updated_at = #{conn.quote(Time.now.utc)} " \
                            "WHERE #{conn.quote_column_name('key')} = 'environment'")
      run.record_outcome!('environment' => updated.to_i.positive? ? Rails.env.to_s : 'missing')
    end

    def reapply_preserved!
      run.step!(:preserved)
      run.record_outcome!(DbRestore::Preserver.reapply!(run))
    end

    def maintenance_off!
      run.step!(:maintenance)
      GogglesDb::AppParameter.maintenance = false
      run.record_outcome!('maintenance' => 'off')
    end

    def report_migrations!
      run.step!(:migrations)
      applied = connection.select_values('SELECT version FROM schema_migrations').map(&:to_s)
      pending = DbRestore.local_schema_versions - applied
      run.record_outcome!('pending_migrations' => pending, 'schema_version' => applied.max)
    end

    def purge_staging!
      run.step!(:staging)
      deleted = DataFix::StagingPurger.purge_all!
      run.record_outcome!('staging_purged' => deleted.values.sum)
    end

    def mark_stale!
      run.step!(:stale)
      epoch = Ops::Setting.db_epoch + 1
      Ops::Setting.store!(Ops::Setting::DB_EPOCH_KEY, epoch)
      DataFix::Pipeline.bump_db_generation!
      # (This process already has fresh connections: don't disconnect them again.)
      DbRestore::Reconnect.remember!(epoch)
      run.record_outcome!('db_epoch' => epoch)
    end

    def cover_remote_writes!
      run.step!(:remote_writes)
      taken_at = run.dump_taken_at
      current = Ops::RemoteWrite.acknowledged_at
      covered = taken_at.present? && !snapshot_load? && (current.nil? || current < taken_at)
      Ops::RemoteWrite.acknowledge!(taken_at) if covered
      run.record_outcome!('remote_writes_covered_until' => covered ? taken_at.utc.iso8601 : nil)
    end

    def resume_queues!
      run.step!(:queues)
      resumed = @queues.resume!(run.preserved.to_h['paused_queues'])
      run.record_outcome!('queues_resumed' => resumed)
    end

    def release_lock!
      run.step!(:lock)
      DbRestore::Lock.release!(run)
    end

    def check_drift!
      run.step!(:drift)
      fingerprint = @drift_job.perform_now(trigger: 'post_restore')
      run.record_outcome!('drift_verdict' => fingerprint.respond_to?(:verdict) ? fingerprint.verdict : nil,
                          'db_fingerprint_id' => fingerprint.respond_to?(:id) ? fingerprint.id : nil)
    rescue StandardError => e
      # (The restore is done: a failed check only leaves the verdict to the next scheduled check.)
      run.append_log!("drift check failed: #{e.class}")
      run.record_outcome!('drift_verdict' => nil, 'drift_error' => DbRestore.scrub("#{e.class}: #{e.message}").truncate(300))
    end

    def finish!
      run.update!(status: 'finished', step: 'finished', finished_at: Time.current, error: nil)
      run.append_log!(I18n.t('db_restore.steps.finished'))
      Ops.record_event!(kind: snapshot_load? ? 'db_restore.rolled_back' : 'db_restore.finished', level: 'success', actor: 'operator',
                        subject_type: 'restore_run', subject_key: run.id, link_path: url_helpers.db_restore_result_path(run),
                        data: event_data)
    end

    def event_data
      outcome = run.outcome.to_h
      { 'dump' => run.dump_basename, 'database' => run.target_database, 'drift' => outcome['drift_verdict'],
        'pending_migrations' => Array(outcome['pending_migrations']).size }
    end

    def snapshot_load?
      run.outcome.to_h['loaded_from'] == 'snapshot'
    end

    def url_helpers
      Rails.application.routes.url_helpers
    end
  end
end
