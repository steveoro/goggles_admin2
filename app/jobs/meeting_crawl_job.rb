# frozen_string_literal: true

#
# = MeetingCrawlJob
#
# Crawls the FIN results page of a single meeting (layout 2, direct-URL mode of the Node crawler),
# waits for the crawl to end and checks/tidies its output (see SeasonBoard::CrawlOutput),
# tracking the attempt in SeasonBoard::ActivityLog (kind :crawl) and pinging the Season board.
#
# Enqueued only through SeasonBoard::Scheduler.crawl! on the 'background' queue (one thread,
# so crawls & extractions run strictly one at a time and never delay the hourly watcher).
#
# The URL is never trusted as given: it must match the row of the current watcher snapshot
# having the same FIN event id (the snapshot URL is the one crawled).
#
# Never raises: any error closes the activity as failed (no retries).
#
# Phase 10: an automatic crawl (+origin+ 'auto', passed by SeasonBoard::Scheduler; for a job queued without it, the
# origin of its ActivityLog entry) is refused at start while the automation master switch is off or unreadable
# (DataFix::Automation fails closed; an unreadable origin counts as automatic); every run ends by enqueuing a
# PipelinePlannerJob pass (when the switch is on), which prepares the crawled source.
#
# The sleeper/clock/factories are class attributes so that specs can run instantly.
#
class MeetingCrawlJob < ApplicationJob
  queue_as :background

  # Hard timeout for a single crawl (the FIN server is slow & throttles: large championships can take that long).
  CRAWL_TIMEOUT = 30.minutes
  # Max wait for another crawl (e.g. a manual one started from the Sources page) to end before giving up.
  IDLE_WAIT_TIMEOUT = Crawler::RunWatcher::IDLE_WAIT_TIMEOUT
  # A non-idle crawler status not updated for this long is considered stale (a dead run).
  STALE_STATUS_AFTER = Crawler::RunWatcher::STALE_STATUS_AFTER
  POLL_INTERVAL = Crawler::RunWatcher::POLL_INTERVAL
  # Consecutive failed status polls tolerated during a crawl.
  MAX_UNREACHABLE_POLLS = Crawler::RunWatcher::MAX_UNREACHABLE_POLLS
  # Pause after each crawl, to be gentle with the FIN server.
  PAUSE_AFTER_CRAWL = 20.seconds

  # Shared with ManifestExtractJob and SourceCrawlJob (also when several job supervisors are running); above the
  # worst-case run (crawler launch + IDLE_WAIT_TIMEOUT + CRAWL_TIMEOUT + PAUSE_AFTER_CRAWL):
  limits_concurrency key: 'season_board', group: 'SeasonBoardBackground', to: 1, duration: 1.hour

  class_attribute :sleeper, default: ->(seconds) { sleep(seconds) }
  class_attribute :clock, default: -> { Time.current }
  class_attribute :crawler_client_factory, default: -> { CrawlerClient.new }
  class_attribute :launcher_factory, default: -> { CrawlerLauncher.new }
  # Base 'crawler/data' folder (nil: SeasonBoard::DiskIndex.default_data_dir).
  class_attribute :data_dir, default: nil

  # Internal: aborts the crawl with a failure message (also raised by Crawler::RunWatcher).
  Failure = Crawler::RunWatcher::Failure

  # - origin: 'auto' | 'manual' (SeasonBoard::Scheduler); nil for a job queued before phase 10 (read from the log).
  def perform(season_id:, fin_event_id:, url:, origin: nil)
    @season_id = season_id
    @fin_event_id = fin_event_id.to_s
    @finished = false
    @pulled = false
    activity_log.start!(@fin_event_id, kind: :crawl, url:)
    finish!(*crawl(season_id, url, origin))
  rescue Failure => e
    finish!(:failed, e.message)
  rescue StandardError => e
    Rails.logger.error("[MeetingCrawlJob] FIN #{@fin_event_id}: #{e.class}: #{e.message}")
    Rails.logger.debug { e.backtrace&.first(10)&.join("\n") }
    finish!(:failed, "error: #{e.class}: #{e.message}".truncate(200))
  ensure
    finish!(:failed, 'interrupted') unless @finished
    notify_board
    sleeper.call(PAUSE_AFTER_CRAWL) if @pulled
  end

  private

  # True for an automatic crawl while the automation master switch is off (or unreadable: fail closed).
  def automatic_paused?(origin)
    automatic = origin.present? ? origin.to_s == 'auto' : logged_as_automatic?
    automatic && !DataFix::Automation.enabled?
  end

  # Origin of the activity entry (kept from the queued one); an unreadable log counts as automatic.
  def logged_as_automatic?
    activity_log.entry(@fin_event_id, :crawl)&.origin == :auto
  rescue StandardError => e
    Rails.logger.warn("[MeetingCrawlJob] FIN #{@fin_event_id}: activity log unreadable (#{e.class}), origin counted as automatic")
    true
  end

  # Drops the stored board summary (SeasonBoard::Snapshot), pings the open pages and enqueues the next pipeline planner
  # pass (phase 10; never raises).
  def notify_board
    SeasonBoard::Snapshot.invalidate!(@season_id)
    SeasonBoard::Notifier.ping
    PipelinePlannerJob.enqueue_after(self.class.name)
  end

  # Returns [status, message].
  def crawl(season_id, url, origin)
    raise Failure, I18n.t('pipeline_automation.reasons.automation_paused') if automatic_paused?(origin)

    season = GogglesDb::Season.find_by(id: season_id)
    raise Failure, "unknown season #{season_id}" unless season

    target_url = snapshot_url_for(url)
    ensure_crawler!
    wait_until_idle!
    since, baseline = start_crawl!(season.id, target_url)
    final = wait_for_crawl_end!(since, baseline)
    raise Failure, "crawler error: #{final.detail}".truncate(200) if final.error?

    outcome = SeasonBoard::CrawlOutput.new(season_id: season.id, fin_event_id: @fin_event_id, since:,
                                           data_dir: data_dir || SeasonBoard::DiskIndex.default_data_dir).call
    [outcome.status, outcome.message]
  end

  # Returns the results URL stored on the current watcher snapshot for the FIN id.
  def snapshot_url_for(url)
    row = Array(FedernuotoWatch::StateStore.new.read['rows']).find { |r| FINEventId.parse(r['url']) == @fin_event_id }
    raise Failure, 'FIN id no longer on the watcher snapshot' unless row
    raise Failure, 'snapshot URL is not a FIN URL' unless FINEventId.fin_url?(row['url'])

    Rails.logger.warn("[MeetingCrawlJob] FIN #{@fin_event_id}: URL changed, using the snapshot one") if url.to_s != row['url']
    row['url']
  end

  def ensure_crawler!
    watcher.ensure_crawler!
  end

  # Waits for any other crawl to end (a stale status counts as idle).
  def wait_until_idle!
    watcher.wait_until_idle!
  end

  # Returns [crawl start time (whole seconds), status Hash before the call].
  def start_crawl!(season_id, url)
    baseline = client.status
    since = clock.call.change(usec: 0)
    result = client.pull_meeting(season_id:, url:)
    raise Failure, "crawler API call failed: #{result.error}".truncate(200) unless result.ok?

    @pulled = true
    [since, baseline]
  end

  # Polls the crawler status until the run started at +since+ ends; returns its final Status.
  def wait_for_crawl_end!(since, baseline)
    watcher.wait_for_crawl_end!(since, baseline, timeout: CRAWL_TIMEOUT)
  end

  # (Crawler::RunWatcher, phase 15: shared with SourceCrawlJob)
  def watcher
    @watcher ||= Crawler::RunWatcher.new(client:, launcher_factory:, sleeper:, clock:)
  end

  def finish!(status, message)
    return if @finished || @fin_event_id.blank?

    @finished = true
    record_finish_event(status, message)
    activity_log.finish!(@fin_event_id, kind: :crawl, status:, message:)
  rescue StandardError => e
    Rails.logger.error("[MeetingCrawlJob] cannot update the activity log: #{e.class}: #{e.message}")
  end

  # Appends 'board.crawl_finished' / 'board.crawl_failed' to the ops event log (never raises).
  def record_finish_event(status, message)
    Ops.safely do
      done = status.to_s == 'done'
      Ops.record_event!(
        kind: done ? 'board.crawl_finished' : 'board.crawl_failed', level: done ? 'success' : 'error', actor: 'job',
        season_id: Integer(@season_id, exception: false), subject_type: 'fin_event', subject_key: @fin_event_id,
        data: { 'status' => status.to_s, 'message' => message }, link_path: Rails.application.routes.url_helpers.season_board_path
      )
    end
  end

  def activity_log
    @activity_log ||= SeasonBoard::ActivityLog.new
  end

  def client
    @client ||= crawler_client_factory.call
  end
end
