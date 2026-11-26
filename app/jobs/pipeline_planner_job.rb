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
# 0.10.103, the order of a pass: reconcile -> master switch check -> the pending FIN change (SeasonBoard::ChangeChain:
# the 'Eventi' calendar crawl, then the crawls of the new or changed meetings with a link) -> SeasonBoard::PipelinePlanner
# -> the automatic dismissal of the FIN change alert once the parity is reached (FedernuotoWatch::ParityCheck). With the
# master switch off only the reconciliation runs: nothing is queued and the alert is never acknowledged.
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

    follow_up_change(season, trigger)
    plan = SeasonBoard::PipelinePlanner.new(season:).call
    log_plan(plan, trigger)
    check_parity(season, trigger)
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

  # The pending FIN change (SeasonBoard::ChangeChain never raises).
  def follow_up_change(season, trigger)
    outcome = SeasonBoard::ChangeChain.new(season:).call
    return unless outcome.queued?

    Rails.logger.info("[PipelinePlannerJob] #{trigger}: FIN change follow-up: calendar #{outcome.calendar}; " \
                      "crawls #{outcome.crawls.join(', ').presence || '-'}; re-crawls #{outcome.recrawls.join(', ').presence || '-'}")
  end

  # The automatic dismissal of the FIN change alert (FedernuotoWatch::ParityCheck never raises).
  def check_parity(season, trigger)
    outcome = FedernuotoWatch::ParityCheck.call(season:)
    Rails.logger.info("[PipelinePlannerJob] #{trigger}: FIN change alert acknowledged (parity reached)") if outcome.status == :acknowledged
  end

  def log_plan(plan, trigger)
    return unless plan.queued?

    Rails.logger.info("[PipelinePlannerJob] #{trigger}: prepares #{plan.prepares.join(', ').presence || '-'}; " \
                      "extractions #{plan.extractions.join(', ').presence || '-'}")
  end
end
