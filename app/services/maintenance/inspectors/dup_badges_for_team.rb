# frozen_string_literal: true

module Maintenance
  module Inspectors
    #
    # = Maintenance::Inspectors::DupBadgesForTeam ('team.dup_badges')
    #
    # The report of 'check:dup_badges_for_team' (Merge::DupBadgesForTeamChecker#run, #display_report): the swimmers that
    # ever had a badge on the team and hold duplicate badges in some season (any team). Read only.
    #
    class DupBadgesForTeam < Maintenance::Inspector
      self.key = 'team.dup_badges'

      param :team_id, :integer, lookup: :team

      validates :team_id, presence: true

      def self.params_from_finding(_finding) = {}

      def subject = ['team', team_id]
      def label = I18n.t('maintenance.operations.team_dup_badges.label', id: team_id)

      protected

      def build_plan
        team = GogglesDb::Team.find_by(id: team_id)
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: team_id)]) unless team

        checker = Merge::DupBadgesForTeamChecker.new(team:)
        checker.run
        checker.display_report
        report_plan(subjects: [{ 'type' => 'team', 'id' => team.id }])
      end
    end
  end
end
