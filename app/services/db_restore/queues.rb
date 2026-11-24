# frozen_string_literal: true

module DbRestore
  #
  # = DbRestore::Queues
  #
  # The Solid Queue side of a restore (local queue DB): pause / resume the queues (SolidQueue::Queue#pause/resume,
  # which keep the queued jobs for later) and list the running jobs (claimed executions).
  #
  # Reads nothing unless Solid Queue is the Active Job adapter (the test environment uses :test: specs stub this
  # class) and never raises: a missing queue DB makes #available? false and every list empty.
  #
  class Queues
    Claimed = Data.define(:job_id, :class_name, :queue_name, :since)

    def available?
      return @available if defined?(@available)

      @available = Dashboard::QueueActivity.solid_queue? &&
                   safely(false) { SolidQueue::Job.connection.table_exists?(SolidQueue::Job.table_name) }
    end

    # Pauses the given queues; returns the names paused by this call (the ones already paused stay as they are and
    # are not returned, so that #resume! leaves them paused).
    def pause!(names)
      return [] unless available?

      Array(names).map(&:to_s).select do |name|
        safely(false) do
          queue = SolidQueue::Queue.find_by_name(name) # rubocop:disable Rails/DynamicFindBy
          next false if queue.paused?

          queue.pause
          true
        end
      end
    end

    # Resumes the given queues; returns the names resumed.
    def resume!(names)
      return [] unless available?

      Array(names).map(&:to_s).select do |name|
        safely(false) do
          SolidQueue::Queue.find_by_name(name).resume # rubocop:disable Rails/DynamicFindBy
          true
        end
      end
    end

    def paused?(name)
      available? && safely(false) { SolidQueue::Queue.find_by_name(name.to_s).paused? } # rubocop:disable Rails/DynamicFindBy
    end

    # Running jobs (Array of Claimed), oldest first; +except_job_ids+: Active Job ids to leave out (the caller's).
    def claimed(except_job_ids: [])
      return [] unless available?

      skip = Array(except_job_ids).compact_blank.map(&:to_s)
      safely([]) do
        SolidQueue::ClaimedExecution.includes(:job).order(:created_at).filter_map do |execution|
          job = execution.job
          next if job.nil? || skip.include?(job.active_job_id.to_s)

          Claimed.new(job_id: job.active_job_id, class_name: job.class_name, queue_name: job.queue_name, since: execution.created_at)
        end
      end
    end

    # Jobs of the given classes waiting to run (ready, scheduled or blocked by a concurrency limit; Array of Claimed,
    # +since+ = enqueue time).
    def queued(class_names:)
      return [] unless available?

      names = Array(class_names).map(&:to_s)
      safely([]) do
        [SolidQueue::ReadyExecution, SolidQueue::ScheduledExecution, SolidQueue::BlockedExecution].flat_map do |execution|
          execution.joins(:job).where(SolidQueue::Job.table_name => { class_name: names }).includes(:job).map do |row|
            Claimed.new(job_id: row.job.active_job_id, class_name: row.job.class_name, queue_name: row.job.queue_name,
                        since: row.created_at)
          end
        end
      end
    end

    private

    def safely(default)
      yield
    rescue StandardError => e
      Rails.logger.warn("[DbRestore::Queues] #{e.class}: #{e.message}")
      default
    end
  end
end
