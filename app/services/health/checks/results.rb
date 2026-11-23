# frozen_string_literal: true

module Health
  module Checks
    #
    # = Health::Checks::Results
    #
    # The 'results' group, one finding per meeting:
    # - results.null_swimmers: MIRs / MRSs with a NULL swimmer_id (one grouped prefilter query per table, then
    #   Fix::NullSwimmersInMeeting#scan on the flagged meetings only) => error;
    # - results.duplicates: DataFix::PostCommitChecks.build_duplicate_results_check_report (unchanged; its
    #   Merge::DuplicateResultCleaner is built with autofix: false) => error. Its detail says to fix the NULL
    #   swimmers first when the same meeting has them: the duplicate report groups NULL swimmer ids together, while
    #   the generated DELETE (joined on swimmer_id) never matches them;
    # - results.dup_mir_per_badge: more than one MIR per badge and program (season-scoped copy of
    #   'check:dup_mir_badges', one grouped query) => warning.
    #
    class Results < Base
      MAX_GROUPS_IN_PAYLOAD = 20

      def call
        null_findings = null_swimmer_findings
        @null_meeting_ids = null_findings.map(&:subject_id)
        null_findings + duplicate_findings + dup_mir_per_badge_findings
      end

      private

      # == results.null_swimmers

      MIR_JOINS = { meeting_program: { meeting_event: :meeting_session } }.freeze
      MRS_JOINS = { meeting_relay_result: { meeting_program: { meeting_event: :meeting_session } } }.freeze
      private_constant :MIR_JOINS, :MRS_JOINS

      def null_swimmer_findings
        meeting_ids = (null_counts(GogglesDb::MeetingIndividualResult, MIR_JOINS).keys +
                       null_counts(GogglesDb::MeetingRelaySwimmer, MRS_JOINS).keys).uniq
        GogglesDb::Meeting.unscoped.where(id: meeting_ids).order(:id).map { |meeting| null_swimmer_finding(meeting) }
      end

      def null_swimmer_finding(meeting)
        report = Fix::NullSwimmersInMeeting.new(meeting:).scan
        finding('results.null_swimmers', severity: 'error', subject_type: 'meeting', subject_id: meeting.id, identity: "meeting:#{meeting.id}",
                                         title_args: { id: meeting.id, description: meeting.description.to_s.truncate(80),
                                                       mirs: null_total(report, :mirs), mrss: null_total(report, :mrss) },
                                         payload: { 'meeting_id' => meeting.id, 'description' => meeting.description,
                                                    'header_date' => meeting.header_date&.iso8601, 'report' => report.as_json,
                                                    'rake' => { 'meeting_id' => meeting.id } })
      end

      def null_total(report, section)
        report.dig(section, :fixable).to_i + report.dig(section, :unfixable).to_i
      end

      # { meeting_id => count } of the rows with a NULL swimmer_id.
      def null_counts(klass, joins)
        klass.unscoped.joins(joins).joins('INNER JOIN meetings ON meetings.id = meeting_sessions.meeting_id')
             .where(meetings: { season_id: }, swimmer_id: nil).group('meetings.id').count
      end

      # == results.duplicates

      def duplicate_findings
        report = DataFix::PostCommitChecks.build_duplicate_results_check_report(season)
        Array(report[:meetings_with_findings]).map do |row|
          meeting_id = row[:meeting_id]
          groups = Array(row[:duplicate_mirs])
          finding('results.duplicates', severity: 'error', subject_type: 'meeting', subject_id: meeting_id,
                                        identity: "meeting:#{meeting_id}",
                                        title_args: { id: meeting_id, description: row[:meeting_description].to_s.truncate(80),
                                                      total: row[:counts].values.sum },
                                        payload: { 'meeting_id' => meeting_id, 'description' => row[:meeting_description],
                                                   'counts' => row[:counts], 'duplicate_mirs' => groups.first(MAX_GROUPS_IN_PAYLOAD),
                                                   'duplicate_mir_groups' => groups.size,
                                                   'null_swimmers_first' => @null_meeting_ids.include?(meeting_id),
                                                   'rake' => { 'meeting_id' => meeting_id } })
        end
      end

      # == results.dup_mir_per_badge

      def dup_mir_per_badge_findings
        keys = GogglesDb::MeetingIndividualResult.unscoped.joins(MIR_JOINS)
                                                 .joins('INNER JOIN meetings ON meetings.id = meeting_sessions.meeting_id')
                                                 .where(meetings: { season_id: })
                                                 .group('meetings.id', :badge_id, 'meeting_programs.id')
                                                 .having('COUNT(*) > 1').count.keys
        descriptions = GogglesDb::Meeting.unscoped.where(id: keys.map(&:first).uniq).pluck(:id, :description).to_h
        keys.group_by(&:first).sort.map { |meeting_id, rows| dup_mir_per_badge_finding(meeting_id, descriptions[meeting_id], rows) }
      end

      # (+rows+: [meeting_id, badge_id, program_id] keys of the meeting)
      def dup_mir_per_badge_finding(meeting_id, description, rows)
        badge_ids = rows.map(&:second).uniq
        finding('results.dup_mir_per_badge', severity: 'warning', subject_type: 'meeting', subject_id: meeting_id,
                                             identity: "meeting:#{meeting_id}",
                                             title_args: { id: meeting_id, description: description.to_s.truncate(80), count: badge_ids.size },
                                             payload: { 'meeting_id' => meeting_id, 'description' => description,
                                                        'badge_ids' => badge_ids.compact.sort.first(100), 'null_badge' => badge_ids.include?(nil),
                                                        'programs' => rows.size, 'rake' => { 'meeting_id' => meeting_id } })
      end
    end
  end
end
