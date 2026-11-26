# frozen_string_literal: true

# = ApplicationJob
#
# Common parent job object
class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # Phase 14: while a guided DB restore holds DbRestore::Lock every job (but DbRestore::RestoreJob) records an event
  # and returns without running (#skipped_by_db_restore runs instead); after a restore the MySQL pool reconnects once
  # (DbRestore::JobGuard).
  # The job class is the source of any remote write made while it runs (see Current, Ops::RemoteWrite);
  # the previous value is restored afterwards (a job performed inline inside a request).
  around_perform do |job, block|
    if DbRestore::JobGuard.skip?(job)
      job.send(:after_db_restore_skip)
      next
    end

    DbRestore::JobGuard.before_perform
    Current.set(source: job.class.name) { block.call }
  end

  private

  # Runs #skipped_by_db_restore, never raising.
  def after_db_restore_skip
    skipped_by_db_restore
  rescue StandardError => e
    Rails.logger.warn("[#{self.class.name}] DB restore skip hook failed: #{e.class}: #{e.message}")
  end

  # Hook run instead of #perform when a DB restore skipped the job (the job is dropped, not re-run): a job tracking its
  # work elsewhere (activity log, run rows) closes it here. It must not touch MySQL (it is being replaced). No-op here.
  def skipped_by_db_restore; end
end
