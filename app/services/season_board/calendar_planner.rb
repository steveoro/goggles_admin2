# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::CalendarPlanner
  #
  # Queues the automatic crawl of the season's FIN 'Eventi' calendar (0.10.103), through
  # SeasonBoard::Scheduler.calendar_crawl!(origin: :auto) (a SourceCrawlJob on the 'background' worker, one crawl at a
  # time with the board crawls). The 'Eventi' calendar lends their link to the board rows that have none on the watched
  # 'Riepilogo Eventi' page (SeasonBoard::CalendarIndex); the next planner pass then crawls the changed meetings that
  # got one (SeasonBoard::CrawlPlanner). Only the calendar itself is crawled: processing it (the 'calendar_results'
  # kind, every meeting of the CSV) stays an operator click.
  #
  # #call(change), after a FIN change (PipelinePlannerJob, FedernuotoWatchJob through SeasonBoard::ChangeChain): only
  # while a change is pending, no calendar crawl has finished (done) since the change was detected ('detected_at'), none
  # is queued or running, and the last automatic attempt is older than MIN_INTERVAL (6 hours).
  #
  # #call_daily (SeasonRecheckJob): one crawl a day, since links appear on 'Eventi' with no change on the watched page
  # and an adoption expires 14 days after its calendar file (CalendarIndex::MAX_FILE_AGE): skipped when a calendar crawl
  # finished in the last MIN_INTERVAL, or the last daily attempt is less than DAILY_INTERVAL old.
  #
  # Both obey the 'auto_calendar' switch (and the master one: DataFix::Automation, fail closed). The attempt times are
  # ops settings (LAST_AUTO_KEY, LAST_DAILY_KEY), written BEFORE the enqueue: an attempt time that cannot be read or
  # written counts as recent (nothing is queued), so a broken ops DB never turns into a burst on the FIN server. At most
  # 4 change-driven crawls plus 1 daily one per day. Returns :queued or the Symbol of the reason it did not.
  #
  class CalendarPlanner
    MIN_INTERVAL = 6.hours
    DAILY_INTERVAL = 20.hours
    LAST_AUTO_KEY = 'season_board.calendar_crawl.last_auto_at'
    LAST_DAILY_KEY = 'season_board.calendar_crawl.last_daily_at'

    # True when the season's default 'Eventi' calendar crawl finished done at or after +time+ (its ActivityLog entry, or
    # the newest 'Eventi' calendar file of the season written since).
    def self.finished_since?(season, time, activity_log: nil, data_dir: nil)
      entry = (activity_log || ActivityLog.new).entry(Sources::CrawlRequest.eventi_calendar(season).key, :crawl)
      return true if entry&.done? && entry.finished_at && entry.finished_at >= time

      newest = CalendarIndex.candidate_paths(season.id, data_dir:).first
      newest.present? && File.mtime(newest) >= time
    rescue SystemCallError
      false
    end

    # True when that crawl ended (done or failed) at or after +time+, or a calendar file was written since.
    def self.ended_since?(season, time, activity_log: nil, data_dir: nil)
      log = activity_log || ActivityLog.new
      entry = log.entry(Sources::CrawlRequest.eventi_calendar(season).key, :crawl)
      return true if (entry&.done? || entry&.failed?) && entry.finished_at && entry.finished_at >= time

      finished_since?(season, time, activity_log: log, data_dir:)
    end

    # == Params
    # - season: the board season; activity_log: SeasonBoard::ActivityLog;
    # - data_dir: base 'crawler/data' folder (the calendar files); now: reference time.
    def initialize(season:, activity_log: nil, data_dir: nil, now: Time.current)
      @season = season
      @activity_log = activity_log || ActivityLog.new
      @data_dir = data_dir
      @now = now
    end

    # The crawl after the pending +change+ (Hash, or nil). Returns :queued or the skip reason.
    def call(change)
      reason = common_refusal
      return reason if reason

      detected_at = change.is_a?(Hash) ? parse_time(change['detected_at']) : nil
      return :no_change unless detected_at
      return :crawled_since_change if self.class.finished_since?(@season, detected_at, activity_log: @activity_log, data_dir: @data_dir)
      return :recent_attempt if recent?(LAST_AUTO_KEY, MIN_INTERVAL)

      enqueue(LAST_AUTO_KEY)
    end

    # The daily crawl. Returns :queued or the skip reason.
    def call_daily
      reason = common_refusal
      return reason if reason
      return :crawled_recently if self.class.finished_since?(@season, @now - MIN_INTERVAL, activity_log: @activity_log, data_dir: @data_dir)
      return :recent_attempt if recent?(LAST_DAILY_KEY, DAILY_INTERVAL)

      enqueue(LAST_DAILY_KEY)
    end

    private

    def common_refusal
      return :no_season unless @season
      return :switch_off unless DataFix::Automation.enabled?(:auto_calendar)

      :busy if @activity_log.busy?(Sources::CrawlRequest.eventi_calendar(@season).key, kind: :crawl)
    end

    # True when the attempt stored under +key+ is younger than +interval+, or cannot be read (fail closed).
    def recent?(key, interval)
      stored = Ops.safely(:unreadable) { Ops.available? ? Ops::Setting.fetch(key) : :unreadable }
      return true if stored == :unreadable
      return false if stored.blank?

      time = parse_time(stored)
      time.nil? || time > @now - interval
    end

    def enqueue(key)
      recorded = Ops.safely(false) do
        Ops::Setting.store!(key, @now.iso8601)
        true
      end
      return :unrecorded unless recorded

      Scheduler.calendar_crawl!(season: @season, origin: :auto) ? :queued : :refused
    rescue StandardError => e
      Rails.logger.error("[SeasonBoard::CalendarPlanner] calendar crawl enqueue failed: #{e.class}: #{e.message}")
      :failed
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
