# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::DbIndex
  #
  # DB facts for the Season board, loaded with exactly two queries for the whole season:
  # 1. the season's calendars LEFT JOINed with their meetings (Calendar.unscoped: the
  #    default scope eager-loads 6 associations);
  # 2. the MIR/MRR counts grouped by meeting (only when at least one meeting is linked).
  #
  # Calendars are keyed by FIN event id, stored in 'calendars.results_code'.
  #
  class DbIndex
    MeetingInfo = Data.define(:id, :description, :code, :header_date, :cancelled, :results_acquired, :manifest,
                              :mir_count, :mrr_count) do
      def results_count = mir_count + mrr_count
      def results? = results_acquired || results_count.positive?
      def cancelled? = cancelled
    end

    CalendarInfo = Data.define(:id, :fin_event_id, :meeting_id, :meeting_code, :meeting_name, :meeting_place,
                               :scheduled_date, :year, :month, :cancelled, :results_link, :meeting) do
      def cancelled? = cancelled
      # True when the calendar points to an existing meeting
      def linked? = meeting.present?
    end

    CALENDAR_COLUMNS = %w[
      calendars.id calendars.results_code calendars.meeting_id calendars.meeting_code calendars.meeting_name
      calendars.meeting_place calendars.scheduled_date calendars.year calendars.month calendars.cancelled
      calendars.results_link
      meetings.id meetings.description meetings.code meetings.header_date meetings.cancelled
      meetings.results_acquired meetings.manifest
    ].freeze

    attr_reader :season_id

    def initialize(season_id:)
      @season_id = season_id.to_i
    end

    # All the season calendars (CalendarInfo), sorted by id.
    def calendars
      load! unless @calendars
      @calendars
    end

    # Hash of FIN event id => CalendarInfo. When several calendars share the same FIN id,
    # the one linked to a meeting wins (then the lowest id); see #duplicate_fin_event_ids.
    def calendars_by_fin_id
      @calendars_by_fin_id ||= calendars.select(&:fin_event_id)
                                        .group_by(&:fin_event_id)
                                        .transform_values { |list| list.min_by { |cal| [cal.linked? ? 0 : 1, cal.id] } }
    end

    def calendar_for(fin_event_id)
      calendars_by_fin_id[fin_event_id.to_s]
    end

    # FIN ids used by more than one calendar row of the season.
    def duplicate_fin_event_ids
      calendars.filter_map(&:fin_event_id).tally.select { |_id, count| count > 1 }.keys
    end

    # Hash of meeting id => MeetingInfo (linked meetings only).
    def meetings
      @meetings ||= calendars.filter_map(&:meeting).index_by(&:id)
    end

    def meeting(meeting_id)
      meetings[meeting_id.to_i]
    end

    # { mir: Integer, mrr: Integer } for a linked meeting (zeroes otherwise).
    def counts_for(meeting_id)
      info = meeting(meeting_id)
      { mir: info&.mir_count.to_i, mrr: info&.mrr_count.to_i }
    end

    # Calendars whose FIN id is blank or not among the given (snapshot) FIN ids.
    def orphans(known_fin_event_ids)
      known = known_fin_event_ids.to_set(&:to_s)
      calendars.reject { |cal| cal.fin_event_id && known.include?(cal.fin_event_id) }
    end

    private

    def load!
      rows = GogglesDb::Calendar.unscoped
                                .joins('LEFT OUTER JOIN meetings ON meetings.id = calendars.meeting_id')
                                .where(season_id:)
                                .order('calendars.id')
                                .pluck(*CALENDAR_COLUMNS.map { |col| Arel.sql(col) })
      counts = result_counts(rows.filter_map { |row| row[11] }.uniq)
      @calendars = rows.map { |row| build_calendar(row, counts) }
    end

    # Returns { meeting_id => [mir_count, mrr_count] } with a single grouped query.
    def result_counts(meeting_ids)
      return {} if meeting_ids.empty?

      GogglesDb::MeetingSession.unscoped
                               .joins('INNER JOIN meeting_events ON meeting_events.meeting_session_id = meeting_sessions.id')
                               .joins('INNER JOIN meeting_programs ON meeting_programs.meeting_event_id = meeting_events.id')
                               .joins('LEFT OUTER JOIN meeting_individual_results mir ON mir.meeting_program_id = meeting_programs.id')
                               .joins('LEFT OUTER JOIN meeting_relay_results mrr ON mrr.meeting_program_id = meeting_programs.id')
                               .where(meeting_id: meeting_ids)
                               .group('meeting_sessions.meeting_id')
                               .pluck(Arel.sql('meeting_sessions.meeting_id'), Arel.sql('COUNT(DISTINCT mir.id)'),
                                      Arel.sql('COUNT(DISTINCT mrr.id)'))
                               .to_h { |meeting_id, mir, mrr| [meeting_id, [mir.to_i, mrr.to_i]] }
    end

    def build_calendar(row, counts)
      cal_id, results_code, meeting_id, meeting_code, meeting_name, place, sched, year, month, cancelled, link = row.first(11)
      CalendarInfo.new(
        id: cal_id, fin_event_id: results_code.to_s.strip.presence, meeting_id:, meeting_code:, meeting_name:,
        meeting_place: place, scheduled_date: sched, year:, month:, cancelled: bool(cancelled), results_link: link,
        meeting: build_meeting(row.drop(11), counts)
      )
    end

    def build_meeting(meeting_row, counts)
      id, description, code, header_date, cancelled, results_acquired, manifest = meeting_row
      return nil if id.nil?

      mir, mrr = counts.fetch(id, [0, 0])
      MeetingInfo.new(
        id:, description:, code:, header_date: header_date.is_a?(String) ? Date.parse(header_date) : header_date,
        cancelled: bool(cancelled), results_acquired: bool(results_acquired), manifest: bool(manifest),
        mir_count: mir, mrr_count: mrr
      )
    end

    def bool(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end
  end
end
