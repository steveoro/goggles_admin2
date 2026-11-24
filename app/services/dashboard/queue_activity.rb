# frozen_string_literal: true

module Dashboard
  #
  # = Dashboard::QueueActivity
  #
  # Read-only view of the Solid Queue tables (local queue DB) for the dashboard: running jobs (claimed
  # executions), queued jobs per queue (ready executions) and failed executions.
  #
  # Reads nothing unless Solid Queue is the Active Job adapter (the test environment uses :test) and never
  # raises: a missing queue DB or table makes #available? false and every list empty.
  #
  # == Usage
  #   activity = Dashboard::QueueActivity.new
  #   activity.running   # => [Running(job_id:, class_name:, queue_name:, since:)]
  #   activity.queued    # => { 'default' => 2, 'background' => 1 }
  #   activity.failed    # => [Failed(id:, job_id:, class_name:, queue_name:, exception_class:, message:, created_at:)]
  #
  class QueueActivity
    MAX_ROWS = 25

    Running = Data.define(:job_id, :class_name, :queue_name, :since)
    Failed = Data.define(:id, :job_id, :class_name, :queue_name, :exception_class, :message, :created_at)

    # True when Solid Queue is the Active Job adapter.
    def self.solid_queue?
      Rails.application.config.active_job.queue_adapter.to_s == 'solid_queue' && defined?(SolidQueue::Job).present?
    end

    # The Solid Queue failed execution with the given ID (its job preloaded), or nil (not found, or Solid Queue not
    # in use). Used by the dashboard Discard / Retry actions.
    def self.failed_execution(id)
      return unless solid_queue?

      SolidQueue::FailedExecution.includes(:job).find_by(id:)
    end

    def initialize(limit: MAX_ROWS)
      @limit = limit
    end

    # False when Solid Queue is not in use or its tables can't be read.
    def available?
      return @available if defined?(@available)

      @available = self.class.solid_queue? && safely(false) { SolidQueue::Job.connection.table_exists?(SolidQueue::Job.table_name) }
    end

    # Running jobs (claimed executions), oldest first.
    def running
      @running ||= read([]) do
        SolidQueue::ClaimedExecution.includes(:job).order(:created_at).limit(@limit).map do |execution|
          Running.new(job_id: execution.job_id, class_name: execution.job&.class_name, queue_name: execution.job&.queue_name,
                      since: execution.created_at)
        end
      end
    end

    # Ready (queued) executions count per queue name.
    def queued
      @queued ||= read({}) { SolidQueue::ReadyExecution.group(:queue_name).count }
    end

    # Failed executions, oldest first.
    def failed
      @failed ||= read([]) do
        SolidQueue::FailedExecution.includes(:job).order(:created_at).limit(@limit).map { |execution| failed_row(execution) }
      end
    end

    # True when a job of the class (String) is queued (ready) or running (claimed); a failed one is not pending.
    def pending?(class_name)
      read(false) do
        [SolidQueue::ReadyExecution, SolidQueue::ClaimedExecution].any? do |execution|
          execution.joins(:job).exists?(SolidQueue::Job.table_name => { class_name: })
        end
      end
    end

    # True when anything is running or queued.
    def busy?
      running.any? || queued.values.sum.positive?
    end

    private

    def read(default, &)
      return default unless available?

      safely(default, &)
    end

    def safely(default)
      yield
    rescue StandardError => e
      Rails.logger.warn("[Dashboard::QueueActivity] #{e.class}: #{e.message}")
      default
    end

    def failed_row(execution)
      error = execution.error.is_a?(Hash) ? execution.error.with_indifferent_access : {}
      Failed.new(id: execution.id, job_id: execution.job_id, class_name: execution.job&.class_name,
                 queue_name: execution.job&.queue_name, exception_class: error[:exception_class],
                 message: error[:message].to_s.truncate(300), created_at: execution.created_at)
    end
  end
end
