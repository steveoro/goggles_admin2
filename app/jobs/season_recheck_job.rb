# frozen_string_literal: true

#
# = SeasonRecheckJob
#
# Daily re-check of the Season board (recurring task 'season_board_recheck', config/recurring.yml):
# enqueues an automatic crawl (SeasonBoard::Scheduler.crawl!, origin :auto) for
# - :structure_committed rows asking for :check_results (past meeting, linked, no results yet);
# - :link_not_crawled rows whose last date is past;
# - :link_not_crawled rows of any date (e.g. future meetings) whose last crawl attempt failed
#   (CrawlPlanner never retries an URL already attempted);
# skipping busy rows, rows crawled less than MIN_RECRAWL_INTERVAL ago and :link_not_crawled rows flagged
# :possible_unlinked_meeting (a not-yet-linked local calendar falls within their dates: the meeting may
# already exist, imported from another source, so the operator links or crawls it by hand), past meetings first (most
# recent first), then the failed retries (soonest first), at most MAX_CRAWLS_PER_RUN per run (the
# crawls then run one at a time). A failed enqueue is logged and doesn't stop the other rows.
#
class SeasonRecheckJob < ApplicationJob
  queue_as :background

  MAX_CRAWLS_PER_RUN = 15
  MIN_RECRAWL_INTERVAL = 20.hours

  # - season_id: board season (default: SeasonBoard::Builder.latest_season)
  # Returns the Array of FIN ids enqueued.
  def perform(season_id: nil)
    season = season_id ? GogglesDb::Season.find_by(id: season_id) : SeasonBoard::Builder.latest_season
    return [] unless season

    activity_log = SeasonBoard::ActivityLog.new
    rows = SeasonBoard::Builder.new(season:, activity_log:).call.rows
    candidates(rows, activity_log).first(MAX_CRAWLS_PER_RUN).select { |row| enqueue_crawl(season, row) }.map(&:fin_event_id)
  end

  private

  def enqueue_crawl(season, row)
    SeasonBoard::Scheduler.crawl!(season_id: season.id, fin_event_id: row.fin_event_id, url: row.url, origin: :auto)
  rescue StandardError => e
    Rails.logger.error("[SeasonRecheckJob] enqueue failed for FIN #{row.fin_event_id}: #{e.class}: #{e.message}")
    false
  end

  def candidates(rows, activity_log)
    today = Date.current
    rechecks = rows.select { |row| recheck?(row, today) }.sort_by { |row| -row.last_date.jd }
    retries = (rows.select { |row| retry_failed?(row, activity_log) } - rechecks).sort_by { |row| retry_order(row) }
    (rechecks + retries).reject { |row| row.busy? || recently_crawled?(row, activity_log) }.uniq(&:fin_event_id)
  end

  # Soonest meeting first, undated rows last
  def retry_order(row)
    row.last_date ? row.last_date.jd : Float::INFINITY
  end

  def recheck?(row, today)
    return false if row.fin_event_id.blank? || row.url.blank? || row.last_date.nil?

    (row.state == :structure_committed && row.action?(:check_results)) ||
      (row.state == :link_not_crawled && row.last_date < today && !row.flag?(:possible_unlinked_meeting))
  end

  # Not crawled yet, whatever the date, with a failed last crawl attempt
  def retry_failed?(row, activity_log)
    return false if row.fin_event_id.blank? || row.url.blank? || row.state != :link_not_crawled
    return false if row.flag?(:possible_unlinked_meeting)

    activity_log.entry(row.fin_event_id, :crawl)&.failed? || false
  end

  def recently_crawled?(row, activity_log)
    last = activity_log.last_attempt_at(row.fin_event_id, :crawl)
    last.present? && last > MIN_RECRAWL_INTERVAL.ago
  end
end
