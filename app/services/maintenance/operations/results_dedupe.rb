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
    class ResultsDedupe < Maintenance::Operation
      self.key = 'results.dedupe'
      self.confirmation = :one_click
      self.outbox_kind = 'fix'
      self.health_group = 'results'
      self.fixes = %w[results.duplicates results.dup_mir_per_badge].freeze
      self.bumps_db_generation = true

      MAX_GROUPS = 50

      param :meeting_id

      validates :meeting_id, presence: true

      def self.params_from_finding(finding)
        { 'meeting_id' => payload_of(finding)['meeting_id'] || finding.subject_id }
      end

      def file_base = "fix_dup_results-#{meeting_id}"
      def season_id = meeting&.season_id
      def subject = ['meeting', meeting_id]
      def label = I18n.t('maintenance.operations.results_dedupe.label', id: meeting_id)
      def typed_token = "DEDUPE #{meeting_id}"

      # Typed as soon as ANY duplicate group (not only the listed ones, capped at MAX_GROUPS) has different timings.
      def confirmation_for(plan)
        mismatches = plan.summary.fetch('timing_mismatch_count') { Array(plan.summary['mir_groups']).count { |group| !group['timing_match'] } }
        mismatches.to_i.positive? ? :typed : :one_click
      end

      def follow_ups(plan)
        return [] if plan.blocked? || plan.empty?

        [{ 'operation_key' => 'ranks.recompute', 'params' => { 'meeting_id' => meeting_id } }]
      end

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Meeting', id: meeting_id)]) unless meeting
        return blank_plan(subjects:, errors: [I18n.t('maintenance.operations.results_dedupe.errors.null_swimmers_first')]) if null_swimmers_open?

        cleaner = Merge::DuplicateResultCleaner.new(meeting:, autofix: true)
        dup_mirs = cleaner.find_duplicate_mirs(meeting.id)
        counts = { 'mirs' => dup_mirs.size, 'laps' => cleaner.find_duplicate_laps(meeting.id).size,
                   'mrss' => cleaner.find_duplicate_mrss(meeting.id).size,
                   'relay_laps' => cleaner.find_duplicate_relay_laps(meeting.id).size, 'mrrs' => cleaner.find_duplicate_mrrs(meeting.id).size }
        cleaner.prepare
        groups = dup_mirs.first(MAX_GROUPS).map { |dup| group_facts(dup) }
        blank_plan(subjects:, summary: { 'meeting_id' => meeting.id, 'meeting' => meeting.description, 'counts' => counts,
                                         'mir_groups' => groups, 'mir_groups_total' => dup_mirs.size,
                                         'timing_mismatch_count' => dup_mirs.count { |dup| !dup[:timing_match] } },
                   warnings: warnings_for(dup_mirs), sql_lines: cleaner.single_transaction_sql_log)
      end

      private

      def meeting
        return @meeting if defined?(@meeting)

        @meeting = meeting_id && GogglesDb::Meeting.find_by(id: meeting_id)
      end

      def subjects = [{ 'type' => 'meeting', 'id' => meeting_id }]

      def null_swimmers_open?
        Ops.safely(false) do
          Ops.available? && Ops::HealthFinding.for_check('results.null_swimmers').unresolved.exists?(subject_id: meeting_id)
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
