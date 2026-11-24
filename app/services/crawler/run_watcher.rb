# frozen_string_literal: true

module Crawler
  #
  # = Crawler::RunWatcher
  #
  # Follows one run of the local crawler server (Node, see CrawlerClient) for a background job (extracted from
  # MeetingCrawlJob in phase 15; MeetingCrawlJob and SourceCrawlJob use it):
  # - #ensure_crawler!: starts the server when needed (CrawlerLauncher);
  # - #wait_until_idle!: waits for any other crawl to end before starting a new one (a stale status counts as idle);
  # - #wait_for_crawl_end!: polls the status until the run started at +since+ ends (#crawl_end?).
  #
  # The crawler status is read from the server (CrawlerClient#status) only: every page reads the status file instead.
  # Every failure raises Crawler::RunWatcher::Failure with a short operator message.
  #
  # The sleeper and the clock are injected so that the job specs run instantly.
  #
  class RunWatcher
    # Aborts the run with a failure message.
    class Failure < StandardError; end

    # Max wait for another crawl (e.g. a board crawl started elsewhere) to end before giving up.
    IDLE_WAIT_TIMEOUT = 5.minutes
    # A non-idle crawler status not updated for this long is considered stale (a dead run).
    STALE_STATUS_AFTER = 30.minutes
    POLL_INTERVAL = 10.seconds
    # Consecutive failed status polls tolerated during a crawl.
    MAX_UNREACHABLE_POLLS = 6

    attr_reader :client

    # == Params:
    # - client: a CrawlerClient (or any object answering #status);
    # - launcher_factory: callable returning a CrawlerLauncher (called by #ensure_crawler! only);
    # - sleeper: callable taking the seconds to sleep; clock: callable returning the current time.
    def initialize(client:, launcher_factory: -> { CrawlerLauncher.new }, sleeper: ->(seconds) { sleep(seconds) },
                   clock: -> { Time.current })
      @client = client
      @launcher_factory = launcher_factory
      @sleeper = sleeper
      @clock = clock
    end

    # Starts the crawler server unless it answers already.
    def ensure_crawler!
      return unless @launcher_factory.call.ensure_running! == :failed

      raise Failure, "crawler server cannot be started (see #{CrawlerLauncher::LOG_PATH.relative_path_from(Rails.root)})"
    end

    # Waits for any other crawl to end (a stale status counts as idle).
    # - on_wait: optional callable, called before each sleep (e.g. a heartbeat).
    def wait_until_idle!(timeout: IDLE_WAIT_TIMEOUT, on_wait: nil)
      deadline = @clock.call + timeout
      loop do
        status = CrawlerClient::Status.from(client.status)
        raise Failure, 'crawler server unreachable' unless status
        return unless status.busy?(now: @clock.call, stale_after: STALE_STATUS_AFTER)
        raise Failure, "crawler busy with another crawl (#{status.status})" if @clock.call >= deadline

        on_wait&.call
        @sleeper.call(POLL_INTERVAL)
      end
    end

    # Polls the crawler status until the run started at +since+ ends; returns its final CrawlerClient::Status.
    # (A status counts only once it differs from the +baseline+ read before the call and is not older than +since+.)
    # - timeout: hard limit of the run; on_poll: optional callable, called after each poll (e.g. a heartbeat).
    def wait_for_crawl_end!(since, baseline, timeout:, on_poll: nil)
      deadline = since + timeout
      unreachable = 0
      loop do
        raise Failure, "timeout after #{timeout.in_minutes.round} min" if @clock.call >= deadline

        @sleeper.call(POLL_INTERVAL)
        hash = client.status
        on_poll&.call
        unreachable = hash ? 0 : unreachable + 1
        raise Failure, 'crawler server stopped responding' if unreachable >= MAX_UNREACHABLE_POLLS

        status = CrawlerClient::Status.from(hash)
        return status if crawl_end?(status, hash, baseline, since)
      end
    end

    # True when +status+ (parsed from +hash+) is the end of the run started at +since+.
    def crawl_end?(status, hash, baseline, since)
      return false unless status&.idle? && hash != baseline

      status.timestamp.present? && status.timestamp >= since
    end
  end
end
