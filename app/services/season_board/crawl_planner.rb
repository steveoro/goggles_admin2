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
  class CrawlPlanner
    CHANGE_KEYS = %w[added with_results updated].freeze

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
      return [] if @season.nil? || !change.is_a?(Hash)

      changed_ids = CHANGE_KEYS.flat_map { |key| Array(change[key]) }.filter_map { |row| FINEventId.parse(row['url']) }.uniq
      return [] if changed_ids.empty?

      board_rows = builder.call.rows.select { |row| changed_ids.include?(row.fin_event_id) }
      board_rows.filter_map { |row| plan(row) }.uniq
    end

    private

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
