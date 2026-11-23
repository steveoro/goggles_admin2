# frozen_string_literal: true

module Health
  module Checks
    #
    # = Health::Checks::Meetings
    #
    # The 'meetings' group, from one Health::SeasonFacts load (3 queries) plus, only when needed, one
    # SeasonBoard::DiskIndex scan of the season folders:
    # - meetings.no_results.unflagged: past meeting, not cancelled (meeting and calendar), MIR + MRR = 0, no
    #   source on disk (closed season: error; current season: warning, only RECENT_DAYS after the header date);
    # - meetings.no_results.source_on_disk: the same, but the Data-Fix files of its FIN event id hold a results
    #   source, phase files or a commit SQL waiting to be pushed (error);
    # - meetings.cancel_mismatch: calendar and meeting 'cancelled' flags differ, or a cancelled meeting/calendar
    #   has results (error), otherwise warning;
    # - calendars.unlinked: calendar not cancelled whose meeting_id is NULL or dangling (never imported), and FIN
    #   ids shared by several calendars (closed: error; current: warning, past calendars only); a calendar whose code
    #   matches a meeting of the season only misses its link (own title, the meeting ids as evidence, warning);
    # - meetings.no_events: meeting not cancelled without events (warning when past, info when future);
    # - meetings.results_flag: meetings with 'results_acquired' still false and MIR + MRR > 0: ONE finding per season
    #   (warning), since its fix is one season-wide command (season_board:backfill).
    #
    class Meetings < Base # rubocop:disable Metrics/ClassLength
      MAX_IDS_IN_PAYLOAD = 200

      def call
        facts = Health::SeasonFacts.new(season_id:)
        facts.meetings.flat_map { |meeting| meeting_findings(meeting) } + [results_flag(facts.meetings)].compact +
          calendar_findings(facts.calendars, facts.meetings)
      end

      private

      def meeting_findings(meeting)
        [no_results(meeting), cancel_mismatch(meeting), no_events(meeting)].compact
      end

      # == meetings.no_results.*

      def no_results(meeting)
        return unless no_results_due?(meeting)

        entry = meeting.fin_event_id && disk_index.for(meeting.fin_event_id)
        disk = disk_facts(entry)
        return no_results_on_disk(meeting, disk) if disk

        finding('meetings.no_results.unflagged', severity: closed? ? 'error' : 'warning', **meeting_subject(meeting),
                                                 title_args: meeting_title_args(meeting),
                                                 payload: meeting_payload(meeting).merge(cancel_target(meeting_id: meeting.id,
                                                                                                       calendar_id: open_calendar_id(meeting))))
      end

      def no_results_on_disk(meeting, disk)
        finding('meetings.no_results.source_on_disk', severity: 'error', **meeting_subject(meeting),
                                                      title_args: meeting_title_args(meeting).merge(file: disk['base']),
                                                      payload: meeting_payload(meeting).merge('disk' => disk))
      end

      def no_results_due?(meeting)
        return false if meeting.cancelled? || meeting.calendar_cancelled? || meeting.results? || meeting.header_date.nil?
        return meeting.header_date < today if closed?

        meeting.header_date < today - RECENT_DAYS
      end

      # Disk facts of a DiskIndex::Entry having a results source, phase files or a pending commit SQL (else nil).
      def disk_facts(entry)
        source = entry && (entry.review_source || entry.results_source)
        return unless source || entry&.sql_pending?

        facts = { 'base' => entry.bases.first, 'results' => false, 'sql_pending' => entry.sql_pending?,
                  'sql_path' => entry.sql_new_paths.first, 'path' => entry.sql_new_paths.first }
        return facts unless source

        facts.merge('base' => source.base, 'phase' => source.phase, 'review_path' => source.review_path,
                    'results' => source.results?, 'path' => source.review_path)
      end

      # == meetings.cancel_mismatch

      def cancel_mismatch(meeting)
        calendar = meeting.calendar
        flags_differ = calendar && calendar.cancelled? != meeting.cancelled?
        cancelled_with_results = (meeting.cancelled? || meeting.calendar_cancelled?) && meeting.results?
        return unless flags_differ || cancelled_with_results

        finding('meetings.cancel_mismatch', severity: cancelled_with_results ? 'error' : 'warning', **meeting_subject(meeting),
                                            title_args: meeting_title_args(meeting),
                                            payload: meeting_payload(meeting).merge(mismatch_target(meeting))
                                                                             .merge('cancelled_with_results' => cancelled_with_results))
      end

      # The linked calendar id when the calendar is not cancelled (flagged together with the meeting).
      def open_calendar_id(meeting)
        meeting.calendar.id if meeting.calendar && !meeting.calendar.cancelled?
      end

      # "Flag cancelled" target for the side not flagged yet, when it has no results.
      def mismatch_target(meeting)
        return {} if meeting.results?
        return cancel_target(meeting_id: meeting.id) if meeting.calendar_cancelled? && !meeting.cancelled?
        return cancel_target(calendar_id: meeting.calendar.id) if meeting.cancelled? && meeting.calendar && !meeting.calendar.cancelled?

        {}
      end

      # == meetings.no_events

      def no_events(meeting)
        return if meeting.cancelled? || meeting.events.positive?

        past = meeting.header_date.present? && meeting.header_date < today
        disk = meeting.fin_event_id && structure_facts(disk_index.for(meeting.fin_event_id))
        finding('meetings.no_events', severity: past ? 'warning' : 'info', **meeting_subject(meeting),
                                      title_args: meeting_title_args(meeting),
                                      payload: meeting_payload(meeting).merge('disk' => disk).compact)
      end

      # Disk facts of any pending source (for the structure review link), else nil.
      def structure_facts(entry)
        source = entry && (entry.review_source || entry.structure_source || entry.results_source || entry.result_free_source)
        return unless source

        { 'base' => source.base, 'phase' => source.phase, 'review_path' => source.review_path, 'path' => source.review_path }
      end

      # == meetings.results_flag

      def results_flag(meetings)
        flagged = meetings.select { |meeting| !meeting.results_acquired && meeting.results? }
        return if flagged.empty?

        finding('meetings.results_flag', severity: 'warning', subject_type: 'season', subject_id: season_id, identity: "season:#{season_id}",
                                         title_args: { id: season_id, count: flagged.size },
                                         payload: { 'season_id' => season_id, 'count' => flagged.size,
                                                    'meeting_ids' => flagged.map(&:id).first(MAX_IDS_IN_PAYLOAD),
                                                    'rake' => { 'season_id' => season_id } })
      end

      # == calendars.unlinked

      def calendar_findings(calendars, meetings)
        by_code = meetings.group_by(&:code).transform_values { |list| list.map(&:id) }
        unlinked = calendars.select { |cal| unlinked_due?(cal) }.map { |cal| unlinked_finding(cal, by_code.fetch(cal.meeting_code, [])) }
        unlinked + duplicate_fin_findings(calendars)
      end

      def unlinked_due?(calendar)
        return false if calendar.cancelled? || calendar.linked?
        return true if closed?

        date = to_date(calendar.scheduled_date)
        date.present? && date < today - RECENT_DAYS
      end

      # (+same_code_ids+: the season meetings with the calendar's code: the meeting exists, only the link is missing)
      def unlinked_finding(calendar, same_code_ids)
        payload = calendar_payload(calendar).merge('same_code_meeting_ids' => same_code_ids)
        payload.merge!(cancel_target(calendar_id: calendar.id)) if same_code_ids.empty?
        finding('calendars.unlinked', severity: closed? && same_code_ids.empty? ? 'error' : 'warning', subject_type: 'calendar',
                                      subject_id: calendar.id, identity: "calendar:#{calendar.id}",
                                      title_args: calendar_title_args(calendar).merge(meetings: same_code_ids.join(', ')),
                                      title_key: same_code_ids.empty? ? 'finding' : 'finding_same_code', payload:)
      end

      def duplicate_fin_findings(calendars)
        calendars.select(&:fin_event_id).group_by(&:fin_event_id).filter_map do |fin_event_id, list|
          next if list.size < 2

          ids = list.map(&:id).sort
          finding('calendars.unlinked', severity: closed? ? 'error' : 'warning', subject_type: 'calendars', subject_id: ids.first,
                                        subject_ids: ids, identity: "calendars:#{id_list(ids)}",
                                        title_args: { fin_event_id:, ids: ids.join(', ') }, title_key: 'finding_duplicate',
                                        payload: { 'duplicate_fin_event_id' => fin_event_id, 'calendars' => list.map { |cal| calendar_payload(cal) },
                                                   'fin_event_id' => fin_event_id })
        end
      end

      # == Payload helpers

      def disk_index
        @disk_index ||= SeasonBoard::DiskIndex.new(season_id:, data_dir:)
      end

      def meeting_subject(meeting)
        { subject_type: 'meeting', subject_id: meeting.id, identity: "meeting:#{meeting.id}" }
      end

      def meeting_title_args(meeting)
        { id: meeting.id, date: meeting.header_date&.iso8601 || '-', description: meeting.description.to_s.truncate(80) }
      end

      def meeting_payload(meeting)
        calendar = meeting.calendar
        {
          'meeting_id' => meeting.id, 'header_date' => meeting.header_date&.iso8601, 'code' => meeting.code,
          'description' => meeting.description, 'cancelled' => meeting.cancelled?, 'results_acquired' => meeting.results_acquired,
          'manifest' => meeting.manifest, 'events' => meeting.events, 'mirs' => meeting.mirs, 'mrrs' => meeting.mrrs,
          'calendar_id' => calendar&.id, 'calendar_ids' => meeting.calendar_ids, 'calendar_cancelled' => calendar&.cancelled?,
          'fin_event_id' => meeting.fin_event_id, 'results_link' => calendar&.results_link
        }
      end

      def calendar_title_args(calendar)
        { id: calendar.id, date: calendar.scheduled_date.presence || '-', name: calendar.meeting_name.to_s.truncate(80) }
      end

      def calendar_payload(calendar)
        { 'calendar_id' => calendar.id, 'meeting_id' => calendar.meeting_id, 'meeting_name' => calendar.meeting_name,
          'meeting_place' => calendar.meeting_place, 'scheduled_date' => calendar.scheduled_date, 'cancelled' => calendar.cancelled?,
          'fin_event_id' => calendar.fin_event_id, 'results_link' => calendar.results_link,
          'dangling_meeting' => calendar.meeting_id.present? && !calendar.linked? }
      end

      # Payload entry read by the "Flag cancelled" button (Health::CancellationsController).
      def cancel_target(meeting_id: nil, calendar_id: nil)
        { 'cancel' => { 'meeting_id' => meeting_id, 'calendar_id' => calendar_id }.compact }
      end
    end
  end
end
