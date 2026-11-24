# frozen_string_literal: true

module Maintenance
  module Inspectors
    #
    # = Maintenance::Inspectors::DupMIRBadges ('meeting.dup_mir_badges')
    #
    # The list of 'check:dup_mir_badges': the badges having more than one MIR in the same program of a meeting (the
    # season-wide view is the data health check results.dup_mir_per_badge). Read only; the fix is 'results.dedupe'.
    #
    class DupMIRBadges < Maintenance::Inspector
      self.key = 'meeting.dup_mir_badges'

      param :meeting_id, :integer, lookup: :meeting

      validates :meeting_id, presence: true

      def self.params_from_finding(finding)
        { 'meeting_id' => payload_of(finding)['meeting_id'] || finding.subject_id }
      end

      def subject = ['meeting', meeting_id]
      def label = I18n.t('maintenance.operations.meeting_dup_mir_badges.label', id: meeting_id)

      protected

      def build_plan
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Meeting', id: meeting_id)]) unless GogglesDb::Meeting.exists?(id: meeting_id)

        badge_ids = GogglesDb::MeetingIndividualResult.joins(meeting_program: { meeting_event: { meeting_session: :meeting } })
                                                      .where(meetings: { id: meeting_id })
                                                      .group(:badge_id, 'meeting_programs.id')
                                                      .having('COUNT(meeting_individual_results.id) > 1')
                                                      .pluck(:badge_id)
        $stdout.puts("\r\n--> Found #{badge_ids.size} badges with > 1 MIR for the *SAME* MeetingProgram.")
        $stdout.puts(badge_ids.size.positive? ? badge_ids.join(', ') : "THAT'S GOOD! No duplicates!")
        follow = badge_ids.any? ? { 'badge_ids' => badge_ids } : {}
        report_plan(subjects: [{ 'type' => 'meeting', 'id' => meeting_id }], summary: { 'badges' => badge_ids.size }.merge(follow))
      end
    end
  end
end
