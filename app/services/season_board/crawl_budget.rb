# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::CrawlBudget
  #
  # The ceiling on the OUTSTANDING automatic meeting crawls (0.10.103): at any time at most MAX_OUTSTANDING automatic
  # crawls are queued or running (ActivityLog entries of kind :crawl, origin :auto, busy; the Sources work under a
  # 'src:' key is not counted). SeasonBoard::CrawlPlanner (after a FIN change) and SeasonRecheckJob (daily) queue at
  # most #remaining more, so the FIN server never gets a burst and the automatic queue stays short (an operator's crawl
  # goes first anyway: SeasonBoard::Scheduler::AUTO_PRIORITY). Unreadable activity log: 0 (fail closed).
  #
  module CrawlBudget
    MAX_OUTSTANDING = 15

    module_function

    # Automatic meeting crawls queued or running (Integer).
    def outstanding(activity_log, now: Time.current)
      activity_log.all_entries.count { |entry| entry.kind == :crawl && entry.origin == :auto && !entry.source? && entry.busy?(now) }
    end

    # How many more automatic crawls may be queued now (0..MAX_OUTSTANDING).
    def remaining(activity_log, now: Time.current)
      [MAX_OUTSTANDING - outstanding(activity_log, now:), 0].max
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::CrawlBudget] activity log unreadable, no automatic crawl: #{e.class}: #{e.message}")
      0
    end
  end
end
