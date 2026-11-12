# frozen_string_literal: true

#
# = FedernuotoWatchJob
#
# Checks the FIN "Riepilogo Eventi" page for changes (see FedernuotoWatch::Checker).
#
# Scheduled hourly as a Solid Queue recurring task (config/recurring.yml) and enqueued on demand
# from the UI ("Check now", with manual: true).
#
# When the check detects a change, the changed rows not crawled yet are queued for an automatic
# crawl (SeasonBoard::CrawlPlanner); planning failures never fail the check.
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
    plan_crawls if outcome == :changed
    outcome
  end

  private

  def plan_crawls
    change = FedernuotoWatch::StateStore.new.pending_change
    return if change.blank?

    fin_ids = SeasonBoard::CrawlPlanner.new(season: SeasonBoard::Builder.latest_season).call(change)
    Rails.logger.info("[FedernuotoWatchJob] automatic crawls queued: #{fin_ids.join(', ')}") if fin_ids.present?
  rescue StandardError => e
    Rails.logger.error("[FedernuotoWatchJob] crawl planning failed: #{e.class}: #{e.message}")
  end
end
