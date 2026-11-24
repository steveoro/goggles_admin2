# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::CrawlPlanner
  #
  # Turns a FIN calendar change detected by the watcher (FedernuotoWatch::Checker diff, stored
  # as the pending 'change') into automatic crawls: every changed row ('added', 'with_results',
  # 'updated') having a FIN id whose board state is :link_not_crawled gets a
  # Scheduler.crawl!(origin: :auto), unless flagged :possible_unlinked_meeting (a local calendar not
  # linked yet falls within its dates: left to the operator, as in SeasonRecheckJob).
  #
  # The pending change is cumulative until acknowledged (the same rows show up at every hourly
  # check), so a row is skipped when the ActivityLog already holds a crawl attempt for the
  # same URL (whatever its outcome); busy rows are skipped by the Scheduler itself.
  #
  # The full board build is stored as the board summary (SeasonBoard::Snapshot.build!), once per instance.
  #
  # Phase 10:
  # - nothing is queued while the automation master switch is off (DataFix::Automation, or ADMIN2_AUTOMATION=0);
  # - #plan_recrawl re-crawls the :structure_committed rows listed under the change's 'with_results' key (FIN now
  #   marks them as having results), at most once per SeasonRecheckJob::MIN_RECRAWL_INTERVAL (20 h) per row, busy
  #   rows skipped. The same-URL dedupe of #call does not apply there (the URL is unchanged by design).
  #
  class CrawlPlanner
    CHANGE_KEYS = %w[added with_results updated].freeze
    RECRAWL_KEY = 'with_results'

    # == Params
    # - season: target GogglesDb::Season (the board season)
    # - activity_log: SeasonBoard::ActivityLog
    # - builder: object responding to #call with a Builder::Result (default: a Builder for the season)
    def initialize(season: Builder.latest_season, activity_log: nil, builder: nil)
      @season = season
      @activity_log = activity_log || ActivityLog.new
      @builder = builder
    end

    # Returns the Array of FIN ids enqueued for crawling.
    def call(change)
      return [] if @season.nil? || !change.is_a?(Hash) || !DataFix::Automation.enabled?

      changed_ids = changed_fin_ids(change, CHANGE_KEYS)
      return [] if changed_ids.empty?

      board_rows.select { |row| changed_ids.include?(row.fin_event_id) }.filter_map { |row| plan(row) }.uniq
    end

    # Re-crawls the :structure_committed rows of the change's 'with_results' list (rate-limited). Returns the Array of
    # FIN ids enqueued.
    def plan_recrawl(change)
      return [] if @season.nil? || !change.is_a?(Hash) || !DataFix::Automation.enabled?

      ids = changed_fin_ids(change, [RECRAWL_KEY])
      return [] if ids.empty?

      board_rows.select { |row| ids.include?(row.fin_event_id) }.filter_map { |row| recrawl(row) }.uniq
    end

    private

    def changed_fin_ids(change, keys)
      keys.flat_map { |key| Array(change[key]) }.filter_map { |row| FINEventId.parse(row['url']) if row.is_a?(Hash) }.uniq
    end

    # Board rows (one build per planner instance).
    def board_rows
      @board_rows ||= Snapshot.build!(@season, builder:).rows
    end

    def recrawl(row)
      return unless row.state == :structure_committed && row.url.present? && !row.busy?

      last = @activity_log.last_attempt_at(row.fin_event_id, :crawl)
      return if last.present? && last > SeasonRecheckJob::MIN_RECRAWL_INTERVAL.ago

      row.fin_event_id if Scheduler.crawl!(season_id: @season.id, fin_event_id: row.fin_event_id, url: row.url, origin: :auto)
    rescue StandardError => e
      Rails.logger.error("[SeasonBoard::CrawlPlanner] re-crawl enqueue failed for FIN #{row.fin_event_id}: #{e.class}: #{e.message}")
      nil
    end

    def builder
      @builder ||= Builder.new(season: @season, activity_log: @activity_log)
    end

    def plan(row)
      return unless row.state == :link_not_crawled && row.url.present?
      return if row.flag?(:possible_unlinked_meeting)
      return if @activity_log.entry(row.fin_event_id, :crawl)&.url == row.url

      row.fin_event_id if Scheduler.crawl!(season_id: @season.id, fin_event_id: row.fin_event_id, url: row.url, origin: :auto)
    rescue StandardError => e
      # (the Scheduler has already closed the log entry as failed: go on with the other rows)
      Rails.logger.error("[SeasonBoard::CrawlPlanner] enqueue failed for FIN #{row.fin_event_id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
