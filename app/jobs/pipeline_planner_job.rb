# frozen_string_literal: true

#
# = PipelinePlannerJob
#
# One pass of SeasonBoard::PipelinePlanner on the Season board season (phase 10): queues the prepares and the
# automatic manifest extractions the rows need next (through SeasonBoard::Scheduler). Never commits, never pushes.
#
# Enqueued (PipelinePlannerJob.enqueue_after) at the end of MeetingCrawlJob, SourceCrawlJob, ManifestExtractJob, a
# successful DataFixPrepareJob and FedernuotoWatchJob, by the board's "Prepare all" button, and every 15 minutes as the
# recurring task 'pipeline_planner' (the safety net). Queues nothing with the master switch off
# (DataFix::Automation, or ADMIN2_AUTOMATION=0). Never raises.
#
# Every pass starts with SeasonBoard::ActivityReconciler, BEFORE the switch check (it queues nothing): it closes the
# board activity entries a job could not close (a finished prepare run, a queued job no longer in the queue).
#
class PipelinePlannerJob < ApplicationJob
  queue_as :default

  # One pass at a time (the others wait: each pass is cheap and re-reads the board).
  limits_concurrency key: 'pipeline_planner', to: 1, duration: 10.minutes

  # Enqueues a pass after +trigger+ (a job class name) when the master switch is on. Never raises; returns true when
  # enqueued.
  def self.enqueue_after(trigger)
    return false unless DataFix::Automation.enabled?

    perform_later(trigger: trigger.to_s)
    true
  rescue StandardError => e
    Rails.logger.warn("[PipelinePlannerJob] not enqueued after #{trigger}: #{e.class}: #{e.message}")
    false
  end

  # - trigger: what asked for the pass ('schedule', 'board', or the job class name), logged only.
  # Returns the SeasonBoard::PipelinePlanner::Plan (empty when paused or without a season).
  def perform(trigger: 'schedule')
    reconcile_activity
    return SeasonBoard::PipelinePlanner::Plan.empty unless DataFix::Automation.enabled?

    season = SeasonBoard::Builder.latest_season
    return SeasonBoard::PipelinePlanner::Plan.empty unless season

    plan = SeasonBoard::PipelinePlanner.new(season:).call
    log_plan(plan, trigger)
    plan
  rescue StandardError => e
    Rails.logger.error("[PipelinePlannerJob] #{trigger}: #{e.class}: #{e.message}")
    SeasonBoard::PipelinePlanner::Plan.empty
  end

  private

  # Never raises (a failure only skips the reconciliation of this pass).
  def reconcile_activity
    closed = SeasonBoard::ActivityReconciler.new.call
    return if closed.empty?

    Rails.logger.info("[PipelinePlannerJob] activity entries closed: #{closed.map { |row| "#{row.kind} #{row.key} #{row.status}" }.join(', ')}")
  rescue StandardError => e
    Rails.logger.warn("[PipelinePlannerJob] activity reconciliation skipped: #{e.class}: #{e.message}")
  end

  def log_plan(plan, trigger)
    return unless plan.queued?

    Rails.logger.info("[PipelinePlannerJob] #{trigger}: prepares #{plan.prepares.join(', ').presence || '-'}; " \
                      "extractions #{plan.extractions.join(', ').presence || '-'}")
  end
end
