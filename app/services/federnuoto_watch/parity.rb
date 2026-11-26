# frozen_string_literal: true

module FedernuotoWatch
  #
  # = FedernuotoWatch::Parity
  #
  # Tells whether the pending FIN change (StateStore#pending_change) has been followed up by the pipeline: the condition
  # of the automatic dismissal of the "FIN calendar changed" alert (0.10.103). Read-only: computed from the stored Season
  # board summary (SeasonBoard::Snapshot.fetch, rebuilt when stale), the board activity log and the watcher state.
  #
  # == Actionable rows
  # The rows of the change's 'added', 'updated' and 'with_results' lists that have a link: their own FIN link, or the
  # one their board row adopts from the FIN 'Eventi' calendar. Each is matched to its board row by key, else by FIN id.
  # The other rows are notices (Notices: rows without a link, true removals (a renamed or moved row is no removal, see
  # StateStore.renamed?), "page text only"), except the rows without a link while the automatic 'Eventi' calendar crawl
  # may still lend them one (#awaiting_calendar: switch 'auto_calendar' on, no calendar crawl ended since the ROW was
  # detected, at most CALENDAR_WAIT after it: each row keeps its own detection time, .row_detected_at).
  #
  # == At parity: the pipeline has nothing left to do by itself for the row (state => at parity?)
  # A busy row (crawl, extraction or preparation queued or running) never is. A row missing from the board is not.
  # - :cancelled, :committed_with_results        => yes (nothing to do);
  # - :sql_pending                               => yes (committed locally: the push is the operator's click);
  # - :prepare_failed                            => yes (failed: shown in the inbox, retried once its source changes);
  # - :needs_review, :ready_to_commit            => yes (prepared: the operator reviews or commits);
  # - :in_review                                 => yes (phase files without a check: the operator resumes them);
  # - :archived_unlinked                         => yes (local files, no linked meeting: the operator links them);
  # - :not_linked                                => yes (no link: never actionable anyway);
  # - :structure_committed                       => yes (see below for a 'with_results' row);
  # - :results_ready, :structure_ready, :crawled_no_manifest => no while the automatic preparation will take them
  #                                                 (switch 'auto_prepare' on, row not held), else yes (the operator's);
  # - :manifest_pending                          => no while the automatic extraction will take it (switch
  #                                                 'auto_extract' on, not given up after 3 attempts), else yes;
  # - :link_not_crawled                          => no (to be crawled; its crawl failing keeps it so: the alert stays,
  #                                                 the failure shows on the row and the daily re-check retries it),
  #                                                 except, left to the operator (board Crawl button and "Needs you" Crawl
  #                                                 item): a row flagged :possible_unlinked_meeting, an adopted row whose
  #                                                 unattended crawls gave up (SeasonBoard::CrawlFailures), and a row whose
  #                                                 last crawl ended DONE for its current URL (its files moved or deleted
  #                                                 since: the automation never crawls the same URL again).
  # A 'with_results' row (FIN published its results link) also needs a crawl ended done at or after its OWN detection:
  # until then it is not at parity in RECRAWL_STATES (SeasonBoard::CrawlPlanner#plan_recrawl crawls it again), and is
  # handed to the operator in IN_REVIEW_STATES (a source with phase files, committed locally or archived: never crawled
  # again automatically; listed in the notice as "results published while in review").
  #
  # #call returns a Result (nil when it cannot be computed: no season, no board summary, no pending change); Result
  # #reached? is true when every actionable row is at parity and no row awaits the calendar crawl.
  #
  class Parity # rubocop:disable Metrics/ClassLength
    # Change lists whose rows may need a crawl.
    CHANGE_KEYS = %w[added updated with_results].freeze
    # Rows without a link wait for the automatic 'Eventi' calendar crawl at most this long after the detection.
    CALENDAR_WAIT = 12.hours

    # States at parity whatever the switches (see the class notes).
    SETTLED_STATES = %i[cancelled committed_with_results sql_pending prepare_failed needs_review ready_to_commit in_review
                        archived_unlinked not_linked structure_committed].freeze
    # States the automatic preparation takes next.
    PREPARE_STATES = %i[results_ready structure_ready crawled_no_manifest].freeze
    # States of a 'with_results' row that SeasonBoard::CrawlPlanner#plan_recrawl crawls again for the published results
    # (no source in review: no phase file, no edit, no lease). In any other state with a source (IN_REVIEW_STATES) the
    # row is left to the operator and listed in the notice.
    RECRAWL_STATES = %i[structure_committed results_ready structure_ready manifest_pending crawled_no_manifest].freeze
    IN_REVIEW_STATES = %i[in_review needs_review ready_to_commit prepare_failed sql_pending archived_unlinked].freeze

    # Reasons of a row not at parity (i18n 'federnuoto_watch.alert.progress.reasons.<reason>').
    REASONS = %i[not_on_board crawling extracting preparing busy waiting_crawl crawl_failed waiting_prepare waiting_extract
                 waiting_recrawl].freeze

    # One row of the change: +row+ the change row Hash (String keys), +section+ its change list, +board_row+ the
    # SeasonBoard::Snapshot::Row (or nil), +fin_event_id+ its FIN id (own or adopted, or nil), +reason+ a REASONS
    # Symbol (nil when at parity).
    Item = Data.define(:section, :row, :board_row, :fin_event_id, :reason) do
      def at_parity? = reason.nil?
      def key = row['key']
      def name = row['name'].presence || board_row&.name || key

      # Plain Hash (stored progress and events).
      def to_h
        { 'key' => key, 'name' => name, 'date' => row['date'], 'year' => row['year'], 'place' => row['place'],
          'section' => section, 'fin_event_id' => fin_event_id, 'reason' => reason&.to_s }.compact
      end
    end

    # What the change holds that no crawl can follow (logged as a 'fin.calendar_notice' event when acknowledged):
    # +without_link+ Items (added / updated / with_results rows with no link), +removed+ the true removals (row Hashes),
    # +text_only+ true when no meeting row changed at all, +results_in_review+ Items of 'with_results' rows whose source
    # is in review (or committed locally, or archived) and was not crawled again since FIN published its results: the
    # automation never re-crawls those, the operator checks the results.
    Notices = Data.define(:without_link, :removed, :text_only, :results_in_review) do
      def initialize(results_in_review: [], **) = super

      def any? = without_link.any? || removed.any? || text_only || results_in_review.any?

      # Plain Hash (event data).
      def to_h
        { 'without_link' => without_link.map(&:to_h), 'removed' => removed.map { |row| Parity.row_summary(row) }, 'text_only' => text_only,
          'results_in_review' => results_in_review.map(&:to_h) }
      end
    end

    # - actionable: Items (with a link); awaiting_calendar: Items without a link waiting for the calendar crawl;
    # - notices: Notices; calendar: :queued / :running while the season's default 'Eventi' calendar crawl is busy;
    # - automation: the master switch (DataFix::Automation.enabled?) as read.
    Result = Data.define(:actionable, :awaiting_calendar, :notices, :calendar, :automation) do
      def pending = actionable.reject(&:at_parity?)
      def actionable? = actionable.any?
      def reached? = pending.empty? && awaiting_calendar.empty?

      # The progress payload shown by the alert (FedernuotoWatch::Progress), for the snapshot of +digest+.
      def progress_payload(digest:, now: Time.current)
        { 'digest' => digest, 'checked_at' => now.iso8601, 'automation' => automation, 'actionable' => actionable.size,
          'at_parity' => actionable.count(&:at_parity?), 'awaiting_calendar' => awaiting_calendar.size, 'calendar' => calendar&.to_s,
          'pending' => pending.map(&:to_h), 'reached' => reached? }
      end
    end

    # The decision of FedernuotoWatch::Checker on a new change: [kind, Result or nil].
    # - :alert            the sticky alert is shown (also whenever the master switch is off or the ops DB is not
    #                     available: the operator dismisses it, and when the parity can't be computed);
    # - :wait             nothing actionable yet, rows without a link await the calendar crawl: no alert, the change
    #                     stays pending (the planner passes follow it up);
    # - :nothing_to_crawl nothing actionable: acknowledged at once, logged as a notice;
    # - :parity           every actionable row is already at parity: acknowledged at once.
    # Never raises (an error counts as :alert).
    def self.decision(change, season: SeasonBoard::Builder.latest_season)
      return [:alert, nil] unless Ops.available? && DataFix::Automation.enabled?

      result = new(season:).call(change)
      [decision_for(result), result]
    rescue StandardError => e
      Rails.logger.warn("[FedernuotoWatch::Parity] decision failed, alert shown: #{e.class}: #{e.message}")
      [:alert, nil]
    end

    def self.decision_for(result)
      return :alert if result.nil?
      return (result.awaiting_calendar.any? ? :wait : :nothing_to_crawl) unless result.actionable?

      result.reached? ? :parity : :alert
    end

    # When the row of +key+ entered the change list +section+ (Time): its own detection time ('row_detected_at', kept
    # across the accumulating change, 0.10.103), else the change's first detection (a change stored before), or nil.
    def self.row_detected_at(change, section, key)
      [change.dig('row_detected_at', section, key), change['first_detected_at'], change['detected_at']].each do |value|
        time = Time.zone.parse(value.to_s) if value.present?
        return time if time
      rescue ArgumentError
        next
      end
      nil
    end

    # Short plain Hash of a change row (events).
    def self.row_summary(row)
      row.to_h.slice('key', 'name', 'date', 'year', 'place', 'url').compact_blank
    end

    # == Params
    # - season: the board season; summary: a SeasonBoard::Snapshot::Summary (default: Snapshot.fetch(season));
    # - activity_log: SeasonBoard::ActivityLog; store: StateStore (the current rows, for the renames);
    # - data_dir: base 'crawler/data' folder (the 'Eventi' calendar files); now: reference time.
    def initialize(season:, summary: nil, activity_log: nil, store: nil, data_dir: nil, now: Time.current) # rubocop:disable Metrics/ParameterLists
      @season = season
      @summary = summary
      @activity_log = activity_log || SeasonBoard::ActivityLog.new
      @store = store || StateStore.new
      @data_dir = data_dir
      @now = now
    end

    # Returns the Result for the change Hash (nil when it cannot be computed).
    def call(change)
      return nil unless computable?(change)

      @change = change
      summary = @summary || SeasonBoard::Snapshot.fetch(@season)
      return nil unless summary

      index_board(summary.rows)
      linked, unlinked = change_items.partition(&:fin_event_id)
      awaiting = unlinked.select { |item| calendar_may_lend?(item) }
      actionable = linked.map { |item| item.with(reason: pending_reason(item)) }
      Result.new(actionable:, awaiting_calendar: awaiting, notices: notices(unlinked - awaiting, actionable), calendar: calendar_status,
                 automation: DataFix::Automation.enabled?)
    end

    private

    def computable?(change)
      @season.present? && change.is_a?(Hash) && change['detected_at'].present?
    end

    def index_board(rows)
      @by_key = rows.select(&:key).index_by(&:key)
      @by_fin_id = rows.select(&:fin_event_id).index_by(&:fin_event_id)
    end

    # The Items of the change rows (one per key), board row and link resolved.
    def change_items
      CHANGE_KEYS.flat_map do |section|
        Array(@change[section]).grep(Hash).map do |row|
          own_id = FINEventId.parse(row['url'])
          board_row = @by_key[row['key']] || (own_id && @by_fin_id[own_id])
          Item.new(section:, row:, board_row:, fin_event_id: board_row&.fin_event_id.presence || own_id, reason: nil)
        end
      end.uniq(&:key)
    end

    def notices(unlinked, actionable)
      sections = %w[added removed with_results updated].map { |key| Array(@change[key]) }
      in_review = actionable.select { |item| results_in_review?(item) }
      Notices.new(without_link: unlinked, removed: true_removals, text_only: sections.all?(&:empty?), results_in_review: in_review)
    end

    # A 'with_results' row handed to the operator because its source is in review (see IN_REVIEW_STATES).
    def results_in_review?(item)
      item.at_parity? && item.section == 'with_results' && IN_REVIEW_STATES.include?(item.board_row&.state) && !crawled_since_detection?(item)
    end

    # The removed rows that are no rename or move onto a row still listed.
    def true_removals
      listed = Array(@store.read['rows']).grep(Hash)
      Array(@change['removed']).grep(Hash).reject { |row| StateStore.renamed?(row, listed) }
    end

    # == Per-row parity (see the class notes)

    def pending_reason(item)
      row = item.board_row
      return :not_on_board unless row
      return busy_reason(item.fin_event_id) if row.busy?
      return crawl_reason(row, item.fin_event_id) if row.state == :link_not_crawled
      return recrawl_reason(row) if item.section == 'with_results' && !crawled_since_detection?(item)
      return nil if SETTLED_STATES.include?(row.state)

      state_reason(row)
    end

    def state_reason(row)
      case row.state
      when *PREPARE_STATES then auto_prepare?(row) ? :waiting_prepare : nil
      when :manifest_pending then auto_extract?(row) ? :waiting_extract : nil
      end
    end

    # (a row crawled DONE for its current URL and still :link_not_crawled, e.g. its files moved or deleted since, is
    # never crawled again by the automation: it is left to the operator, whose board row and "Needs you" item offer Crawl)
    def crawl_reason(row, fin_event_id)
      return nil if row.flag?(:possible_unlinked_meeting) || crawled_done_for_url?(row, fin_event_id)
      return nil if row.flag?(:link_adopted) && SeasonBoard::CrawlFailures.adopted_exhausted?(fin_event_id)

      row.flag?(:crawl_failed) ? :crawl_failed : :waiting_crawl
    end

    def crawled_done_for_url?(row, fin_event_id)
      entry = @activity_log.entry(fin_event_id, :crawl)
      (entry&.done? && entry.url.present? && entry.url == row.url) || false
    end

    # A 'with_results' row not crawled since its own detection: waits for the automatic re-crawl in RECRAWL_STATES, else
    # is left to the operator (its source is in review, committed locally or archived: listed in the notice).
    def recrawl_reason(row)
      RECRAWL_STATES.include?(row.state) ? :waiting_recrawl : nil
    end

    # True when a crawl of the row ended done at or after the row's own detection.
    def crawled_since_detection?(item)
      entry = @activity_log.entry(item.fin_event_id, :crawl)
      detected = self.class.row_detected_at(@change, item.section, item.key)
      entry&.done? && entry.finished_at.present? && detected.present? && entry.finished_at >= detected
    end

    def busy_reason(fin_event_id)
      activity = @activity_log.for(fin_event_id)
      return :crawling if activity[:crawl]&.busy?
      return :extracting if activity[:extract]&.busy?

      :preparing
    end

    def auto_prepare?(row)
      DataFix::Automation.enabled?(:auto_prepare) && !row.flag?(:prepare_held)
    end

    def auto_extract?(row)
      pdf_path = row.next_action&.params&.dig(:pdf_path)
      DataFix::Automation.enabled?(:auto_extract) && pdf_path.present? && !SeasonBoard::PipelinePlanner.extraction_gave_up?(pdf_path)
    end

    # == The 'Eventi' calendar crawl

    def calendar_entry
      return @calendar_entry if defined?(@calendar_entry)

      @calendar_entry = @activity_log.entry(Sources::CrawlRequest.eventi_calendar(@season).key, :crawl)
    end

    def calendar_status
      entry = calendar_entry
      return nil unless entry&.busy?(@now)

      entry.running? ? :running : :queued
    end

    # True while the automatic calendar crawl may still lend a link to the row without one: switch on, and the row was
    # detected less than CALENDAR_WAIT ago with no calendar crawl ended since (its own detection time).
    def calendar_may_lend?(item)
      detected = self.class.row_detected_at(@change, item.section, item.key)
      return false unless detected && detected >= @now - CALENDAR_WAIT && auto_calendar?

      !calendar_ended_since?(detected)
    end

    # (memoized per time: the rows of one change share a few detection times)
    def calendar_ended_since?(time)
      @calendar_ended ||= {}
      return @calendar_ended[time] if @calendar_ended.key?(time)

      @calendar_ended[time] = SeasonBoard::CalendarPlanner.ended_since?(@season, time, activity_log: @activity_log, data_dir: @data_dir)
    end

    def auto_calendar?
      @auto_calendar = DataFix::Automation.enabled?(:auto_calendar) unless defined?(@auto_calendar)
      @auto_calendar
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
