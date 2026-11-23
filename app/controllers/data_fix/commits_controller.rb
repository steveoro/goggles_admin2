# frozen_string_literal: true

module DataFix
  # CommitsController: Phase 6 commit + commit report actions.
  class CommitsController < BaseController
    # (retry_archive takes the archived source path as is: no working-copy resolution)
    skip_before_action :set_source_path, only: :retry_archive

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
        flash[:error] = I18n.t('data_import.data_fix.missing_phase_files', list: missing_phases.join(', '))
        redirect_to(review_results_path(file_path: file_path, phase5_v2: 1)) && return
      end

      if result_free
        # Structure-only commit: meeting & sessions must be valid; results are not required.
        structure_report = Import::StructureValidator.new(phase1_data: PhaseFileManager.new(phase1_path).data)
        unless structure_report.valid?
          error_count = structure_report.error_messages.size
          flash[:error] = I18n.t('data_import.data_fix.invalid_meeting_structure',
                                 errors: structure_report.error_messages.first(3).join(' • '),
                                 more: error_count > 3 ? " (+#{error_count - 3} more)" : '')
          redirect_to(review_sessions_path(file_path: file_path, phase_v2: 1)) && return
        end

        # Manifest-extracted sources flag the committed Meeting as manifest-only
        # (applies to new meetings only; existing meetings keep their current flag).
        source_resolver.mark_phase1_manifest_flag!(phase1_path) if source_resolver.parsed_source_json(source_path).dig('_meta', 'meeting_only') == true
      else
        # Validate Phase 5 data exists in data_import_* tables
        if mir_count.zero? && mrr_count.zero?
          flash[:error] = I18n.t('data_import.data_fix.no_phase5_data')
          redirect_to(review_results_path(file_path: file_path, phase5_v2: 1, rescan: 1)) && return
        end
      end

      # Generate paths for output files
      source_dir = File.dirname(source_path) # Typically 'crawler/data/results.new/<season_id>/'
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

      commit_state = 'failed'
      error_message = nil
      archive_error = nil
      stats = nil
      season_id = nil
      done_dir = nil
      first_error_step_label = nil
      script = nil

      begin
        # Commit all entities in a transaction (will generate log file via Main). The SQL script is registered in
        # the Outbox INSIDE the local transaction (before_commit): a failed write rolls the local commit back.
        stats = committer.commit_all(before_commit: lambda { |sql|
          script = write_commit_script(source_path:, sql:, committer:)
        })

        # Guard: if any errors were accumulated, treat as failure even if transaction did not raise
        raise StandardError, "Commit completed with #{stats[:errors].count} errors. Check #{log_full_path} for details." if stats[:errors].any?

        commit_state = 'committed'
      rescue StandardError => e
        if committer.committed?
          # (e.g. the log file write failed after the local COMMIT: the commit and its script stand)
          Rails.logger.error("[Phase 6 Commit] committed, then: #{e.class}: #{e.message}")
          commit_state = 'committed'
        else
          # The local transaction rolled back: a script written meanwhile must not stay pushable.
          Outbox::Writer.discard!(script)
          script = nil
          # Log detailed error and prepare report data
          error_message = "Phase 6 commit failed: #{e.message}"
          Rails.logger.error("[Phase 6 Commit] #{error_message}")
          Rails.logger.error(e.backtrace.join("\n"))

          # Ensure stats is available for the report even if commit_all raised early
          stats ||= committer.stats if committer.respond_to?(:stats)
          stats ||= { errors: [] }
          first_error_step_label = first_error_step_label_for(committer)
        end
      end

      if commit_state == 'committed'
        begin
          # Move source+phase files to results.done/, clean the staging tables and append the
          # post-commit log section. (LT2 source moved too when this run converted one to LT4.)
          archive = archive_commit_files(source_path:, file_path:, log_full_path:)
          season_id = archive[:season_id]
          done_dir = archive[:done_dir]
        rescue StandardError => e
          # The local DB is committed and the script registered: only the bookkeeping failed ("Retry archiving").
          commit_state = 'committed_archive_failed'
          archive_error = "#{e.class}: #{e.message}"
          season_id = Outbox.season_id_for(File.basename(source_dir))
          Rails.logger.error("[Phase 6 Commit] archiving failed: #{archive_error}")
        end
      end

      sql_filename = script&.filename
      # Store report data in session for GET action
      session[:commit_report] = {
        file_path: file_path,
        log_path: log_full_path,
        sql_filename: sql_filename,
        script_id: script.respond_to?(:id) ? script.id : nil,
        commit_success: commit_state == 'committed',
        commit_state: commit_state,
        error_message: error_message,
        archive_error: archive_error,
        stats: stats,
        season_id: season_id,
        done_dir: done_dir,
        first_error_step_label: first_error_step_label
      }
      record_commit_event(source_path:, sql_filename:, commit_state:, season_id:,
                          error_message: error_message || archive_error, stats:)
      enqueue_health_runs(season_id:, commit_state:)

      # Redirect to report page (POST-redirect-GET pattern)
      redirect_to data_fix_commit_phase6_report_path
    end

    # Phase 6, "committed, archiving failed": runs the archiving step again (idempotent: moves only the files still
    # in results.new, purges the staging rows left, appends the log section), then shows the report again.
    # Never commits anything.
    def retry_archive
      source_path = params[:file_path].to_s
      unless retryable_source?(source_path)
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_result_files_path) && return
      end

      log_full_path = File.join(File.dirname(source_path), "#{File.basename(source_path, '.json')}.log")
      report = { file_path: source_path, log_path: log_full_path, sql_filename: params[:sql_filename].presence,
                 script_id: params[:script_id].presence&.to_i, stats: nil, error_message: nil, first_error_step_label: nil }
      begin
        archive = archive_commit_files(source_path:, file_path: source_path, log_full_path:)
        report.merge!(commit_success: true, commit_state: 'committed', season_id: archive[:season_id], done_dir: archive[:done_dir])
        record_archive_event(source_path:, season_id: archive[:season_id], error: nil)
      rescue StandardError => e
        error = "#{e.class}: #{e.message}"
        season_id = Outbox.season_id_for(File.basename(File.dirname(source_path)))
        report.merge!(commit_success: false, commit_state: 'committed_archive_failed', archive_error: error, season_id:)
        record_archive_event(source_path:, season_id:, error:)
      end
      session[:commit_report] = report
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
      @commit_state = report_data[:commit_state].presence || (@commit_success ? 'committed' : 'failed')
      @archive_error = report_data[:archive_error]
      @outbox_script = Ops.safely { Ops::SqlScript.find_by(id: report_data[:script_id]) if report_data[:script_id] && Ops.available? }
      @post_commit_checks = DataFix::PostCommitChecks.build_post_commit_checks_report(@season_id) if @commit_success && @season_id.present?

      # Render the report view
      render 'data_fix/commit_phase6_report'
    end

    private

    # Registers the commit SQL script in the Outbox (called inside the local transaction, see Main#commit_all):
    # results.new/<season folder>/NNNN-<source base>.sql, under the data root of the source.
    def write_commit_script(source_path:, sql:, committer:)
      Outbox::Writer.write!(
        kind: 'commit', name: File.basename(source_path, '.json'), sql:, folder: File.basename(File.dirname(source_path)),
        data_root: Outbox.data_root_for(source_path),
        origin: { 'producer' => 'data_fix.commit', 'source_base' => File.basename(source_path, '.json').delete_suffix('-lt4'),
                  'source_file' => File.basename(source_path), 'meeting_id' => committer.meeting_id,
                  'fin_event_id' => source_fin_event_id(source_path), 'actor_user_id' => current_user&.id }.compact
      )
    end

    # FIN event id of the source file (top-level meetingURL / manifestURL), or nil. Never raises.
    def source_fin_event_id(source_path)
      data = source_resolver.parsed_source_json(source_path)
      FINEventId.parse_any(data['meetingURL'], data['manifestURL'])
    rescue StandardError
      nil
    end

    # Moves the source + phase files to results.done/ etc. (see DataFix::CommitArchiver).
    def archive_commit_files(source_path:, file_path:, log_full_path:)
      DataFix::CommitArchiver.finalize(
        source_path: source_path,
        lt2_source_path: file_path.gsub('-lt4.json', '.json'),
        phase1_path: source_resolver.default_phase_path_for(source_path, 1),
        phase_paths: (1..5).map { |phase| source_resolver.default_phase_path_for(source_path, phase) },
        log_full_path: log_full_path
      )
    end

    # A retry is allowed only for a JSON source path under a results.new folder.
    def retryable_source?(source_path)
      source_path.end_with?('.json') && File.expand_path(source_path, Rails.root).include?("/#{Outbox::NEW_DIR}/")
    end

    # Suggested step to review from the first logged validation error (best effort, never raises).
    def first_error_step_label_for(committer)
      return unless committer.respond_to?(:logger) && committer.logger.respond_to?(:entries)

      first_error_entry = Array(committer.logger.entries).find { |entry| entry[:level] == :error }
      return unless first_error_entry

      step = PHASE_HINTS[first_error_entry[:entity_type].to_s]
      STEP_LABELS[step] if step
    rescue StandardError
      nil
    end

    PHASE_HINTS = {
      'Meeting' => 1, 'Calendar' => 1, 'City' => 1, 'SwimmingPool' => 1, 'MeetingSession' => 1,
      'Team' => 2, 'TeamAffiliation' => 2, 'Swimmer' => 3, 'Badge' => 3, 'MeetingEvent' => 4,
      'MeetingProgram' => 5, 'MeetingIndividualResult' => 5, 'MeetingRelayResult' => 5, 'MeetingRelaySwimmer' => 5,
      'Lap' => 5, 'RelayLap' => 5
    }.freeze
    STEP_LABELS = {
      1 => 'Step 1 • Sessions / Meeting', 2 => 'Step 2 • Teams', 3 => 'Step 3 • Swimmers',
      4 => 'Step 4 • Events', 5 => 'Step 5 • Results'
    }.freeze
    private_constant :PHASE_HINTS, :STEP_LABELS

    # Appends 'datafix.committed' / 'datafix.archive_failed' / 'datafix.commit_failed' to the ops log (never raises).
    def record_commit_event(source_path:, sql_filename:, commit_state:, season_id:, error_message:, stats:)
      Ops.safely do
        first_error = error_message || Array(stats&.dig(:errors)).first
        kind, level = { 'committed' => %w[datafix.committed success],
                        'committed_archive_failed' => %w[datafix.archive_failed warning] }
                      .fetch(commit_state, %w[datafix.commit_failed error])
        Ops.record_event!(
          kind:, level:, actor: 'operator',
          season_id: season_id || Integer(File.basename(File.dirname(source_path.to_s)), exception: false),
          subject_type: 'source',
          subject_key: source_path.to_s,
          data: { 'sql_filename' => sql_filename, 'first_error' => first_error&.to_s&.truncate(500) }.compact,
          link_path: commit_state == 'failed' ? nil : outbox_path(focus: sql_filename)
        )
      end
    end

    # Appends 'datafix.archived' (retry succeeded) or 'datafix.archive_failed' to the ops log (never raises).
    def record_archive_event(source_path:, season_id:, error:)
      Ops.record_event!(
        kind: error ? 'datafix.archive_failed' : 'datafix.archived', level: error ? 'warning' : 'success',
        actor: 'operator', season_id:, subject_type: 'source', subject_key: source_path.to_s,
        data: { 'error' => error&.truncate(500) }.compact
      )
    end

    # (phase 06) After a local commit, queues the read-only data health checks of every group of the season
    # (trigger 'post_commit', 'maintenance' worker). The synchronous post-commit checks of the report stay as they are.
    # Never fails the commit flow.
    def enqueue_health_runs(season_id:, commit_state:)
      return unless season_id.present? && commit_state.to_s.start_with?('committed')

      Health::SeasonRunJob.enqueue_season(season_id: season_id.to_i, trigger: 'post_commit')
    rescue StandardError => e
      Rails.logger.error("[Phase 6 Commit] health runs not queued: #{e.class}: #{e.message}")
    end
  end
end
