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
  # and returns without running; after a restore the MySQL pool reconnects once (DbRestore::JobGuard).
  # The job class is the source of any remote write made while it runs (see Current, Ops::RemoteWrite);
  # the previous value is restored afterwards (a job performed inline inside a request).
  around_perform do |job, block|
    next if DbRestore::JobGuard.skip?(job)

    DbRestore::JobGuard.before_perform
    Current.set(source: job.class.name) { block.call }
  end
end
