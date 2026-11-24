# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::ResultsDedupe ('results.dedupe')
    #
    # Deletes the duplicate results of one meeting (MIRs, laps, MRSs, relay laps, MRRs; the lowest id is kept) with the
    # exact call of 'check:dup_mir_swimmers autofix=1':
    #   Merge::DuplicateResultCleaner.new(meeting:, autofix: true)#prepare, #single_transaction_sql_log
    # "Nothing to do" is Plan#empty? (no DELETE), never the rake's 'size <= 5'.
    #
    # Refused while the meeting has an open (or acknowledged) 'results.null_swimmers' finding: the duplicate report
    # groups the NULL swimmer ids together, but the generated deletions join on swimmer_id and never match them; fix the
    # NULL swimmers first ('results.null_swimmers_fix').
    #
    # Confirmation: one click when every duplicate MIR group has the same timing; typed ("DEDUPE <meeting id>")
    # otherwise (the MIR deletion ignores the timing). Fixes: results.duplicates, results.dup_mir_per_badge.
    # Suggests 'ranks.recompute' for the meeting afterwards (never chained).
    #
    # Rake-only params (phase 13, 'check:dup_mir_swimmers'; never on the form): +season_id+ (every meeting of a season,
    # instead of +meeting_id+), +report+ (prints DuplicateResultCleaner#display_report first, captured in the console)
    # and +report_only+ (the report without autofix: no SQL).
    #
    class ResultsDedupe < Maintenance::Operation
      self.key = 'results.dedupe'
      self.confirmation = :one_click
      self.outbox_kind = 'fix'
      self.health_group = 'results'
      self.fixes = %w[results.duplicates results.dup_mir_per_badge].freeze
      self.bumps_db_generation = true

      MAX_GROUPS = 50

      param :meeting_id, :integer, lookup: :meeting
      param :season_id, :integer, form: false
      param :report, :flag, form: false
      param :report_only, :flag, form: false

      validate :one_target

      attr_reader :cleaner

      def self.params_from_finding(finding)
        { 'meeting_id' => payload_of(finding)['meeting_id'] || finding.subject_id }
      end

      def file_base = season_param? ? "fix_dup_results-season_#{season_param}" : "fix_dup_results-#{meeting_id}"
      def season_id = season_param.presence || meeting&.season_id
      def subject = season_param? ? ['season', season_param] : ['meeting', meeting_id]
      def typed_token = season_param? ? "DEDUPE SEASON #{season_param}" : "DEDUPE #{meeting_id}"

      def label
        return I18n.t('maintenance.operations.results_dedupe.label_season', id: season_param) if season_param?

        I18n.t('maintenance.operations.results_dedupe.label', id: meeting_id)
      end

      # Typed as soon as ANY duplicate group (not only the listed ones, capped at MAX_GROUPS) has different timings.
      def confirmation_for(plan)
        mismatches = plan.summary.fetch('timing_mismatch_count') { Array(plan.summary['mir_groups']).count { |group| !group['timing_match'] } }
        mismatches.to_i.positive? ? :typed : :one_click
      end

      def follow_ups(plan)
        return [] if plan.blocked? || plan.empty? || season_param?

        [{ 'operation_key' => 'ranks.recompute', 'params' => { 'meeting_id' => meeting_id } }]
      end

      protected

      def build_plan # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return blank_plan(errors: [not_found_error]) if targets.empty? && (season_param? ? season.nil? : meeting.nil?)
        if !flag?(:report_only) && null_swimmers_open?
          return blank_plan(subjects:,
                            errors: [I18n.t('maintenance.operations.results_dedupe.errors.null_swimmers_first')])
        end

        @cleaner = if season_param?
                     Merge::DuplicateResultCleaner.new(season:,
                                                       autofix: !flag?(:report_only))
                   else
                     Merge::DuplicateResultCleaner.new(
                       meeting:, autofix: !flag?(:report_only)
                     )
                   end
        @cleaner.display_report if flag?(:report) || flag?(:report_only)
        dup_mirs = targets.flat_map { |mtg| @cleaner.find_duplicate_mirs(mtg.id) }
        counts = { 'mirs' => dup_mirs.size, 'laps' => count_of(:find_duplicate_laps), 'mrss' => count_of(:find_duplicate_mrss),
                   'relay_laps' => count_of(:find_duplicate_relay_laps), 'mrrs' => count_of(:find_duplicate_mrrs) }
        return blank_plan(subjects:, summary: { 'counts' => counts }) if flag?(:report_only)

        @cleaner.prepare
        groups = dup_mirs.first(MAX_GROUPS).map { |dup| group_facts(dup) }
        blank_plan(subjects:, summary: target_facts.merge('counts' => counts, 'mir_groups' => groups, 'mir_groups_total' => dup_mirs.size,
                                                          'timing_mismatch_count' => dup_mirs.count { |dup| !dup[:timing_match] }),
                   warnings: warnings_for(dup_mirs), sql_lines: @cleaner.single_transaction_sql_log)
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

      # The meetings checked (the meeting, or every meeting of the season).
      def targets
        @targets ||= if season_param?
                       season ? GogglesDb::Meeting.where(season_id: season.id).order(:id).to_a : []
                     else
                       [meeting].compact
                     end
      end

      def count_of(finder) = targets.sum { |mtg| @cleaner.send(finder, mtg.id).size }

      def target_facts
        season_param? ? { 'season_id' => season.id, 'meetings' => targets.size } : { 'meeting_id' => meeting.id, 'meeting' => meeting.description }
      end

      def not_found_error
        return I18n.t('maintenance.errors.not_found', what: 'Season', id: season_param) if season_param?

        I18n.t('maintenance.errors.not_found', what: 'Meeting', id: meeting_id)
      end

      def subjects = [{ 'type' => subject.first, 'id' => subject.second }]

      def null_swimmers_open?
        Ops.safely(false) do
          next false unless Ops.available?

          scope = Ops::HealthFinding.for_check('results.null_swimmers').unresolved
          season_param? ? scope.exists?(season_id: season_param) : scope.exists?(subject_id: meeting_id)
        end
      end

      def group_facts(dup)
        { 'swimmer_id' => dup[:swimmer].id, 'swimmer' => dup[:swimmer].complete_name, 'program_id' => dup[:meeting_program_id],
          'timing_match' => dup[:timing_match], 'mir_ids' => dup[:mirs].map(&:id),
          'timings' => dup[:mirs].map { |mir| mir.to_timing.to_s } }
      end

      def warnings_for(dup_mirs)
        list = []
        list << I18n.t('maintenance.operations.results_dedupe.warnings.timing_mismatch') if dup_mirs.any? { |dup| !dup[:timing_match] }
        list << I18n.t('maintenance.operations.results_dedupe.warnings.groups_capped', count: dup_mirs.size) if dup_mirs.size > MAX_GROUPS
        list
      end
    end
  end
end
