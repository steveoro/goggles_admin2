# frozen_string_literal: true

module Maintenance
  module Inspectors
    #
    # = Maintenance::Inspectors::TeamCheck ('team.check')
    #
    # The team merge feasibility report of 'check:team' (Merge::TeamChecker#run, #display_report): read only, the
    # report is the console. The preview of 'team.merge'.
    #
    class TeamCheck < Maintenance::Inspector
      self.key = 'team.check'

      param :source_id, :integer, lookup: :team
      param :dest_id, :integer, lookup: :team

      validates :source_id, :dest_id, presence: true

      def self.params_from_finding(_finding) = {}

      def subject = ['team', source_id]
      def label = I18n.t('maintenance.operations.team_check.label', source: source_id, dest: dest_id)

      protected

      def build_plan
        source = GogglesDb::Team.find_by(id: source_id)
        dest = GogglesDb::Team.find_by(id: dest_id)
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: source_id)]) unless source
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: dest_id)]) unless dest

        checker = Merge::TeamChecker.new(source:, dest:)
        checker.run
        checker.display_report
        report_plan(subjects: [{ 'type' => 'team', 'id' => source.id }, { 'type' => 'team', 'id' => dest.id }])
      end
    end
  end
end
