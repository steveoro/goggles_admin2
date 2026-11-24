# frozen_string_literal: true

# Helpers for the guided DB restore specs (phase 14): runs in the ops DB, a fake queue adapter, a fake target.
module DbRestoreHelpers
  # Saved Ops::RestoreRun with sensible defaults.
  def create_restore_run(**attributes)
    Ops::RestoreRun.create!({ status: 'ready', step: 'inspected', target_database: 'goggles_development', user_id: 1,
                              dump_path: Rails.root.join('spec/fixtures/db_restore/production-0001-tiny.sql.bz2').to_s,
                              dump_bytes: 1_000 }.merge(attributes))
  end

  # A run holding DbRestore::Lock (status 'loading' by default).
  def lock_with_run(status: 'loading', **attributes)
    run = create_restore_run(status:, **attributes)
    DbRestore::Lock.acquire!(run)
    run
  end

  # DbRestore::Target passing every guard (development env, local host, development DB name).
  def passing_target(database: 'goggles_development')
    DbRestore::Target.new(env: 'development', config: { 'database' => database, 'host' => 'localhost', 'username' => 'root',
                                                        'password' => 'secret-pwd' },
                          development_database: database, production_names: %w[goggles])
  end

  # Fake DbRestore::Queues: available, records pauses/resumes (and whether the lock was still held at each resume),
  # returns +claimed+ / +queued+.
  class FakeQueues
    attr_reader :paused, :resumed, :resumed_while_locked
    attr_accessor :claimed_jobs, :queued_jobs, :available

    def initialize(claimed: [], queued: [], available: true)
      @claimed_jobs = claimed
      @queued_jobs = queued
      @available = available
      @paused = []
      @resumed = []
      @resumed_while_locked = []
    end

    def queued(class_names:)
      queued_jobs.select { |job| Array(class_names).include?(job.class_name) }
    end

    def available? = available

    def pause!(names)
      fresh = Array(names) - @paused
      @paused.concat(fresh)
      fresh
    end

    def resume!(names)
      @resumed_while_locked << DbRestore::Lock.active?
      @resumed.concat(Array(names))
      Array(names)
    end

    def claimed(except_job_ids: [])
      claimed_jobs.reject { |job| except_job_ids.include?(job.job_id) }
    end
  end

  def claimed_job(class_name, queue = 'default', job_id: SecureRandom.uuid)
    DbRestore::Queues::Claimed.new(job_id:, class_name:, queue_name: queue, since: Time.current)
  end

  # Empty Data-Fix session index (no review in progress).
  def empty_session_index
    instance_double(DataFix::SessionIndex, rows: [])
  end
end

RSpec.configure do |config|
  config.include(DbRestoreHelpers)
  # (A db_epoch change rolled back with the example must not make the next one disconnect its pinned MySQL
  #  test connection: see DbRestore::Reconnect.)
  config.after(:each) { DbRestore::Reconnect.forget! }
end
