# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::Builder
  #
  # Merges the FIN calendar snapshot stored by the watcher (FedernuotoWatch::StateStore), the
  # DB facts (DbIndex), the local files (DiskIndex) & the job activity (ActivityLog) into one
  # SeasonBoard::Row per FIN calendar row, each with a pipeline state & one next action
  # (see SeasonBoard::StateResolver for the states, the rules & the NextAction payloads).
  #
  # Being busy (a queued/running crawl, extraction or prepare in the ActivityLog, a prepare run queued or running, or a
  # prepare job holding the source lease) is an overlay (Row#busy? + :busy flag), not a state; being locked (a job working on the row's files
  # right now: the lease, or a running entry) is the subset that also disables the review links (Row#locked?). The ops pipeline facts of each row's source
  # (SeasonBoard::PipelineIndex, phase 10) feed the :prepare_failed / :needs_review / :ready_to_commit states.
  #
  # Adopted links (0.10.102): a snapshot row without URL takes the meeting link of the FIN "Eventi" calendar row that
  # matches it unambiguously (SeasonBoard::CalendarIndex, derived at every build, never stored in the watcher state).
  # The row is then resolved with that URL exactly as a linked row (state, disk, DB, activity), flagged
  # :link_adopted, and its FIN id counts as "on the snapshot" for the orphans. A row's own URL always wins.
  #
  class Builder # rubocop:disable Metrics/ClassLength
    STATES = StateResolver::STATES
    ACTIONS = StateResolver::ACTIONS

    # The ops pipeline facts used by the build (read by SeasonBoard::PipelinePlanner: see PipelineIndex#read_error?).
    attr_reader :pipeline_index

    FLAGS = RowFlags::FLAGS

    # - rows: Array of Row (snapshot order)
    # - orphans: Array of DbIndex::CalendarInfo (season calendars without FIN id or not in the snapshot)
    # - unmatched_sources: Array of DiskIndex::Entry (pending files without FIN id)
    # - snapshot_checked_at: Time of the last watcher check (or nil)
    # - warnings: Array of Strings
    # - active_activities: Array of ActivityLog::Entry (queued/running, for the page strip)
    # - pending_board_sql_paths: board SQL scripts (backfill/calendar link) awaiting push (optional, default [])
    # - unmatched_pipeline: Hash of unmatched source base => PipelineIndex::Facts (phase 15: the non-FIN sources
    #   prepared from the Sources page; optional, default {})
    # - off_board_sources: Array of DiskIndex::Entry (0.10.102: pending files whose FIN id is on no board row, e.g. a
    #   meeting only on the 'Eventi' calendar, or an adopted link gone since; optional, default [])
    Result = Data.define(:season, :rows, :orphans, :unmatched_sources, :snapshot_checked_at, :warnings, :active_activities,
                         :pending_board_sql_paths, :unmatched_pipeline, :off_board_sources) do
      def initialize(pending_board_sql_paths: [], unmatched_pipeline: {}, off_board_sources: [], **) = super

      # Orphans that can be targets of the manual "Link to meeting" action (see Builder.link_candidates).
      def link_candidates
        Builder.link_candidates(orphans)
      end

      # Hash of state (Symbol) => row count, in row order.
      def state_counts = rows.map(&:state).tally

      # Rows without a FIN link (state :not_linked, hidden by default on the board).
      def unlinked_count = rows.count { |row| row.state == :not_linked }

      # Past rows already committed with results (hidden by default on the board).
      def done_count(today: Date.current) = rows.count { |row| Builder.hidden_as_done?(row, today:) }
    end

    # True for a past row already committed with results (hidden by default on the board).
    # +row+: anything responding to #state and #last_date (Row, Snapshot::Row).
    def self.hidden_as_done?(row, today: Date.current)
      row.state == :committed_with_results && (row.last_date.nil? || row.last_date < today)
    end

    # Orphans that can be targets of the manual "Link to meeting" action: only the calendars
    # without a FIN id yet (CalendarLinker refuses to overwrite a different results_code) and not
    # cancelled. Orphans with a FIN id absent from the snapshot stay listed among the orphans only.
    def self.link_candidates(orphans)
      orphans.reject { |cal| cal.fin_event_id || cal.cancelled? || cal.meeting&.cancelled? }
    end

    # Date of a calendar (DbIndex::CalendarInfo): its ISO 'scheduled_date' (a varchar), else the
    # header date of its meeting, else nil (legacy rows store only the day number there).
    def self.calendar_date(calendar)
      Date.iso8601(calendar.scheduled_date.to_s)
    rescue Date::Error
      calendar.meeting&.header_date
    end

    # Latest MASFIN season (the board target).
    def self.latest_season
      GogglesDb::Season.last_season_by_type(GogglesDb::SeasonType.mas_fin)
    end

    # == Params
    # - season: GogglesDb::Season
    # - rows: snapshot rows (Array of Hashes with String keys); read from +state_store+ when nil
    # - disk_index / db_index / activity_log: defaults built for the season
    # - today: reference date for the "past" checks
    # - state_store: FedernuotoWatch::StateStore used when +rows+ is nil (default store when nil)
    # - snapshot_checked_at: overrides the 'last_checked' time read from the store
    # - pipeline_index: SeasonBoard::PipelineIndex (default: one for the season)
    # - calendar_index: SeasonBoard::CalendarIndex (default: one for the season, on the data folder of the DiskIndex,
    #   as of the last watcher check, else +today+)
    def initialize(season:, rows: nil, disk_index: nil, db_index: nil, activity_log: nil, today: Date.current, # rubocop:disable Metrics/ParameterLists
                   state_store: nil, snapshot_checked_at: nil, pipeline_index: nil, calendar_index: nil)
      @season = season
      @rows = rows
      @disk_index = disk_index || DiskIndex.new(season_id: season.id)
      @db_index = db_index || DbIndex.new(season_id: season.id)
      @activity_log = activity_log || ActivityLog.new
      @pipeline_index = pipeline_index || PipelineIndex.new(season_id: season.id)
      @calendar_index = calendar_index
      @today = today
      @resolver = StateResolver.new(today:)
      @row_flags = RowFlags.new(season:, db_index: @db_index)
      @state_store = state_store
      @snapshot_checked_at = snapshot_checked_at
    end

    # Returns a Result.
    def call
      snapshot_rows = load_snapshot_rows
      @adopted = adopted_links(snapshot_rows)
      fin_ids = snapshot_rows.filter_map { |row| FINEventId.parse(row['url']) || @adopted[row]&.fin_event_id }
      orphans = @db_index.orphans(fin_ids)
      @unlinked_dates = self.class.link_candidates(orphans).filter_map { |cal| self.class.calendar_date(cal) }
      board_rows = snapshot_rows.map { |row| build_row(row) }
      off_board = off_board_sources(fin_ids)

      Result.new(
        season: @season, rows: board_rows, orphans:, unmatched_sources: @disk_index.unmatched, snapshot_checked_at: @snapshot_checked_at,
        warnings: warnings_for(snapshot_rows, board_rows, fin_ids, off_board), active_activities: @activity_log.active,
        pending_board_sql_paths: @disk_index.board_sql_paths, unmatched_pipeline:, off_board_sources: off_board
      )
    end

    private

    # Disk entries with something pending whose FIN id is on no board row (0.10.102), in FIN id order.
    def off_board_sources(fin_ids)
      ids = fin_ids.to_set
      @disk_index.entries.values.select { |entry| ids.exclude?(entry.fin_event_id) && entry.pending? }.sort_by(&:fin_event_id)
    end

    def off_board_warnings(entries)
      return [] if entries.empty?

      [I18n.t('season_board.calendar_links.off_board', count: entries.size, ids: entries.map(&:fin_event_id).join(', '))]
    end

    # Pipeline facts of the unmatched sources (base => Facts; only the ones with an ops row).
    def unmatched_pipeline
      @disk_index.unmatched.each_with_object({}) do |entry, memo|
        facts = @pipeline_index.for_entry(entry)
        memo[entry.bases.first] = facts if facts
      end
    end

    def load_snapshot_rows
      return Array(@rows) if @rows

      state = (@state_store || FedernuotoWatch::StateStore.new).read
      @snapshot_checked_at ||= parse_time(state['last_checked'])
      Array(state['rows'])
    end

    # Snapshot row (identity) => CalendarIndex::Link, for the rows adopting a link of the 'Eventi' calendar.
    # (the default index is built here: it is as of the last watcher check, known once the snapshot is read)
    def adopted_links(snapshot_rows)
      @calendar_index ||= CalendarIndex.new(season: @season, data_dir: @disk_index.data_dir, as_of: @snapshot_checked_at || @today)
      snapshot_rows.each_with_object({}.compare_by_identity) do |row, memo|
        link = @calendar_index.link_for(row, snapshot_rows)
        memo[row] = link if link
      end
    end

    # (an adopted link is resolved as the row's own URL: same state rules, disk, DB & activity matching)
    def build_row(snapshot_row)
      link = @adopted[snapshot_row]
      row = link ? snapshot_row.merge('url' => link.url) : snapshot_row
      fin_id = FINEventId.parse(row['url'])
      calendar = fin_id && @db_index.calendar_for(fin_id)
      disk = fin_id && @disk_index.for(fin_id)
      facts = StateResolver::Facts.new(
        row:, fin_event_id: fin_id, row_date: RowDate.parse(row['date'], row['year']),
        calendar:, meeting: calendar&.meeting, disk:, pipeline: disk && @pipeline_index.for_entry(disk)
      )
      activity = fin_id ? @activity_log.for(fin_id) : ActivityLog::KINDS.index_with(nil)
      assemble_row(facts, @resolver.call(facts), activity, link)
    end

    def assemble_row(facts, outcome, activity, link)
      busy = activity.values.compact.any?(&:busy?) || facts.pipeline&.preparing? || facts.pipeline&.prepare_queued? || false
      flags = @row_flags.call(facts, outcome.state, activity, busy, unlinked_dates: @unlinked_dates, link_adopted: link.present?)
      Row.new(
        **snapshot_attributes(facts), **meeting_attributes(facts.calendar, facts.meeting),
        state: outcome.state, state_detail: outcome.detail, next_action: outcome.next_action,
        activity:, busy:, flags:, disk_entry: facts.disk,
        pipeline: facts.pipeline, locked: locked?(facts, activity), adopted_link: link
      )
    end

    # A job works on the row's files right now: a prepare job holds the source lease, or an entry is running (not stale).
    def locked?(facts, activity)
      facts.pipeline&.leased? || activity.values.compact.any? { |entry| entry.running? && entry.busy? } || false
    end

    def snapshot_attributes(facts)
      row = facts.row
      {
        fin_event_id: facts.fin_event_id, key: row['key'], date_text: row['date'], year: row['year'],
        first_date: facts.row_date.first_date, last_date: facts.row_date.last_date,
        name: row['name'], place: row['place'], url: row['url'].presence, info: row['info'].presence
      }
    end

    def meeting_attributes(calendar, meeting)
      {
        calendar:, calendar_id: calendar&.id, meeting_id: meeting&.id, meeting_description: meeting&.description,
        meeting_header_date: meeting&.header_date, mir_count: meeting&.mir_count.to_i, mrr_count: meeting&.mrr_count.to_i,
        results_acquired: meeting&.results_acquired || false
      }
    end

    # == Warnings

    def warnings_for(snapshot_rows, board_rows, fin_ids, off_board)
      warnings = []
      warnings << 'The FIN calendar snapshot is empty: has the watcher run yet?' if snapshot_rows.empty?
      warnings.concat(date_warnings(board_rows))
      fin_ids.tally.select { |_id, count| count > 1 }.each_key do |fin_id|
        warnings << "FIN event id #{fin_id} appears on more than one snapshot row"
      end
      @row_flags.duplicate_fin_event_ids.each { |fin_id| warnings << "FIN event id #{fin_id} is used by more than one calendar row" }
      warnings.concat(@calendar_index.warnings(snapshot_rows), off_board_warnings(off_board))
    end

    def date_warnings(board_rows)
      warnings = []
      outside = board_rows.select { |row| row.flag?(:outside_season) }
      if outside.any?
        warnings << "#{outside.size} snapshot row(s) (year #{outside.map(&:year).uniq.sort.join(', ')}) fall outside season " \
                    "#{@season.id} (#{@season.begin_date} - #{@season.end_date}): is the snapshot for another season?"
      end
      unparsable = board_rows.count { |row| row.flag?(:unparsable_date) }
      warnings << "#{unparsable} snapshot row(s) with an unparsable date" if unparsable.positive?
      warnings
    end

    def parse_time(value)
      value.present? ? Time.zone.parse(value.to_s) : nil
    rescue ArgumentError
      nil
    end
  end
end
