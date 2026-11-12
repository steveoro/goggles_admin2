# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::Scheduler
  #
  # Single entry point for enqueuing the Season board background work (manual buttons,
  # CrawlPlanner & SeasonRecheckJob), so that every request is recorded as 'queued' in the
  # ActivityLog before the job is enqueued and a second request for the same FIN id is
  # refused while the first one is still queued or running.
  #
  # Both methods return false (doing nothing) when the FIN id is already busy with the same
  # kind of work, true once the job has been enqueued.
  # If the enqueue itself fails the log entry is closed as failed and the error is re-raised.
  #
  class Scheduler
    # Enqueues a MeetingCrawlJob for the FIN results URL.
    # - origin: :manual (board button) or :auto (watcher / daily re-check)
    def self.crawl!(season_id:, fin_event_id:, url:, origin:) # rubocop:disable Naming/PredicateMethod
      log = ActivityLog.new
      return false if log.busy?(fin_event_id, kind: :crawl)

      record_and_enqueue(log, fin_event_id, kind: :crawl, origin:, url:) do
        MeetingCrawlJob.perform_later(season_id:, fin_event_id: fin_event_id.to_s, url:)
      end
      true
    end

    # Enqueues a ManifestExtractJob for the pending manifest PDF of the FIN id.
    # - engine: LLM engine name (nil for the default, see PdfManifests::ClientFactory)
    def self.extract!(season_id:, fin_event_id:, engine: nil) # rubocop:disable Naming/PredicateMethod
      log = ActivityLog.new
      return false if log.busy?(fin_event_id, kind: :extract)

      record_and_enqueue(log, fin_event_id, kind: :extract, origin: :manual) do
        ManifestExtractJob.perform_later(season_id:, fin_event_id: fin_event_id.to_s, engine:)
      end
      true
    end

    def self.record_and_enqueue(log, fin_event_id, kind:, origin:, url: nil)
      log.queue!(fin_event_id, kind:, origin:, url:)
      begin
        yield
      rescue StandardError => e
        log.finish!(fin_event_id, kind:, status: :failed, message: "enqueue failed: #{e.message}".truncate(200))
        raise
      end
      Notifier.ping
      nil
    end
    private_class_method :record_and_enqueue
  end
end
