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
  # 0.10.103 (only new or changed meetings are crawled, never a whole calendar):
  # - a change row is matched to its board row by key as well as by FIN id, so a row without a link on the watched
  #   page whose board row adopts one from the FIN 'Eventi' calendar (flag :link_adopted, SeasonBoard::CalendarIndex)
  #   is crawled like a linked one, unless its unattended crawls gave up (SeasonBoard::CrawlFailures.adopted_exhausted?,
  #   fail closed);
  # - a row FIN removed from the page (flag :removed_from_fin) is never crawled;
  # - at most MAX_CRAWLS_PER_PASS crawls per pass, and never more than SeasonBoard::CrawlBudget allows: at most 15
  #   automatic crawls queued or running at any time (the rest are logged and left for a next pass: the pending change
  #   is cumulative, PipelinePlannerJob runs every 15 minutes and after every crawl);
  # - #plan_recrawl takes every 'with_results' row (FIN published its results link) not crawled since its OWN detection
  #   (FedernuotoWatch::Parity.row_detected_at), in FedernuotoWatch::Parity::RECRAWL_STATES only (a source in review,
  #   committed locally or archived is never crawled again automatically: Parity hands it to the operator); after a
  #   failed attempt since the detection it waits SeasonRecheckJob::MIN_RECRAWL_INTERVAL (20 h). Same budget as #call.
  #
  class CrawlPlanner
    CHANGE_KEYS = %w[added with_results updated].freeze
    RECRAWL_KEY = 'with_results'
    MAX_CRAWLS_PER_PASS = 15

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
      return [] unless plannable?(change)

      rows = changed_board_rows(change)
      rows.empty? ? [] : enqueue_capped(rows.select { |row| candidate?(row) }.uniq(&:fin_event_id))
    end

    # Re-crawls the rows of the change's 'with_results' list that need it (see the class notes). Returns the Array of FIN
    # ids enqueued.
    def plan_recrawl(change)
      return [] unless plannable?(change)

      detections = with_results_detections(change)
      return [] if detections.empty?

      rows = board_rows.filter_map do |row|
        key = detection_key(row, detections)
        row if key && recrawl_candidate?(row, detections[key])
      end
      enqueue_capped(rows.uniq(&:fin_event_id))
    end

    private

    def plannable?(change)
      @season.present? && change.is_a?(Hash) && DataFix::Automation.enabled?
    end

    def changed_fin_ids(change, keys)
      keys.flat_map { |key| Array(change[key]) }.filter_map { |row| FINEventId.parse(row['url']) if row.is_a?(Hash) }.uniq
    end

    # The board rows of the change rows, matched by FIN id or by key (no board build without a change row).
    def changed_board_rows(change)
      ids = changed_fin_ids(change, CHANGE_KEYS)
      keys = changed_row_keys(change)
      return [] if ids.empty? && keys.empty?

      board_rows.select { |row| ids.include?(row.fin_event_id) || keys.include?(row.key) }
    end

    # { row key or FIN id => its detection Time (nil for a change stored without them) } of the 'with_results' rows.
    def with_results_detections(change)
      Array(change[RECRAWL_KEY]).grep(Hash).each_with_object({}) do |row, memo|
        detected = FedernuotoWatch::Parity.row_detected_at(change, RECRAWL_KEY, row['key'])
        memo[row['key']] = detected if row['key'].present?
        fin_id = FINEventId.parse(row['url'])
        memo[fin_id] = detected if fin_id
      end
    end

    def changed_row_keys(change)
      CHANGE_KEYS.flat_map { |key| Array(change[key]) }.filter_map { |row| row['key'].presence if row.is_a?(Hash) }.to_set
    end

    # Queues the candidates within the budget (a refused one does not count); logs the ones left for a next pass.
    def enqueue_capped(candidates)
      queued = []
      left = candidates.drop_while do |row|
        next false if @queued_count.to_i >= budget

        fin_id = plan(row)
        if fin_id
          queued << fin_id
          @queued_count = @queued_count.to_i + 1
        end
        true
      end
      log_left(left) if left.any?
      queued.uniq
    end

    # Crawls this planner may queue in all (MAX_CRAWLS_PER_PASS, and what SeasonBoard::CrawlBudget leaves; read once).
    def budget
      @budget ||= [MAX_CRAWLS_PER_PASS, CrawlBudget.remaining(@activity_log.reload!)].min
    end

    def log_left(rows)
      Rails.logger.info("[SeasonBoard::CrawlPlanner] crawl budget used (#{budget} in this pass, at most #{CrawlBudget::MAX_OUTSTANDING} " \
                        "automatic crawls outstanding), left for a next pass: #{rows.map(&:fin_event_id).join(', ')}")
    end

    # Board rows (one build per planner instance).
    def board_rows
      @board_rows ||= Snapshot.build!(@season, builder:).rows
    end

    def builder
      @builder ||= Builder.new(season: @season, activity_log: @activity_log)
    end

    # The key of the row in the detections (its key, else its FIN id), or nil.
    def detection_key(row, detections)
      [row.key, row.fin_event_id].find { |value| value.present? && detections.key?(value) }
    end

    # A row in RECRAWL_STATES, not busy nor removed, not crawled done since +detected+, and not attempted since then less
    # than MIN_RECRAWL_INTERVAL ago (a change stored without detection times: no attempt in the last 20 h, as before).
    def recrawl_candidate?(row, detected)
      return false unless recrawlable?(row)

      entry = @activity_log.entry(row.fin_event_id, :crawl)
      return false if crawled_since?(entry, detected)

      last = entry&.last_timestamp
      !(last && (detected.nil? || last >= detected) && last > SeasonRecheckJob::MIN_RECRAWL_INTERVAL.ago)
    end

    def recrawlable?(row)
      FedernuotoWatch::Parity::RECRAWL_STATES.include?(row.state) && row.url.present? && row.fin_event_id.present? &&
        !row.busy? && !row.flag?(:removed_from_fin)
    end

    def crawled_since?(entry, detected)
      (detected && entry&.done? && entry.finished_at && entry.finished_at >= detected) || false
    end

    # A :link_not_crawled row with a link, not left to the operator (a local calendar not linked yet on its dates, removed
    # from the FIN page, an adopted link whose crawls gave up) and not attempted for the same URL yet.
    def candidate?(row)
      return false unless row.state == :link_not_crawled && row.url.present? && row.fin_event_id.present?
      return false if left_to_operator?(row) || @activity_log.entry(row.fin_event_id, :crawl)&.url == row.url

      !(row.flag?(:link_adopted) && CrawlFailures.adopted_exhausted?(row.fin_event_id))
    end

    def left_to_operator?(row)
      row.flag?(:possible_unlinked_meeting) || row.flag?(:removed_from_fin)
    end

    def plan(row)
      row.fin_event_id if Scheduler.crawl!(season_id: @season.id, fin_event_id: row.fin_event_id, url: row.url, origin: :auto)
    rescue StandardError => e
      # (the Scheduler has already closed the log entry as failed: go on with the other rows)
      Rails.logger.error("[SeasonBoard::CrawlPlanner] enqueue failed for FIN #{row.fin_event_id}: #{e.class}: #{e.message}")
      nil
    end
  end
end
