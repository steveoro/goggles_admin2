# frozen_string_literal: true

module Health
  #
  # = Health::SeasonFacts
  #
  # Shared loader of the 'meetings' check group: the season meetings with their linked calendar and their
  # event / MIR / MRR counts, plus every season calendar, in exactly three queries (Meeting and Calendar are
  # read +unscoped+: their default scopes eager-load several associations):
  # 1. the season meetings;
  # 2. one grouped count per meeting (LEFT JOINs, so that a meeting without sessions counts 0; COUNT DISTINCT
  #    because the individual and relay results of a program are joined together);
  # 3. the season calendars LEFT JOINed with their meeting (a NULL or dangling meeting_id means "never imported").
  #
  # "No results" means MIR + MRR = 0 (a relay-only meeting has results).
  #
  class SeasonFacts
    CalendarRow = Data.define(:id, :meeting_id, :cancelled, :results_code, :results_link, :scheduled_date,
                              :meeting_name, :meeting_place, :meeting_code, :meeting_exists) do
      def cancelled? = cancelled
      # FIN event id ('calendars.results_code', stripped; nil when blank).
      def fin_event_id = results_code.to_s.strip.presence
      def linked? = meeting_exists
    end

    MeetingRow = Data.define(:id, :code, :description, :header_date, :cancelled, :results_acquired, :manifest,
                             :events, :mirs, :mrrs, :calendar, :calendar_ids) do
      def cancelled? = cancelled
      def results_count = mirs + mrrs
      def results? = results_count.positive?
      def calendar_cancelled? = calendar&.cancelled? || false
      def fin_event_id = calendar&.fin_event_id
    end

    attr_reader :season_id

    def initialize(season_id:)
      @season_id = season_id.to_i
    end

    # Season meetings (MeetingRow), by header date then id.
    def meetings
      load! unless @meetings
      @meetings
    end

    # Season calendars (CalendarRow), by id.
    def calendars
      load! unless @calendars
      @calendars
    end

    private

    def load!
      @calendars = load_calendars
      counts = load_counts
      by_meeting = @calendars.select(&:meeting_id).group_by(&:meeting_id)
      @meetings = load_meetings.map { |row| build_meeting(row, counts, by_meeting) }
                               .sort_by { |m| [m.header_date || Date.new(1900), m.id] }
    end

    def load_meetings
      GogglesDb::Meeting.unscoped.where(season_id:)
                        .pluck(:id, :code, :description, :header_date, :cancelled, :results_acquired, :manifest)
    end

    # { meeting_id => [events, mirs, mrrs] }
    def load_counts
      GogglesDb::Meeting.unscoped.where(season_id:)
                        .joins('LEFT JOIN meeting_sessions ms ON ms.meeting_id = meetings.id')
                        .joins('LEFT JOIN meeting_events me ON me.meeting_session_id = ms.id')
                        .joins('LEFT JOIN meeting_programs mp ON mp.meeting_event_id = me.id')
                        .joins('LEFT JOIN meeting_individual_results mir ON mir.meeting_program_id = mp.id')
                        .joins('LEFT JOIN meeting_relay_results mrr ON mrr.meeting_program_id = mp.id')
                        .group('meetings.id')
                        .pluck(Arel.sql('meetings.id'), Arel.sql('COUNT(DISTINCT me.id)'), Arel.sql('COUNT(DISTINCT mir.id)'),
                               Arel.sql('COUNT(DISTINCT mrr.id)'))
                        .to_h { |id, events, mirs, mrrs| [id, [events.to_i, mirs.to_i, mrrs.to_i]] }
    end

    def load_calendars
      GogglesDb::Calendar.unscoped.where(season_id:)
                         .joins('LEFT JOIN meetings m ON m.id = calendars.meeting_id')
                         .order('calendars.id')
                         .pluck(*%w[calendars.id calendars.meeting_id calendars.cancelled calendars.results_code calendars.results_link
                                    calendars.scheduled_date calendars.meeting_name calendars.meeting_place calendars.meeting_code
                                    m.id].map { |col| Arel.sql(col) })
                         .map { |row| build_calendar(row) }
    end

    def build_calendar(row)
      id, meeting_id, cancelled, code, link, scheduled, name, place, meeting_code, existing_id = row
      CalendarRow.new(id:, meeting_id:, cancelled: bool(cancelled), results_code: code, results_link: link, scheduled_date: scheduled,
                      meeting_name: name, meeting_place: place, meeting_code:, meeting_exists: existing_id.present?)
    end

    # The linked calendar: the first one not cancelled, else the lowest id.
    def build_meeting(row, counts, by_meeting)
      id, code, description, header_date, cancelled, results_acquired, manifest = row
      events, mirs, mrrs = counts.fetch(id, [0, 0, 0])
      calendars = by_meeting.fetch(id, [])
      MeetingRow.new(id:, code:, description:, header_date: header_date.is_a?(String) ? Date.parse(header_date) : header_date,
                     cancelled: bool(cancelled), results_acquired: bool(results_acquired), manifest: bool(manifest),
                     events:, mirs:, mrrs:, calendar: calendars.find { |cal| !cal.cancelled? } || calendars.first,
                     calendar_ids: calendars.map(&:id))
    end

    def bool(value)
      ActiveModel::Type::Boolean.new.cast(value) || false
    end
  end
end
