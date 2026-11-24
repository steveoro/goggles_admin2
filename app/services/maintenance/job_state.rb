# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::JobState
  #
  # What Solid Queue knows about the job of an Ops::OperationRun (by its Active Job id), read-only and never raising:
  # - :active  => the job is still queued, scheduled, blocked (e.g. on the 'local_db_writer' semaphore) or claimed by
  #               a worker;
  # - :dead    => the job finished or failed (e.g. its worker process was pruned after a crash, or a graceful stop
  #               released it and the re-run found the run already claimed) or no longer exists, while the run row
  #               still says queued/running: nobody will ever finish that run;
  # - :unknown => Solid Queue is not the adapter (test env), its tables can't be read, or the run has no job id.
  # Used by Ops::OperationRun#interrupted?.
  #
  module JobState
    module_function

    def for(job_id)
      return :unknown if job_id.blank? || !Dashboard::QueueActivity.solid_queue?

      job = find_job(job_id)
      return :dead if job.nil? || job.finished_at.present? || job.failed_execution.present?

      :active
    rescue StandardError => e
      Rails.logger.warn("[Maintenance::JobState] #{e.class}: #{e.message}")
      :unknown
    end

    # The Solid Queue job row of an Active Job id (nil when missing).
    def find_job(job_id) = SolidQueue::Job.find_by(active_job_id: job_id.to_s)
  end
end
