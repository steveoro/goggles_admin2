# frozen_string_literal: true

module Maintenance
  module Inspectors
    #
    # = Maintenance::Inspectors::BadgeCheck ('badge.check')
    #
    # The badge merge (or, without a destination, category auto-fix) feasibility report of 'check:badge'
    # (Merge::BadgeChecker#run, #display_report): read only, the report is the console. The preview of 'badge.merge'.
    #
    class BadgeCheck < Maintenance::Inspector
      self.key = 'badge.check'

      param :source_id, :integer, lookup: :badge
      param :dest_id, :integer, lookup: :badge

      validates :source_id, presence: true

      def self.params_from_finding(_finding) = {}

      def subject = ['badge', source_id]
      def label = I18n.t('maintenance.operations.badge_check.label', source: source_id, dest: dest_id.presence || '-')

      protected

      def build_plan
        source = GogglesDb::Badge.find_by(id: source_id)
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Badge', id: source_id)]) unless source

        dest = dest_id.present? ? GogglesDb::Badge.find_by(id: dest_id) : nil
        checker = Merge::BadgeChecker.new(source:, dest:)
        checker.run
        checker.display_report
        report_plan(subjects: [source, dest].compact.map { |badge| { 'type' => 'badge', 'id' => badge.id } })
      end
    end
  end
end
