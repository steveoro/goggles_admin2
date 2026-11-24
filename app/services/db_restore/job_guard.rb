# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::JobGuard
  #
  # Job side of DbRestore::Lock, called by the +around_perform+ of ApplicationJob (so every job class of every phase
  # is covered): while a restore holds the lock a job records an 'db_restore.job_skipped' event and returns without
  # running (a recurring job simply runs next time; the click-only jobs are also refused at enqueue by their
  # controllers). Only DbRestore::RestoreJob runs through the lock. Outside a restore, it reconnects the MySQL
  # pool once after a restore (DbRestore::Reconnect).
  #
  module JobGuard
    # Job classes allowed to run while the lock is held.
    EXEMPT = %w[DbRestore::RestoreJob].freeze

    module_function

    # True when +job+ must not run now. Never raises.
    def skip?(job)
      return false if EXEMPT.include?(job.class.name)

      run = DbRestore::Lock.current_run
      return false unless run

      record_skip(job, run)
      true
    end

    # Runs before every job allowed to perform.
    def before_perform
      DbRestore::Reconnect.check!
    end

    def record_skip(job, run)
      Rails.logger.warn("[DbRestore::JobGuard] #{job.class.name} skipped: DB restore run #{run.id} in progress")
      Ops.record_event!(kind: 'db_restore.job_skipped', level: 'warning', actor: 'job', subject_type: 'restore_run',
                        subject_key: run.id, data: { 'job' => job.class.name, 'queue' => job.queue_name.to_s, 'job_id' => job.job_id })
    end
  end
end
