# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::ChangeChain
  #
  # The automatic follow-up of the pending FIN change (0.10.103), shared by PipelinePlannerJob (every pass) and
  # FedernuotoWatchJob (on a detected change), so the two never diverge:
  #
  # 1. SeasonBoard::CalendarPlanner#call: the FIN 'Eventi' calendar crawl (switch 'auto_calendar'; at most once per
  #    6 hours while the change is pending, and not after one finished since the change was detected);
  # 2. SeasonBoard::CrawlPlanner#call: one MeetingCrawlJob per new or changed meeting with a link (its own, or adopted
  #    from the 'Eventi' calendar), at most 15 per pass;
  # 3. SeasonBoard::CrawlPlanner#plan_recrawl: the structure-committed meetings FIN now lists with results.
  #
  # Nothing is queued without a pending change, or while the automation master switch is off (DataFix::Automation,
  # ADMIN2_AUTOMATION=0). Only crawls are queued, through SeasonBoard::Scheduler: never a commit, a push or a write to
  # the local DB. Never raises (a failing step is logged and the next one still runs).
  #
  class ChangeChain
    # calendar: the CalendarPlanner outcome Symbol (or why nothing ran: :paused, :no_season, :no_change, :failed);
    # crawls / recrawls: the FIN ids queued.
    Outcome = Data.define(:calendar, :crawls, :recrawls) do
      def self.skipped(reason) = new(calendar: reason, crawls: [], recrawls: [])
      def queued? = calendar == :queued || crawls.any? || recrawls.any?
    end

    def initialize(season:, store: nil, activity_log: nil)
      @season = season
      @store = store || FedernuotoWatch::StateStore.new
      @activity_log = activity_log || ActivityLog.new
    end

    def call
      return Outcome.skipped(:no_season) unless @season
      return Outcome.skipped(:paused) unless DataFix::Automation.enabled?

      change = @store.pending_change
      return Outcome.skipped(:no_change) unless change.is_a?(Hash)

      calendar = step(:failed) { CalendarPlanner.new(season: @season, activity_log: @activity_log).call(change) }
      planner = CrawlPlanner.new(season: @season, activity_log: @activity_log)
      Outcome.new(calendar:, crawls: step([]) { planner.call(change) }, recrawls: step([]) { planner.plan_recrawl(change) })
    rescue StandardError => e
      Rails.logger.error("[SeasonBoard::ChangeChain] #{e.class}: #{e.message}")
      Outcome.skipped(:failed)
    end

    private

    def step(default)
      yield
    rescue StandardError => e
      Rails.logger.error("[SeasonBoard::ChangeChain] step failed: #{e.class}: #{e.message}")
      default
    end
  end
end
