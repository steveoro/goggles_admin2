# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::MeetingPurge ('meeting.purge')
    #
    # Deletes every row of a meeting bottom-up (results, programs, events, sessions, reservations, team scores, the
    # calendar and the meeting row; with +stop_at_events+ only down to the meeting programs) with the exact calls of
    # 'purge:meeting':
    #   Purge::Meeting.new(meeting:, stop_at_events:)#display_report, #prepare, #single_transaction_sql_log
    # The row counts printed by #display_report are the console and the 'row_counts' fact. The rake prompt is the
    # typed confirmation here ("PURGE <meeting id>").
    #
    class MeetingPurge < Maintenance::Operation
      self.key = 'meeting.purge'
      self.confirmation = :typed
      self.outbox_kind = 'purge'
      self.health_group = 'meetings'
      self.fixes = [].freeze
      self.bumps_db_generation = true

      param :meeting_id, :integer, lookup: :meeting
      param :stop_at_events, :flag

      validates :meeting_id, presence: true

      attr_reader :purger

      def self.params_from_finding(_finding) = {}

      def file_base = "purge_meeting-#{meeting_id}"
      def season_id = GogglesDb::Meeting.where(id: meeting_id).pick(:season_id)
      def subject = ['meeting', meeting_id]
      def label = I18n.t('maintenance.operations.meeting_purge.label', id: meeting_id)
      def typed_token = "PURGE #{meeting_id}"

      protected

      def build_plan
        meeting = GogglesDb::Meeting.find_by(id: meeting_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Meeting', id: meeting_id)]) unless meeting

        @purger = Purge::Meeting.new(meeting:, stop_at_events: flag?(:stop_at_events))
        @purger.display_report
        @purger.prepare
        blank_plan(subjects: [{ 'type' => 'meeting', 'id' => meeting.id }],
                   summary: { 'meeting' => meeting.description, 'stop_at_events' => flag?(:stop_at_events),
                              'row_counts' => @purger.row_counts.transform_keys(&:to_s), 'total_rows' => @purger.row_counts.values.sum },
                   sql_lines: @purger.single_transaction_sql_log)
      end
    end
  end
end
