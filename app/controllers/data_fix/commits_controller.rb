# frozen_string_literal: true

module DataFix
  # CommitsController: Phase 6 commit + commit report actions.
  class CommitsController < BaseController
    include FileCounter

    # Phase 6: Commit all entities to DB and generate SQL/log report
    def commit_phase6
      file_path = @file_path
      source_path = @source_path

      phase5_path = source_resolver.default_phase_path_for(source_path, 5)
      overwrite_meta = (PhaseFileManager.new(phase5_path).meta&.dig('individual_result_overwrite') if File.exist?(phase5_path))
      overwrite_candidates = Array(overwrite_meta&.dig('snapshot', 'candidates'))
      overwrite_selected_count = overwrite_candidates.count { |candidate| candidate['selected'] == true }
      if overwrite_meta&.dig('enabled') == true && overwrite_selected_count.positive? && params[:confirm_overwrite].to_s != '1'
        flash[:alert] = I18n.t('data_import.data_fix.individual_result_overwrite_confirmation_required')
        redirect_to(review_results_path(file_path: source_path, phase5_v2: 1)) && return
      end

      # Gather all phase file paths
      phase1_path = source_resolver.default_phase_path_for(source_path, 1)
      phase2_path = source_resolver.default_phase_path_for(source_path, 2)
      phase3_path = source_resolver.default_phase_path_for(source_path, 3)
      phase4_path = source_resolver.default_phase_path_for(source_path, 4)
      phase5_path = source_resolver.default_phase_path_for(source_path, 5)

      # Result-free sources (e.g. manifest-only files) commit a bare meeting
      # structure: only Phase 1 is required and no staged result rows are expected.
      # If staging rows exist anyway, the import is treated as result-bearing.
      mir_count = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).count
      mrr_count = GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: source_path).count
      result_free = source_resolver.source_result_free?(source_path) && mir_count.zero? && mrr_count.zero?

      # Validate required phase files exist
      missing_phases = []
      missing_phases << 1 unless File.exist?(phase1_path)
      unless result_free
        missing_phases << 2 unless File.exist?(phase2_path)
        missing_phases << 3 unless File.exist?(phase3_path)
        missing_phases << 4 unless File.exist?(phase4_path)
        missing_phases << 5 unless File.exist?(phase5_path)
      end

      if missing_phases.any?
        flash[:error] = "Missing phase files: #{missing_phases.join(', ')}. Please complete all phases first."
        redirect_to(review_results_path(file_path: file_path, phase5_v2: 1)) && return
      end

      if result_free
        # Structure-only commit: meeting & sessions must be valid; results are not required.
        structure_report = Import::StructureValidator.new(phase1_data: PhaseFileManager.new(phase1_path).data)
        unless structure_report.valid?
          flash[:error] = "Invalid meeting structure: #{structure_report.error_messages.first(3).join(' • ')}" \
                          "#{" (+#{structure_report.error_messages.size - 3} more)" if structure_report.error_messages.size > 3} " \
                          'Fix the highlighted fields and save the Step 1 forms before committing.'
          redirect_to(review_sessions_path(file_path: file_path, phase_v2: 1)) && return
        end

        # Manifest-extracted sources flag the committed Meeting as manifest-only
        # (applies to new meetings only; existing meetings keep their current flag).
        source_resolver.mark_phase1_manifest_flag!(phase1_path) if source_resolver.parsed_source_json(source_path).dig('_meta', 'meeting_only') == true
      else
        # Validate Phase 5 data exists in data_import_* tables
        if mir_count.zero? && mrr_count.zero?
          flash[:error] = 'No Phase 5 data found. Please rescan Phase 5 (Results) before committing.' # rubocop:disable Rails/I18nLocaleTexts
          redirect_to(review_results_path(file_path: file_path, phase5_v2: 1, rescan: 1)) && return
        end
      end

      # Generate paths for output files
      source_dir = File.dirname(source_path) # Typically 'crawler/data/results.new/<season_id>/'
      # Get folder that stores already sent SQL files to produce a reliable index counter for the file:
      sent_dir = source_dir.to_s.gsub('results.new', 'results.sent')
      dest_file = File.basename(source_path)
      # Prepare a sequential counter prefix for the uploadable batch file:
      last_counter = compute_file_counter(source_dir, sent_dir)
      dest_file = "#{format('%04d', last_counter + 1)}-#{File.basename(dest_file.to_s.gsub('.json', '.sql'))}"
      sql_full_path = File.join(source_dir, dest_file)
      log_full_path = File.join(source_dir, "#{File.basename(source_path, '.json')}.log")

      # Initialize Main with all phase paths and log path
      committer = Import::Committers::Main.new(
        phase1_path: phase1_path,
        phase2_path: phase2_path,
        phase3_path: phase3_path,
        phase4_path: phase4_path,
        phase5_path: phase5_path,
        source_path: source_path,
        log_path: log_full_path
      )

      commit_success = false
      error_message = nil
      stats = nil
      season_id = nil
      done_dir = nil
      first_error_step_label = nil

      begin
        # Commit all entities in a transaction (will generate log file via Main)
        stats = committer.commit_all

        # Guard: if any errors were accumulated, treat as failure even if transaction did not raise
        raise StandardError, "Commit completed with #{stats[:errors].count} errors. Check #{log_full_path} for details." if stats[:errors].any?

        # Write the SQL batch file, move source+phase files to results.done/,
        # clean the staging tables and append the post-commit log section.
        # (LT2 source moved too when this run converted one to LT4.)
        archive = DataFix::CommitArchiver.finalize(
          source_path: source_path,
          lt2_source_path: file_path.gsub('-lt4.json', '.json'),
          phase1_path: phase1_path,
          phase_paths: [phase1_path, phase2_path, phase3_path, phase4_path, phase5_path],
          sql_full_path: sql_full_path,
          log_full_path: log_full_path,
          sql_content: committer.sql_log_content
        )
        season_id = archive[:season_id]
        done_dir = archive[:done_dir]

        commit_success = true
      rescue StandardError => e
        # Log detailed error and prepare report data
        error_message = "Phase 6 commit failed: #{e.message}"
        Rails.logger.error("[Phase 6 Commit] #{error_message}")
        Rails.logger.error(e.backtrace.join("\n"))

        # Ensure stats is available for the report even if commit_all raised early
        stats ||= committer.stats if committer.respond_to?(:stats)
        stats ||= { errors: [] }

        # Derive a suggested step to review from the first logged validation error
        begin
          if committer.respond_to?(:logger) && committer.logger.respond_to?(:entries)
            entries = committer.logger.entries || []
            first_error_entry = entries.find { |entry| entry[:level] == :error }

            if first_error_entry
              entity_type = first_error_entry[:entity_type].to_s
              phase_hint_map = {
                'Meeting' => 1,
                'Calendar' => 1,
                'City' => 1,
                'SwimmingPool' => 1,
                'MeetingSession' => 1,
                'Team' => 2,
                'TeamAffiliation' => 2,
                'Swimmer' => 3,
                'Badge' => 3,
                'MeetingEvent' => 4,
                'MeetingProgram' => 5,
                'MeetingIndividualResult' => 5,
                'MeetingRelayResult' => 5,
                'MeetingRelaySwimmer' => 5,
                'Lap' => 5,
                'RelayLap' => 5
              }

              step = phase_hint_map[entity_type]
              if step
                step_labels = {
                  1 => 'Step 1 • Sessions / Meeting',
                  2 => 'Step 2 • Teams',
                  3 => 'Step 3 • Swimmers',
                  4 => 'Step 4 • Events',
                  5 => 'Step 5 • Results'
                }
                first_error_step_label = step_labels[step]
              end
            end
          end
        rescue StandardError
          # Best-effort hinting only; never break the report rendering
        end
      end

      # Store report data in session for GET action
      session[:commit_report] = {
        file_path: file_path,
        log_path: log_full_path,
        sql_filename: File.basename(sql_full_path),
        commit_success: commit_success,
        error_message: error_message,
        stats: stats,
        season_id: season_id,
        done_dir: done_dir,
        first_error_step_label: first_error_step_label
      }

      # Redirect to report page (POST-redirect-GET pattern)
      redirect_to data_fix_commit_phase6_report_path
    end

    # Phase 6: Display commit report (GET action after POST redirect)
    def commit_phase6_report
      report_data = session[:commit_report]

      # Guard: if no report data in session, redirect to file list
      unless report_data
        flash.now[:warning] = 'No commit report data found. Please run Phase 6 commit first.' # rubocop:disable Rails/I18nLocaleTexts
        redirect_to(pull_result_files_path) && return
      end

      # Clear session data (one-time use)
      session.delete(:commit_report)

      # Set instance variables for view
      @file_path = report_data[:file_path]
      @log_path = report_data[:log_path]
      @sql_filename = report_data[:sql_filename]
      @commit_success = report_data[:commit_success]
      @error_message = report_data[:error_message]
      @stats = report_data[:stats]
      @season_id = report_data[:season_id]
      @done_dir = report_data[:done_dir]
      @first_error_step_label = report_data[:first_error_step_label]
      @post_commit_checks = DataFix::PostCommitChecks.build_post_commit_checks_report(@season_id) if @commit_success && @season_id.present?

      # Render the report view
      render 'data_fix/commit_phase6_report'
    end
  end
end
