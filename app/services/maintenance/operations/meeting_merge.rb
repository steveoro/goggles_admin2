# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::MeetingMerge ('meeting.merge')
    #
    # Merges a source meeting into a destination one of the same season with the exact call of 'merge:meeting':
    #   Merge::Meeting.new(source:, dest:, skip_columns:, console_output: false)#prepare, #sql_log
    # (#prepare returns false when the checker fails: the plan is blocked, the checker report printed by #prepare is the
    # console). The merge warning log (timing conflicts, ...) becomes the plan warnings (capped) and its count a fact.
    # After a local apply the post-merge verification (#verify_merge_result: expected vs final counts) is appended to
    # the run console. Typed confirmation ("MERGE <src> INTO <dest>").
    #
    # +console_output+ (rake only, never on the form): the checker progress dots of the former task.
    #
    class MeetingMerge < Maintenance::Operation
      self.key = 'meeting.merge'
      self.confirmation = :typed
      self.outbox_kind = 'merge'
      self.health_group = 'meetings'
      self.fixes = [].freeze
      self.bumps_db_generation = true

      MAX_WARNINGS = 100

      param :source_id, :integer, lookup: :meeting
      param :dest_id, :integer, lookup: :meeting
      param :skip_columns, :flag
      param :console_output, :flag, form: false

      validates :source_id, :dest_id, presence: true
      validate :distinct_ids

      attr_reader :merger

      def self.params_from_finding(_finding) = {}

      def file_base = "merge_meetings-#{source_id}-#{dest_id}"
      def season_id = GogglesDb::Meeting.where(id: dest_id).pick(:season_id)
      def subject = ['meeting', source_id]
      def label = I18n.t('maintenance.operations.meeting_merge.label', source: source_id, dest: dest_id)
      def typed_token = "MERGE #{source_id} INTO #{dest_id}"

      # The post-merge verification (expected counts cached by #prepare, final counts read now).
      def after_local_apply(_plan)
        merger&.verify_merge_result
        nil
      end

      protected

      def build_plan # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        source = GogglesDb::Meeting.find_by(id: source_id)
        dest = GogglesDb::Meeting.find_by(id: dest_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Meeting', id: source_id)]) unless source
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Meeting', id: dest_id)]) unless dest

        @merger = Merge::Meeting.new(source:, dest:, skip_columns: flag?(:skip_columns), console_output: flag?(:console_output))
        subjects = [{ 'type' => 'meeting', 'id' => source.id }, { 'type' => 'meeting', 'id' => dest.id }]
        unless @merger.prepare
          return blank_plan(subjects:, warnings: @merger.warnings.map(&:to_s),
                            errors: [I18n.t('maintenance.operations.meeting_merge.errors.checker')] + @merger.errors.map(&:to_s))
        end

        blank_plan(subjects:, console: @merger.log.join("\r\n"),
                   summary: { 'source' => meeting_facts(source), 'dest' => meeting_facts(dest),
                              'expected_counts' => @merger.expected_counts.transform_keys(&:to_s),
                              'warning_log' => @merger.warning_log.size, 'flags' => flag?(:skip_columns) ? ['skip_columns'] : [] },
                   warnings: @merger.warnings.map(&:to_s) + @merger.warning_log.first(MAX_WARNINGS).map(&:to_s),
                   sql_lines: @merger.sql_log)
      end

      private

      def distinct_ids
        errors.add(:dest_id, I18n.t('maintenance.errors.same_ids')) if source_id.present? && source_id == dest_id
      end

      def meeting_facts(meeting)
        { 'id' => meeting.id, 'description' => meeting.description, 'season_id' => meeting.season_id,
          'header_date' => meeting.header_date&.to_s }
      end
    end
  end
end
