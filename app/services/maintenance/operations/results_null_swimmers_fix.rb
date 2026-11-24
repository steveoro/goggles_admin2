# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::ResultsNullSwimmersFix ('results.null_swimmers_fix')
    #
    # Restores the swimmer of the MIRs / MRSs of one meeting having a NULL swimmer_id from their badge (cascaded to
    # laps and relay laps) with the exact calls of 'fix:nil_swimmers_in_results meeting_id=':
    #   Fix::NullSwimmersInMeeting.new(meeting:)#scan, #fixable?, #prepare
    # wrapped in the transaction of fix.rake. Rows without a usable badge are listed as unfixable and never touched.
    # One click. Fixes: results.null_swimmers.
    #
    class ResultsNullSwimmersFix < Maintenance::Operation
      self.key = 'results.null_swimmers_fix'
      self.confirmation = :one_click
      self.outbox_kind = 'fix'
      self.health_group = 'results'
      self.fixes = %w[results.null_swimmers].freeze

      SECTIONS = %i[mirs mrss laps relay_laps].freeze

      param :meeting_id

      validates :meeting_id, presence: true

      def self.params_from_finding(finding)
        { 'meeting_id' => payload_of(finding)['meeting_id'] || finding.subject_id }
      end

      def file_base = "fix_nil_swimmers-#{meeting_id}"
      def season_id = meeting&.season_id
      def subject = ['meeting', meeting_id]
      def label = I18n.t('maintenance.operations.results_null_swimmers_fix.label', id: meeting_id)

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Meeting', id: meeting_id)]) unless meeting

        fixer = Fix::NullSwimmersInMeeting.new(meeting:)
        report = fixer.scan
        statements = fixer.fixable? ? fixer.prepare : []
        unfixable = (Array(report.dig(:mirs, :details)) + Array(report.dig(:mrss, :details)))
        blank_plan(subjects: [{ 'type' => 'meeting', 'id' => meeting.id }],
                   summary: { 'meeting_id' => meeting.id, 'meeting' => meeting.description, 'report' => report_facts(report),
                              'unfixable' => unfixable },
                   warnings: unfixable.any? ? [I18n.t('maintenance.operations.results_null_swimmers_fix.warnings.unfixable', count: unfixable.size)] : [],
                   sql_lines: wrap(statements))
      end

      private

      def meeting
        return @meeting if defined?(@meeting)

        @meeting = meeting_id && GogglesDb::Meeting.find_by(id: meeting_id)
      end

      def report_facts(report)
        SECTIONS.to_h { |section| [section.to_s, report[section].to_h.except(:details).stringify_keys] }
      end

      # The transaction wrapper of fix.rake (fix:nil_swimmers_in_results).
      def wrap(statements)
        return [] if statements.empty?

        ["-- Fix null swimmers - Meeting #{meeting.id}", "-- Generated: #{Time.zone.now}", '', 'SET AUTOCOMMIT = 0;',
         'START TRANSACTION;', '', *statements, '', 'COMMIT;']
      end
    end
  end
end
