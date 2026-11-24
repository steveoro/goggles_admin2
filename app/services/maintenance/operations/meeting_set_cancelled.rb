# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::MeetingSetCancelled ('meeting.set_cancelled')
    #
    # Flags a meeting and/or its calendar as cancelled (the data health "Flag cancelled", formerly
    # Health::MeetingCanceller): one SqlMaker#log_update('cancelled' => true, 'updated_at' => nil) per row not flagged
    # yet, in the wrapper of SeasonBoard::CalendarLinker. Refused when the meeting has results (MIR + MRR > 0).
    #
    # Params: meeting_id and/or calendar_id (the payload 'cancel' target of the finding). One click.
    # Fixes: meetings.no_results.unflagged, meetings.cancel_mismatch, calendars.unlinked (when the finding names a
    # 'cancel' target).
    #
    class MeetingSetCancelled < Maintenance::Operation
      self.key = 'meeting.set_cancelled'
      self.confirmation = :one_click
      self.outbox_kind = 'cancel_flag'
      self.health_group = 'meetings'
      self.fixes = %w[meetings.no_results.unflagged meetings.cancel_mismatch calendars.unlinked].freeze

      param :meeting_id
      param :calendar_id

      validate :target_given

      def self.params_from_finding(finding)
        payload_of(finding)['cancel'].to_h.slice('meeting_id', 'calendar_id')
      end

      # Only findings naming what to flag.
      def self.offer_for?(finding)
        super && payload_of(finding)['cancel'].present?
      end

      def file_base = meeting_id ? "meeting_cancel-#{meeting_id}" : "calendar_cancel-#{calendar_id}"

      def season_id = (meeting || calendar)&.season_id

      def subject = meeting_id ? ['meeting', meeting_id] : ['calendar', calendar_id]

      def label
        return I18n.t('maintenance.operations.meeting_set_cancelled.label_calendar', id: calendar_id) unless meeting_id

        I18n.t('maintenance.operations.meeting_set_cancelled.label_meeting', id: meeting_id)
      end

      protected

      def build_plan
        error = lookup_error
        return blank_plan(errors: [error]) if error

        counts = result_counts
        statements = targets.map { |row| SqlMaker.new(row:).log_update('cancelled' => true, 'updated_at' => nil) }
        refusals = (counts[:mirs] + counts[:mrrs]).positive? ? [I18n.t('maintenance.operations.meeting_set_cancelled.errors.has_results')] : []
        blank_plan(subjects:, summary: summary(counts), errors: refusals, sql_lines: wrap(statements))
      end

      private

      def target_given
        errors.add(:base, I18n.t('maintenance.operations.meeting_set_cancelled.errors.no_target')) if meeting_id.nil? && calendar_id.nil?
      end

      def meeting
        return @meeting if defined?(@meeting)

        @meeting = meeting_id && GogglesDb::Meeting.unscoped.find_by(id: meeting_id)
      end

      def calendar
        return @calendar if defined?(@calendar)

        @calendar = calendar_id && GogglesDb::Calendar.unscoped.find_by(id: calendar_id)
      end

      def lookup_error
        scope = 'maintenance.operations.meeting_set_cancelled.errors'
        return I18n.t("#{scope}.meeting_not_found", id: meeting_id) if meeting_id && meeting.nil?
        return I18n.t("#{scope}.calendar_not_found", id: calendar_id) if calendar_id && calendar.nil?
        return unless meeting && calendar

        I18n.t("#{scope}.other_meeting", id: calendar_id, meeting_id:) if calendar.meeting_id != meeting.id
      end

      # Counts of the meeting (or of the meeting linked to the calendar).
      def result_counts
        target_id = meeting&.id || calendar&.meeting_id
        return { events: 0, mirs: 0, mrrs: 0 } unless target_id

        events = GogglesDb::MeetingEvent.unscoped.joins(:meeting_session).where(meeting_sessions: { meeting_id: target_id }).count
        { events:, mirs: results_count(GogglesDb::MeetingIndividualResult, target_id),
          mrrs: results_count(GogglesDb::MeetingRelayResult, target_id) }
      end

      def results_count(klass, target_id)
        klass.unscoped.joins(meeting_program: { meeting_event: :meeting_session }).where(meeting_sessions: { meeting_id: target_id }).count
      end

      # The rows still to flag.
      def targets = [meeting, calendar].compact.reject(&:cancelled)

      def subjects
        [meeting && { 'type' => 'meeting', 'id' => meeting.id }, calendar && { 'type' => 'calendar', 'id' => calendar.id }].compact
      end

      def summary(counts) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        {
          'meeting_id' => meeting&.id, 'meeting' => meeting&.description, 'header_date' => meeting&.header_date&.iso8601,
          'meeting_cancelled' => meeting&.cancelled, 'calendar_id' => calendar&.id, 'calendar' => calendar&.meeting_name,
          'calendar_cancelled' => calendar&.cancelled, 'events' => counts[:events], 'mirs' => counts[:mirs], 'mrrs' => counts[:mrrs]
        }.compact
      end

      # Same wrapper as SeasonBoard::CalendarLinker (and the former Health::MeetingCanceller).
      def wrap(statements)
        return [] if statements.empty?

        [
          "-- Data health, flag cancelled: season_id=#{season_id}, meeting_id=#{meeting&.id || '-'}, calendar_id=#{calendar&.id || '-'}\r\n",
          'SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";', 'SET AUTOCOMMIT = 0;', 'START TRANSACTION;', "--\r\n",
          *statements, "\r\n--\r\n", 'COMMIT;'
        ]
      end
    end
  end
end
