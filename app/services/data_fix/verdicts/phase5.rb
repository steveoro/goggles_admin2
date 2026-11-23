# frozen_string_literal: true

module DataFix
  module Verdicts
    #
    # = DataFix::Verdicts::Phase5 (results)
    #
    # Blocked: populate errors; cross-source staging collisions ("waiting for <other> to be committed"); staged rows
    # differing from the source rows (parity); programs flagged by DataFix::IssueDetector (today's Step 5 gate);
    # nothing staged for a result-bearing source; Import::CommitPreflight errors.
    # Review: overwrite mode with selected deletions; partial duplicate matches found by the auto-verify.
    # A result-free source is clean when Phase 1 is structurally valid and nothing is staged.
    #
    class Phase5 < Base
      PHASE = 5

      protected

      def check
        return check_result_free if pipeline.result_free?

        populate = meta['populate'].is_a?(Hash) ? meta['populate'] : {}
        check_populate(populate)
        check_staging
        check_preflight
        check_overwrite_and_verify(populate)
      end

      private

      def check_result_free
        valid = Import::StructureValidator.new(phase1_data: pipeline.phase_data(1)).valid?
        blocked!(:structure_invalid) unless valid
        counts['result_free'] = true
      end

      def check_populate(populate)
        blocked!(:populate_errors, count: populate['errors_count'].to_i, details: populate['errors'])
        collisions = Array(populate['collisions'])
        others = collisions.filter_map { |row| row['other_source'] }.uniq.map { |path| File.basename(path.to_s) }
        blocked!(:collisions, count: populate['collisions_count'].to_i, message: others.join(', '), details: others)
        parity = populate['parity'].is_a?(Hash) ? populate['parity'] : {}
        mismatched = Array(parity['mismatched_programs'])
        blocked!(:parity, count: mismatched.size, details: mismatched) if mismatched.any?
      end

      def check_staging # rubocop:disable Metrics/AbcSize
        staging = DataFix::StagingRows.load_staging_rows(pipeline.source_path)
        programs = Array(data['programs'])
        staged = staging[:mirs].size + staging[:mrrs].size
        blocked!(:nothing_staged) if staged.zero?
        if staged.positive?
          filter_data = DataFix::IssueDetector.load_filter_data(pipeline.source_path, staging)
          flagged = DataFix::IssueDetector.detect_programs_with_issues(programs, filter_data, staging)
          blocked!(:result_issues, count: flagged.size)
        end
        counts.merge!('programs' => programs.size, 'results' => staging[:mirs].size, 'relay_results' => staging[:mrrs].size,
                      'new_results' => staging[:mirs].count { |row| row.meeting_individual_result_id.nil? } +
                                       staging[:mrrs].count { |row| row.meeting_relay_result_id.nil? })
      end

      def check_preflight
        preflight = Import::CommitPreflight.new(pipeline:).call
        preflight.errors.each { |row| blocked!(:"preflight_#{row[:code]}", message: row[:message], count: [row[:count].to_i, 1].max) }
        preflight.warnings.each { |row| info!(:"preflight_#{row[:code]}", message: row[:message], count: [row[:count].to_i, 1].max) }
      end

      def check_overwrite_and_verify(populate)
        overwrite = meta['individual_result_overwrite']
        if overwrite.is_a?(Hash) && overwrite['enabled'] == true
          selected = Array(overwrite.dig('snapshot', 'candidates')).count { |candidate| candidate['selected'] == true }
          review!(:overwrite_selected, count: selected)
          counts['overwrite_deletions'] = selected
        end
        partial = Array(populate.dig('auto_verify', 'partial')).size
        review!(:partial_duplicates, count: partial)
        counts['auto_verified'] = populate.dig('auto_verify', 'verified').to_i
      end
    end
  end
end
