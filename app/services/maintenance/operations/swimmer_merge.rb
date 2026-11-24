# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::SwimmerMerge ('swimmer.merge')
    #
    # Merges a source swimmer into a destination one with the exact call of 'merge:swimmer':
    #   Merge::Swimmer.new(source:, dest:, skip_columns:, force:)#prepare, #sql_log
    # The checker report is printed by #prepare when it fails (captured in the console) and its log is shown. Checker
    # errors block the plan unless +force+ is set, as the rake task does.
    # Typed confirmation ("MERGE <src> INTO <dest>"). Fixes: swimmers.possible_duplicates.
    #
    class SwimmerMerge < Maintenance::Operation
      self.key = 'swimmer.merge'
      self.confirmation = :typed
      self.outbox_kind = 'merge'
      self.health_group = 'people'
      self.fixes = %w[swimmers.possible_duplicates].freeze
      self.bumps_db_generation = true

      param :source_id
      param :dest_id
      param :skip_columns, :flag
      param :force, :flag

      validates :source_id, :dest_id, presence: true
      validate :distinct_ids

      def self.params_from_finding(finding)
        rake = payload_of(finding)['rake'].to_h
        { 'source_id' => rake['src'], 'dest_id' => rake['dest'] }
      end

      def file_base = "merge_swimmers-#{source_id}-#{dest_id}"
      def season_id = nil
      def subject = ['swimmer', source_id]
      def label = I18n.t('maintenance.operations.swimmer_merge.label', source: source_id, dest: dest_id)
      def typed_token = "MERGE #{source_id} INTO #{dest_id}"

      protected

      def build_plan # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        source = GogglesDb::Swimmer.find_by(id: source_id)
        dest = GogglesDb::Swimmer.find_by(id: dest_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Swimmer', id: source_id)]) unless source
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Swimmer', id: dest_id)]) unless dest

        merger = Merge::Swimmer.new(source:, dest:, skip_columns: flag?(:skip_columns), force: flag?(:force))
        merger.prepare
        checker_errors = merger.errors.map(&:to_s)
        blocking = checker_errors.any? && !flag?(:force)
        blank_plan(subjects: [{ 'type' => 'swimmer', 'id' => source.id }, { 'type' => 'swimmer', 'id' => dest.id }],
                   console: checker_errors.any? ? '' : merger.log.join("\r\n"), # (a failing checker printed its log already)
                   summary: { 'source' => swimmer_facts(source), 'dest' => swimmer_facts(dest),
                              'flags' => %i[skip_columns force].select { |name| flag?(name) }.map(&:to_s) },
                   warnings: merger.warnings.map(&:to_s) + (blocking ? [] : checker_errors),
                   errors: blocking ? [I18n.t('maintenance.operations.swimmer_merge.errors.checker')] + checker_errors : [],
                   sql_lines: blocking ? [] : merger.sql_log)
      end

      private

      def distinct_ids
        errors.add(:dest_id, I18n.t('maintenance.errors.same_ids')) if source_id.present? && source_id == dest_id
      end

      def swimmer_facts(swimmer)
        { 'id' => swimmer.id, 'name' => swimmer.complete_name, 'year_of_birth' => swimmer.year_of_birth,
          'gender_type_id' => swimmer.gender_type_id }
      end
    end
  end
end
