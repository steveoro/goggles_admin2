# frozen_string_literal: true

#
# = FedernuotoWatchJob
#
# Checks the FIN "Riepilogo Eventi" page for changes (see FedernuotoWatch::Checker).
#
# Scheduled hourly as a Solid Queue recurring task (config/recurring.yml) and enqueued on demand
# from the UI ("Check now", with manual: true).
#
# When the check detects a change, it is followed up as by every PipelinePlannerJob pass (SeasonBoard::ChangeChain,
# 0.10.103: the FIN 'Eventi' calendar crawl, the crawls of the new or changed meetings with a link, the re-crawl of the
# structure-committed meetings FIN now lists with results), then a PipelinePlannerJob pass is enqueued (phase 10).
# After every check that did not fail, the automatic dismissal of the alert is checked (FedernuotoWatch::ParityCheck:
# with the master switch on and the parity reached; otherwise it refreshes the alert's progress lines). Nothing is
# queued and nothing acknowledged while the automation master switch is off. Planning failures never fail the check.
#
class FedernuotoWatchJob < ApplicationJob
  queue_as :default

  # Never run two checks at the same time (e.g. the recurring one + a manual one):
  limits_concurrency key: 'federnuoto_watch', to: 1, duration: 10.minutes

  # == Params:
  # - manual: true when requested from the UI (broadcasts feedback also when nothing changed or on errors).
  # Returns the Checker outcome.
  def perform(manual: false)
    outcome = FedernuotoWatch::Checker.call(manual:)
    season = (SeasonBoard::Builder.latest_season if outcome != :error)
    follow_up_change(season) if outcome == :changed
    check_parity(season) if outcome != :error
    outcome
  end

  private

  def follow_up_change(season)
    outcome = SeasonBoard::ChangeChain.new(season:).call
    Rails.logger.info("[FedernuotoWatchJob] calendar crawl: #{outcome.calendar}") if outcome.calendar == :queued
    Rails.logger.info("[FedernuotoWatchJob] automatic crawls queued: #{outcome.crawls.join(', ')}") if outcome.crawls.present?
    Rails.logger.info("[FedernuotoWatchJob] results published, re-crawls queued: #{outcome.recrawls.join(', ')}") if outcome.recrawls.present?
  rescue StandardError => e
    Rails.logger.error("[FedernuotoWatchJob] crawl planning failed: #{e.class}: #{e.message}")
  ensure
    PipelinePlannerJob.enqueue_after(self.class.name)
  end

  def check_parity(season)
    FedernuotoWatch::ParityCheck.call(season:)
  rescue StandardError => e
    Rails.logger.error("[FedernuotoWatchJob] parity check failed: #{e.class}: #{e.message}")
  end
end
