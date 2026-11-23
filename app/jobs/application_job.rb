# frozen_string_literal: true

# = ApplicationJob
#
# Common parent job object
class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  # The job class is the source of any remote write made while it runs (see Current, Ops::RemoteWrite);
  # the previous value is restored afterwards (a job performed inline inside a request).
  around_perform do |job, block|
    Current.set(source: job.class.name) { block.call }
  end
end
