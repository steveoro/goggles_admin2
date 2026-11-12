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
  # Being busy (a queued/running crawl or extraction in the ActivityLog) is an overlay
  # (Row#busy? + :busy flag), not a state.
  #
  class Builder
    STATES = StateResolver::STATES
    ACTIONS = StateResolver::ACTIONS

    FLAGS = RowFlags::FLAGS

    # - rows: Array of Row (snapshot order)
    # - orphans: Array of DbIndex::CalendarInfo (season calendars without FIN id or not in the snapshot)
    # - unmatched_sources: Array of DiskIndex::Entry (pending files without FIN id)
    # - snapshot_checked_at: Time of the last watcher check (or nil)
    # - warnings: Array of Strings
    # - active_activities: Array of ActivityLog::Entry (queued/running, for the page strip)
    # - pending_board_sql_paths: board SQL scripts (backfill/calendar link) awaiting push (optional, default [])
    Result = Data.define(:season, :rows, :orphans, :unmatched_sources, :snapshot_checked_at, :warnings, :active_activities,
                         :pending_board_sql_paths) do
      def initialize(pending_board_sql_paths: [], **) = super

      # Orphans that can be targets of the manual "Link to meeting" action (see Builder.link_candidates).
      def link_candidates
        Builder.link_candidates(orphans)
      end
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
    def initialize(season:, rows: nil, disk_index: nil, db_index: nil, activity_log: nil, today: Date.current, # rubocop:disable Metrics/ParameterLists
                   state_store: nil, snapshot_checked_at: nil)
      @season = season
      @rows = rows
      @disk_index = disk_index || DiskIndex.new(season_id: season.id)
      @db_index = db_index || DbIndex.new(season_id: season.id)
      @activity_log = activity_log || ActivityLog.new
      @resolver = StateResolver.new(today:)
      @row_flags = RowFlags.new(season:, db_index: @db_index)
      @state_store = state_store
      @snapshot_checked_at = snapshot_checked_at
    end

    # Returns a Result.
    def call
      snapshot_rows = load_snapshot_rows
      fin_ids = snapshot_rows.filter_map { |row| FINEventId.parse(row['url']) }
      orphans = @db_index.orphans(fin_ids)
      @unlinked_dates = self.class.link_candidates(orphans).filter_map { |cal| self.class.calendar_date(cal) }
      board_rows = snapshot_rows.map { |row| build_row(row) }

      Result.new(
        season: @season, rows: board_rows, orphans:,
        unmatched_sources: @disk_index.unmatched, snapshot_checked_at: @snapshot_checked_at,
        warnings: warnings_for(snapshot_rows, board_rows, fin_ids), active_activities: @activity_log.active,
        pending_board_sql_paths: @disk_index.board_sql_paths
      )
    end

    private

    def load_snapshot_rows
      return Array(@rows) if @rows

      state = (@state_store || FedernuotoWatch::StateStore.new).read
      @snapshot_checked_at ||= parse_time(state['last_checked'])
      Array(state['rows'])
    end

    def build_row(row)
      fin_id = FINEventId.parse(row['url'])
      calendar = fin_id && @db_index.calendar_for(fin_id)
      facts = StateResolver::Facts.new(
        row:, fin_event_id: fin_id, row_date: RowDate.parse(row['date'], row['year']),
        calendar:, meeting: calendar&.meeting, disk: fin_id && @disk_index.for(fin_id)
      )
      activity = fin_id ? @activity_log.for(fin_id) : { crawl: nil, extract: nil }
      assemble_row(facts, @resolver.call(facts), activity)
    end

    def assemble_row(facts, outcome, activity)
      busy = activity.values.compact.any?(&:busy?)
      Row.new(
        **snapshot_attributes(facts), **meeting_attributes(facts.calendar, facts.meeting),
        state: outcome.state, state_detail: outcome.detail, next_action: outcome.next_action,
        activity:, busy:, flags: @row_flags.call(facts, outcome.state, activity, busy, unlinked_dates: @unlinked_dates), disk_entry: facts.disk
      )
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

    def warnings_for(snapshot_rows, board_rows, fin_ids)
      warnings = []
      warnings << 'The FIN calendar snapshot is empty: has the watcher run yet?' if snapshot_rows.empty?
      warnings.concat(date_warnings(board_rows))
      fin_ids.tally.select { |_id, count| count > 1 }.each_key do |fin_id|
        warnings << "FIN event id #{fin_id} appears on more than one snapshot row"
      end
      @row_flags.duplicate_fin_event_ids.each { |fin_id| warnings << "FIN event id #{fin_id} is used by more than one calendar row" }
      warnings
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
