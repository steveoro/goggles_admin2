# frozen_string_literal: true

module Outbox
  #
  # = Outbox::PushJob
  #
  # Performs one Ops::PushRun (Outbox::Pusher). Enqueued ONLY by OutboxController#push, after the operator
  # confirmed the push on the confirmation page: never by a scheduler, planner, callback or another job
  # (spec/jobs/outbox/push_job_spec.rb scans app/ for that).
  #
  # - Queue 'outbox': its own single-thread worker (config/queue.yml), so a push never waits behind a 30-minute
  #   crawl ('background') nor delays the quick jobs ('default').
  # - One push at a time (concurrency key 'outbox_push').
  # - No retry, ever: a failure is recorded on the run and the job is discarded (a re-post could apply a script
  #   twice).
  #
  class PushJob < ApplicationJob
    queue_as :outbox

    limits_concurrency key: 'outbox_push', to: 1, duration: 2.hours

    # (no retry_on: an unexpected error stops the run, recorded, and the job is dropped)
    discard_on StandardError do |job, error|
      job.send(:record_failure, error)
    end

    def perform(push_run_id)
      run = Ops::PushRun.find_by(id: push_run_id)
      return unless run&.running?

      @run = run
      run.update!(job_id:)
      Outbox::Pusher.new(run:).call
    end

    private

    def record_failure(error)
      Rails.logger.error("[Outbox::PushJob] run #{@run&.id}: #{error.class}: #{error.message}")
      Ops.safely do
        next unless @run&.reload&.running?

        @run.stop!(script: nil, error: "#{error.class}: #{error.message}")
        Ops.record_event!(kind: 'outbox.push_stopped', level: 'error', actor: 'job', subject_type: 'push_run',
                          subject_key: @run.id, data: { 'error' => error.message.to_s.truncate(500) })
      end
      Outbox::Notifier.ping
    end
  end
end
