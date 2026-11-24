# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::MeetingTeamFix ('meeting.team_fix')
    #
    # Moves every result of a wrong team to the right one inside a single meeting (MIRs, MRRs, laps, relay laps, with
    # their badges and the duplicates), with the exact calls of 'merge:team_in_1_meeting':
    #   Merge::TeamInMeeting.new(meeting:, src_team:, dest_team:, full_report:, index:)#display_report, #prepare, #sql_log
    # The preview report printed by #display_report is the console. The constructor's ArgumentError (identical teams,
    # ...) becomes a plan error. +index+ only numbers the suggested 'merge:badge' commands of the full report (checked:
    # Merge::TeamInMeeting reads it nowhere else); without it, the next Outbox number is used.
    # Confirmation: the "I have read the dry run" checkbox.
    #
    class MeetingTeamFix < Maintenance::Operation
      self.key = 'meeting.team_fix'
      self.confirmation = :confirm
      self.outbox_kind = 'merge'
      self.health_group = 'badges'
      self.fixes = [].freeze
      self.bumps_db_generation = true

      param :meeting_id, :integer, lookup: :meeting
      param :source_team_id, :integer, lookup: :team
      param :dest_team_id, :integer, lookup: :team
      param :full_report, :flag
      param :index, :integer, form: false

      validates :meeting_id, :source_team_id, :dest_team_id, presence: true

      attr_reader :fixer

      def self.params_from_finding(_finding) = {}

      def file_base = "merge_team_in_meeting-#{meeting_id}-#{source_team_id}-to-#{dest_team_id}"
      def season_id = GogglesDb::Meeting.where(id: meeting_id).pick(:season_id)
      def subject = ['meeting', meeting_id]
      def label = I18n.t('maintenance.operations.meeting_team_fix.label', meeting: meeting_id, source: source_team_id, dest: dest_team_id)

      # True when the last plan stopped on the strategy's input checks (the rake task printed "*** ERROR: ...").
      def argument_error? = @argument_error.present?

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        meeting = GogglesDb::Meeting.find_by(id: meeting_id)
        src_team = GogglesDb::Team.find_by(id: source_team_id)
        dest_team = GogglesDb::Team.find_by(id: dest_team_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Meeting', id: meeting_id)]) unless meeting
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: source_team_id)]) unless src_team
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: dest_team_id)]) unless dest_team

        begin
          @fixer = Merge::TeamInMeeting.new(meeting:, src_team:, dest_team:, full_report: flag?(:full_report), index: report_index)
        rescue ArgumentError => e
          @argument_error = e.message
          return blank_plan(errors: [e.message])
        end
        @fixer.display_report
        @fixer.prepare
        blank_plan(subjects: [{ 'type' => 'meeting', 'id' => meeting.id }, { 'type' => 'team', 'id' => src_team.id },
                              { 'type' => 'team', 'id' => dest_team.id }],
                   summary: { 'meeting' => meeting.description, 'source_team' => src_team.name, 'dest_team' => dest_team.name,
                              'conflicting_badges' => @fixer.conflicting_badges.count, 'badge_merge_pairs' => @fixer.badge_merge_pairs.size },
                   warnings: if @fixer.badge_merge_pairs.any?
                               [I18n.t('maintenance.operations.meeting_team_fix.warnings.badge_pairs',
                                       count: @fixer.badge_merge_pairs.size)]
                             else
                               []
                             end,
                   sql_lines: @fixer.sql_log)
      end

      private

      # The index of the suggested commands: the param, else the next Outbox number (read only).
      def report_index
        index.presence || (Outbox::Sequence.current_max(data_root: Outbox.data_root) + 1)
      end
    end
  end
end
