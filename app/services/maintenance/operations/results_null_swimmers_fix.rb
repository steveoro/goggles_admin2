# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::ResultsNullSwimmersFix ('results.null_swimmers_fix')
    #
    # Restores the swimmer of the MIRs / MRSs of one meeting having a NULL swimmer_id from their badge (cascaded to
    # laps and relay laps) with the exact calls of 'fix:nil_swimmers_in_results meeting_id=':
    #   Fix::NullSwimmersInMeeting.new(meeting:)#scan, #display_report, #fixable?, #prepare
    # wrapped in the transaction of fix.rake. Rows without a usable badge are listed as unfixable and never touched.
    # The scan report of each meeting is the console. One click. Fixes: results.null_swimmers.
    #
    # Rake-only param (phase 13, never on the form): +season_id+ (every meeting of the season, one script, as
    # 'fix:nil_swimmers_in_results season_id=' did).
    #
    class ResultsNullSwimmersFix < Maintenance::Operation
      self.key = 'results.null_swimmers_fix'
      self.confirmation = :one_click
      self.outbox_kind = 'fix'
      self.health_group = 'results'
      self.fixes = %w[results.null_swimmers].freeze

      SECTIONS = %i[mirs mrss laps relay_laps].freeze
      TOTAL_KEYS = { 'mirs' => %i[mirs fixable], 'mrss' => %i[mrss fixable], 'laps' => %i[laps fixable],
                     'relay_laps' => %i[relay_laps fixable], 'unfixable_mirs' => %i[mirs unfixable],
                     'unfixable_mrss' => %i[mrss unfixable] }.freeze

      param :meeting_id, :integer, lookup: :meeting
      param :season_id, :integer, form: false

      validate :one_target

      def self.params_from_finding(finding)
        { 'meeting_id' => payload_of(finding)['meeting_id'] || finding.subject_id }
      end

      def file_base = "fix_nil_swimmers-#{season_param? ? "season_#{season_param}" : meeting_id}"
      def season_id = season_param.presence || meeting&.season_id
      def subject = season_param? ? ['season', season_param] : ['meeting', meeting_id]

      def label
        return I18n.t('maintenance.operations.results_null_swimmers_fix.label_season', id: season_param) if season_param?

        I18n.t('maintenance.operations.results_null_swimmers_fix.label', id: meeting_id)
      end

      # The meetings scanned (the meeting, or every meeting of the season).
      def targets
        @targets ||= if season_param?
                       season ? GogglesDb::Meeting.for_season(season).order(:id).to_a : []
                     else
                       [meeting].compact
                     end
      end

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        return blank_plan(errors: [not_found_error]) if season_param? ? season.nil? : meeting.nil?

        statements = []
        totals = TOTAL_KEYS.transform_values { 0 }
        unfixable = []
        targets.each do |mtg|
          fixer = Fix::NullSwimmersInMeeting.new(meeting: mtg)
          report = @last_report = fixer.scan
          fixer.display_report
          statements.concat(fixer.fixable? ? fixer.prepare : [])
          TOTAL_KEYS.each { |key, path| totals[key] += report.dig(*path).to_i }
          unfixable.concat(Array(report.dig(:mirs, :details)) + Array(report.dig(:mrss, :details)))
        end
        blank_plan(subjects: [{ 'type' => subject.first, 'id' => subject.second }],
                   summary: summary_for(totals, unfixable),
                   warnings: unfixable.any? ? [I18n.t('maintenance.operations.results_null_swimmers_fix.warnings.unfixable', count: unfixable.size)] : [],
                   sql_lines: wrap(statements))
      end

      private

      def season_param = attributes['season_id']
      def season_param? = season_param.present?

      def one_target
        errors.add(:meeting_id, :blank) if meeting_id.blank? && !season_param?
      end

      def meeting
        return @meeting if defined?(@meeting)

        @meeting = meeting_id && GogglesDb::Meeting.find_by(id: meeting_id)
      end

      def season
        return @season if defined?(@season)

        @season = season_param? ? GogglesDb::Season.find_by(id: season_param) : nil
      end

      def not_found_error
        return I18n.t('maintenance.errors.not_found', what: 'Season', id: season_param) if season_param?

        I18n.t('maintenance.errors.not_found', what: 'Meeting', id: meeting_id)
      end

      def summary_for(totals, unfixable)
        target = season_param? ? { 'season_id' => season.id, 'meetings' => targets.size } : { 'meeting_id' => meeting.id, 'meeting' => meeting.description }
        target.merge('totals' => totals, 'report' => (report_facts(@last_report) unless season_param?), 'unfixable' => unfixable.first(200)).compact
      end

      # The scan report of a meeting (phase 11 fact), without the row details.
      def report_facts(report)
        SECTIONS.to_h { |section| [section.to_s, report[section].to_h.except(:details).stringify_keys] }
      end

      # The transaction wrapper of fix.rake (fix:nil_swimmers_in_results).
      def wrap(statements)
        return [] if statements.empty?

        scope = season_param? ? "Season #{season.id}" : "Meeting #{meeting.id}"
        ["-- Fix null swimmers - #{scope}", "-- Generated: #{Time.zone.now}", '', 'SET AUTOCOMMIT = 0;',
         'START TRANSACTION;', '', *statements, '', 'COMMIT;']
      end
    end
  end
end
