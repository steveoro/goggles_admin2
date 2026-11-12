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
# The sleeper/clock/factories are class attributes so that specs can run instantly.
#
class MeetingCrawlJob < ApplicationJob
  queue_as :background

  # Hard timeout for a single crawl (the FIN server is slow & throttles: large championships can take that long).
  CRAWL_TIMEOUT = 30.minutes
  # Max wait for another crawl (e.g. started from the Pull page) to end before giving up.
  IDLE_WAIT_TIMEOUT = 5.minutes
  # A non-idle crawler status not updated for this long is considered stale (a dead run).
  STALE_STATUS_AFTER = 30.minutes
  POLL_INTERVAL = 10.seconds
  # Consecutive failed status polls tolerated during a crawl.
  MAX_UNREACHABLE_POLLS = 6
  # Pause after each crawl, to be gentle with the FIN server.
  PAUSE_AFTER_CRAWL = 20.seconds

  # Shared with ManifestExtractJob (also when several job supervisors are running); above the worst-case
  # run (crawler launch + IDLE_WAIT_TIMEOUT + CRAWL_TIMEOUT + PAUSE_AFTER_CRAWL):
  limits_concurrency key: 'season_board', group: 'SeasonBoardBackground', to: 1, duration: 1.hour

  class_attribute :sleeper, default: ->(seconds) { sleep(seconds) }
  class_attribute :clock, default: -> { Time.current }
  class_attribute :crawler_client_factory, default: -> { CrawlerClient.new }
  class_attribute :launcher_factory, default: -> { CrawlerLauncher.new }
  # Base 'crawler/data' folder (nil: SeasonBoard::DiskIndex.default_data_dir).
  class_attribute :data_dir, default: nil

  # Internal: aborts the crawl with a failure message.
  class Failure < StandardError; end

  def perform(season_id:, fin_event_id:, url:)
    @fin_event_id = fin_event_id.to_s
    @finished = false
    @pulled = false
    activity_log.start!(@fin_event_id, kind: :crawl, url:)
    finish!(*crawl(season_id, url))
  rescue Failure => e
    finish!(:failed, e.message)
  rescue StandardError => e
    Rails.logger.error("[MeetingCrawlJob] FIN #{@fin_event_id}: #{e.class}: #{e.message}")
    Rails.logger.debug { e.backtrace&.first(10)&.join("\n") }
    finish!(:failed, "error: #{e.class}: #{e.message}".truncate(200))
  ensure
    finish!(:failed, 'interrupted') unless @finished
    SeasonBoard::Notifier.ping
    sleeper.call(PAUSE_AFTER_CRAWL) if @pulled
  end

  private

  # Returns [status, message].
  def crawl(season_id, url)
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
    return unless launcher_factory.call.ensure_running! == :failed

    raise Failure, "crawler server cannot be started (see #{CrawlerLauncher::LOG_PATH.relative_path_from(Rails.root)})"
  end

  # Waits for any other crawl to end (a stale status counts as idle).
  def wait_until_idle!
    deadline = clock.call + IDLE_WAIT_TIMEOUT
    loop do
      status = CrawlerClient::Status.from(client.status)
      raise Failure, 'crawler server unreachable' unless status
      return unless status.busy?(now: clock.call, stale_after: STALE_STATUS_AFTER)
      raise Failure, "crawler busy with another crawl (#{status.status})" if clock.call >= deadline

      sleeper.call(POLL_INTERVAL)
    end
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
  # (A status counts only once it differs from the +baseline+ read before the call and is not older than +since+.)
  def wait_for_crawl_end!(since, baseline)
    deadline = since + CRAWL_TIMEOUT
    unreachable = 0
    loop do
      raise Failure, "timeout after #{CRAWL_TIMEOUT.in_minutes.round} min" if clock.call >= deadline

      sleeper.call(POLL_INTERVAL)
      hash = client.status
      unreachable = hash ? 0 : unreachable + 1
      raise Failure, 'crawler server stopped responding' if unreachable >= MAX_UNREACHABLE_POLLS

      status = CrawlerClient::Status.from(hash)
      return status if crawl_end?(status, hash, baseline, since)
    end
  end

  def crawl_end?(status, hash, baseline, since)
    return false unless status&.idle? && hash != baseline

    status.timestamp.present? && status.timestamp >= since
  end

  def finish!(status, message)
    return if @finished || @fin_event_id.blank?

    @finished = true
    activity_log.finish!(@fin_event_id, kind: :crawl, status:, message:)
  rescue StandardError => e
    Rails.logger.error("[MeetingCrawlJob] cannot update the activity log: #{e.class}: #{e.message}")
  end

  def activity_log
    @activity_log ||= SeasonBoard::ActivityLog.new
  end

  def client
    @client ||= crawler_client_factory.call
  end
end
