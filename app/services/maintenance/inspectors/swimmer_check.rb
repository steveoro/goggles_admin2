# frozen_string_literal: true

module Maintenance
  module Inspectors
    #
    # = Maintenance::Inspectors::SwimmerCheck ('swimmer.check')
    #
    # The swimmer merge feasibility report of 'check:swimmer' (Merge::SwimmerChecker#run, #display_report): read only,
    # the report is the console. The preview of 'swimmer.merge'.
    #
    class SwimmerCheck < Maintenance::Inspector
      self.key = 'swimmer.check'

      param :source_id, :integer, lookup: :swimmer
      param :dest_id, :integer, lookup: :swimmer

      validates :source_id, :dest_id, presence: true

      def self.params_from_finding(_finding) = {}

      def subject = ['swimmer', source_id]
      def label = I18n.t('maintenance.operations.swimmer_check.label', source: source_id, dest: dest_id)

      protected

      def build_plan
        source = GogglesDb::Swimmer.find_by(id: source_id)
        dest = GogglesDb::Swimmer.find_by(id: dest_id)
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Swimmer', id: source_id)]) unless source
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Swimmer', id: dest_id)]) unless dest

        checker = Merge::SwimmerChecker.new(source:, dest:)
        checker.run
        checker.display_report
        report_plan(subjects: [{ 'type' => 'swimmer', 'id' => source.id }, { 'type' => 'swimmer', 'id' => dest.id }])
      end
    end
  end
end
