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
# The full board build is stored as the board summary (SeasonBoard::Snapshot.build!).
# Nothing is queued while the automation master switch is off (DataFix::Automation, phase 10).
# 0.10.102: a row whose link is adopted from the FIN 'Eventi' calendar (flag :link_adopted) is skipped once its crawls
# failed SeasonBoard::CrawlFailures::MAX_ADOPTED_FAILURES times in a row (or the count can't be read): then only the
# operator's Crawl button, or the link published later on the 'Riepilogo Eventi' page, crawls it again.
# 0.10.103: first asks for the daily crawl of the FIN 'Eventi' calendar (SeasonBoard::CalendarPlanner#call_daily, switch
# 'auto_calendar': links appear there with no change on the watched page, and an adoption needs a calendar file at most
# 14 days old); a row FIN removed from the page (flag :removed_from_fin) is never crawled; at most what
# SeasonBoard::CrawlBudget leaves (15 automatic crawls queued or running at any time) is queued.
#
class SeasonRecheckJob < ApplicationJob
  queue_as :background

  MAX_CRAWLS_PER_RUN = 15
  MIN_RECRAWL_INTERVAL = 20.hours

  # - season_id: board season (default: SeasonBoard::Builder.latest_season)
  # Returns the Array of FIN ids enqueued.
  def perform(season_id: nil)
    return [] unless DataFix::Automation.enabled?

    season = season_id ? GogglesDb::Season.find_by(id: season_id) : SeasonBoard::Builder.latest_season
    return [] unless season

    activity_log = SeasonBoard::ActivityLog.new
    queue_daily_calendar(season, activity_log)
    rows = SeasonBoard::Snapshot.build!(season, builder: SeasonBoard::Builder.new(season:, activity_log:)).rows
    limit = [MAX_CRAWLS_PER_RUN, SeasonBoard::CrawlBudget.remaining(activity_log.reload!)].min
    candidates(rows, activity_log).first(limit).select { |row| enqueue_crawl(season, row) }.map(&:fin_event_id)
  end

  private

  # The daily 'Eventi' calendar crawl (never raises).
  def queue_daily_calendar(season, activity_log)
    outcome = SeasonBoard::CalendarPlanner.new(season:, activity_log:).call_daily
    Rails.logger.info("[SeasonRecheckJob] daily FIN 'Eventi' calendar crawl: #{outcome}")
  rescue StandardError => e
    Rails.logger.error("[SeasonRecheckJob] daily calendar crawl not queued: #{e.class}: #{e.message}")
  end

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
    (rechecks + retries).reject { |row| skipped?(row, activity_log) }.uniq(&:fin_event_id)
  end

  def skipped?(row, activity_log)
    row.busy? || row.flag?(:removed_from_fin) || recently_crawled?(row, activity_log) || adopted_given_up?(row)
  end

  # An adopted row whose last crawls kept failing (SeasonBoard::CrawlFailures, fail closed).
  def adopted_given_up?(row)
    row.flag?(:link_adopted) && SeasonBoard::CrawlFailures.adopted_exhausted?(row.fin_event_id)
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
