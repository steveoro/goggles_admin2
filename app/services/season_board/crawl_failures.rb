# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::CrawlFailures
  #
  # Consecutive failed crawls of a FIN id (0.10.102), read from the ops event log written by MeetingCrawlJob: the
  # 'board.crawl_failed' events since the last 'board.crawl_finished' one, whatever their origin (a refusal because
  # the automation was paused is not an attempt and doesn't count).
  #
  # It caps the unattended crawls of the rows whose link is adopted from the FIN 'Eventi' calendar
  # (SeasonBoard::CalendarIndex): after MAX_ADOPTED_FAILURES consecutive failures only the operator's Crawl button (or
  # the link published later on the 'Riepilogo Eventi' page) crawls them again; a successful crawl starts over.
  # Fails closed: an unreadable ops DB counts as exhausted.
  #
  class CrawlFailures
    KINDS = %w[board.crawl_finished board.crawl_failed].freeze
    FAILED_KIND = 'board.crawl_failed'

    # Unattended crawls of an adopted row stop after this many consecutive failures.
    MAX_ADOPTED_FAILURES = 3
    # Newest events read per FIN id (paused refusals are skipped, so a few more than the cap).
    SCAN_LIMIT = 50

    # Number of consecutive failed crawls of the FIN id (Integer), or nil when the ops DB can't be read.
    def self.consecutive(fin_event_id)
      Ops.safely(nil) do
        next nil unless Ops.available?

        failures = 0
        Ops::Event.where(kind: KINDS).for_subject('fin_event', fin_event_id).recent.limit(SCAN_LIMIT).each do |event|
          break unless event.kind == FAILED_KIND

          failures += 1 unless paused_refusal?(event)
        end
        failures
      end
    end

    # True when an adopted row must no longer be crawled unattended (also when the count can't be read).
    def self.adopted_exhausted?(fin_event_id)
      count = consecutive(fin_event_id)
      count.nil? || count >= MAX_ADOPTED_FAILURES
    end

    # A crawl refused at start because the automation master switch was off (any locale of the message).
    def self.paused_refusal?(event)
      message = event.data.is_a?(Hash) ? event.data['message'].to_s : ''
      I18n.available_locales.any? { |locale| message == I18n.t('pipeline_automation.reasons.automation_paused', locale:) }
    end
  end
end
