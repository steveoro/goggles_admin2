# frozen_string_literal: true

module DataFix
  # ResultsController: Phase 5 (results) review, per-row overwrite metadata and result verification endpoints.
  class ResultsController < BaseController
    def review_results
      source_path = @source_path
      phase_path = pipeline.phase_path(5)

      # Build/rebuild phase 5 (staging rows + program list) when missing, on rescan, or when stale without edits
      return unless ensure_phase_file!(phase: 5, review_path: method(:review_results_path))

      @retry_needed = pipeline.settle!(5)

      # Load phase5 JSON with program groups
      if File.exist?(phase_path)
        phase5_json = JSON.parse(File.read(phase_path))
        overwrite_meta = phase5_json.dig('_meta', 'individual_result_overwrite')
        overwrite_meta = {} unless overwrite_meta.is_a?(Hash)
        overwrite_snapshot = overwrite_meta['snapshot']
        overwrite_snapshot = {} unless overwrite_snapshot.is_a?(Hash)
        @overwrite_existing_results = overwrite_meta['enabled'] == true
        @overwrite_candidates = if @overwrite_existing_results
                                  Array(overwrite_snapshot['candidates'])
                                else
                                  []
                                end
        @overwrite_selected_count = @overwrite_candidates.count { |candidate| candidate['selected'] == true }
        @overwrite_merge_count = @overwrite_candidates.count { |candidate| candidate['selected'] == true && candidate['merge'] == true }
        @overwrite_candidates_by_program_key = @overwrite_candidates.group_by do |candidate|
          [candidate['session_order'], candidate['event_code'], candidate['category_code'], candidate['gender_code']].join('-')
        end
        @phase5_meta = {
          'name' => phase5_json['name'],
          'source_file' => phase5_json['source_file'],
          'retry_needed' => @retry_needed,
          'individual_result_overwrite' => overwrite_meta
        }
        all_programs = phase5_json['programs'] || []
        existing_program_keys = all_programs.to_set do |program|
          [program['session_order'], program['event_code'], program['category_code'], program['gender_code']].join('-')
        end
        @overwrite_candidates_by_program_key.each do |program_key, candidates|
          next if existing_program_keys.include?(program_key)

          candidate = candidates.first
          all_programs << {
            'session_order' => candidate['session_order'],
            'event_key' => candidate['event_code'],
            'event_code' => candidate['event_code'],
            'category_code' => candidate['category_code'],
            'gender_code' => candidate['gender_code'],
            'relay' => false,
            'result_count' => 0,
            'deletion_count' => candidates.size
          }
        end
        @total_programs_count = all_programs.size # Track unfiltered count

        # Load all staging rows once: issue detection, filters, pagination counts
        # and the view all reuse these buckets instead of per-program LIKE queries.
        staging = DataFix::StagingRows.load_staging_rows(source_path)

        phase1_path = pipeline.phase_path(1)
        phase3_path = pipeline.phase_path(3)
        phase1_data = File.exist?(phase1_path) ? JSON.parse(File.read(phase1_path))['data'] || {} : {}
        phase3_data = File.exist?(phase3_path) ? JSON.parse(File.read(phase3_path))['data'] || {} : {}
        @result_outcome_planner = DataFix::ResultOutcomePlanner.new(
          source_path:,
          meeting_id: phase1_data['id'] || phase1_data['meeting_id'],
          season_id: pipeline.season&.id,
          overwrite_enabled: @overwrite_existing_results,
          overwrite_candidates: @overwrite_candidates,
          badge_rows: phase3_data['badges'] || []
        )
        @result_outcome_counts = @result_outcome_planner.counts
        @result_outcome_warnings = @result_outcome_planner.warnings

        # ALWAYS run server-side issue detection BEFORE pagination
        # This ensures we know about issues regardless of filtering or pagination
        filter_data = DataFix::IssueDetector.load_filter_data(source_path, staging)
        @programs_with_issues = DataFix::IssueDetector.detect_programs_with_issues(all_programs, filter_data, staging)
        @issue_count = @programs_with_issues.size
        # (phase 12) issue markers of the program cards: next/previous issue navigation
        @issue_program_keys = @programs_with_issues.to_set { |program| program_key_for(program) }

        # Server-side filtering: only show programs with issues if filter is active.
        # An explicit filter_issues param always wins; when absent, the filter
        # auto-activates on first render whenever issues are detected (the
        # operator can still toggle it off with filter_issues=0).
        @filter_active = params[:filter_issues].present? ? params[:filter_issues] == '1' : @issue_count.positive?
        all_programs = @programs_with_issues if @filter_active && @issue_count.positive?

        # Filter to show only programs with any new (will-be-created) rows:
        # unmatched parent MIR/MRR OR matched parents that have new child rows (laps, MRS, relay_laps)
        @filter_new_active = params[:filter_new] == '1'
        if @filter_new_active
          all_programs = all_programs.select do |prog|
            program_key = "#{prog['session_order']}-#{prog['event_code']}-#{prog['category_code']}-#{prog['gender_code']}"
            if prog['relay']
              (staging[:mrrs_by_program][program_key] || []).any? { |row| row.meeting_relay_result_id.nil? } ||
                (staging[:relay_swimmers_by_program][program_key] || []).any? { |row| row.meeting_relay_swimmer_id.nil? } ||
                (staging[:relay_laps_by_program][program_key] || []).any? { |row| row.relay_lap_id.nil? }
            else
              (staging[:mirs_by_program][program_key] || []).any? { |row| row.meeting_individual_result_id.nil? } ||
                (staging[:laps_by_program][program_key] || []).any? { |row| row.lap_id.nil? }
            end
          end
        end

        # Filter to show only programs with unmatched parent result rows (MIR/MRR with nil matched ID)
        # This is stricter than filter_new: ignores child rows (laps, MRS, relay_laps)
        @filter_unmatched_active = params[:filter_unmatched] == '1'
        if @filter_unmatched_active
          all_programs = all_programs.select do |prog|
            program_key = "#{prog['session_order']}-#{prog['event_code']}-#{prog['category_code']}-#{prog['gender_code']}"
            if prog['relay']
              (staging[:mrrs_by_program][program_key] || []).any? { |row| row.meeting_relay_result_id.nil? }
            else
              (staging[:mirs_by_program][program_key] || []).any? { |row| row.meeting_individual_result_id.nil? }
            end
          end
        end

        # Count new results for summary display
        @new_result_count = staging[:mirs].count { |row| row.meeting_individual_result_id.nil? } +
                            staging[:mrrs].count { |row| row.meeting_relay_result_id.nil? }

        # Count unmatched parent results (for the (+) filter banner)
        @unmatched_parent_count = @new_result_count

        # Sort programs by event order from phase4 (individual events first, then relays)
        phase4_path = source_resolver.default_phase_path_for(source_path, 4)
        all_programs = Phase5::Paginator.sort_by_event_order(all_programs, phase4_path)

        # Apply pagination to prevent UI slowdown
        @current_page = [params[:page].to_i, 1].max
        @phase5_programs, @total_pages = Phase5::Paginator.paginate(all_programs, @current_page, staging)
        @issue_nav = results_issue_nav(all_programs, staging)
      else
        @phase5_meta = {}
        @phase5_programs = []
        @total_programs_count = 0
        @current_page = 1
        @total_pages = 1
      end

      # Populate data_import_* tables for detailed review (triggered by populate_db only)
      if params[:populate_db].present?
        # (an explicit operator rebuild of phase 5: same recipe as the build, through the pipeline)
        broadcast_progress('Populating DB from phase 5 data...', 0, 100)
        pipeline.build_phase!(5, force: true, strict_upstream: false)
        @populate_stats = pipeline.last_build_result[:stats]
        flash.now[:info] = I18n.t('data_fix.flash.populated', results: @populate_stats[:mir_created], laps: @populate_stats[:laps_created],
                                                              relay_results: @populate_stats[:relay_results_created],
                                                              relay_swimmers: @populate_stats[:relay_swimmers_created],
                                                              relay_laps: @populate_stats[:relay_laps_created],
                                                              programs: @populate_stats[:programs_matched])

        # populate! rewrote the staging tables: reload before rendering
        staging = DataFix::StagingRows.load_staging_rows(source_path)
      end

      @issue_program_keys ||= Set.new
      # Query data_import tables for display (loaded once, reused per program bucket)
      staging ||= DataFix::StagingRows.load_staging_rows(source_path)
      @mirs_by_program = staging[:mirs_by_program]
      @mrrs_by_program = staging[:mrrs_by_program]
      @all_results = staging[:mirs]

      # Also check for relay results to determine if commit button should be visible
      @has_relay_results = staging[:mrrs].any?

      # Result-free sources (e.g. manifest-only files) can still commit the bare
      # meeting structure: in that case the commit gate requires a valid meeting
      # with valid sessions instead of staged result rows. When staging rows are
      # already present the source is treated as result-bearing and the regular
      # results review UI is rendered.
      @result_free = source_resolver.source_result_free?(source_path) && staging[:mirs].empty? && staging[:mrrs].empty?
      if @result_free
        phase1_path = source_resolver.default_phase_path_for(source_path, 1)
        phase1_data = File.exist?(phase1_path) ? PhaseFileManager.new(phase1_path).data : {}
        @structure_report = Import::StructureValidator.new(phase1_data: phase1_data)
        @structure_errors = @structure_report.error_messages
      end

      # Eager-load swimmers and teams to avoid N+1 queries
      # NOTE: Load ALL swimmer/team IDs from source file, not just from @all_results (which is limited)
      # This ensures the view can find swimmers for any program displayed via pagination
      swimmer_ids = staging[:mirs].filter_map(&:swimmer_id).uniq
      team_ids = staging[:mirs].filter_map(&:team_id).uniq
      @swimmers_by_id = GogglesDb::Swimmer.where(id: swimmer_ids).index_by(&:id)
      @teams_by_id = GogglesDb::Team.includes(:city).where(id: team_ids).index_by(&:id)

      # Load phase 2 and phase 3 data for team/badge lookup by key
      phase2_path = source_resolver.default_phase_path_for(source_path, 2)
      phase3_path = source_resolver.default_phase_path_for(source_path, 3)
      @phase2_data = JSON.parse(File.read(phase2_path)) if File.exist?(phase2_path)
      @phase3_data = JSON.parse(File.read(phase3_path)) if File.exist?(phase3_path)

      # Build team lookup by key (for unmatched teams)
      if @phase2_data
        teams = @phase2_data.dig('data', 'teams') || []
        @teams_by_key = teams.index_by { |t| t['key'] }
      end

      # Build badge/team key mapping: swimmer_key => team_key
      # Also index by partial key (without gender) for flexible lookup
      if @phase3_data
        badges = @phase3_data.dig('data', 'badges') || []
        @team_key_by_swimmer_key = badges.each_with_object({}) do |badge, hash|
          swimmer_key = badge['swimmer_key']
          team_key = badge['team_key']
          # Index by full key
          hash[swimmer_key] = team_key
          # Also index by partial key (gender stripped, team preserved)
          partial_key = DataFix::SwimmerKey.normalize_swimmer_key_for_lookup(swimmer_key)
          next unless partial_key

          # Store both with and without leading pipe for flexible lookup
          hash[partial_key] = team_key
          hash[partial_key.sub(/^\|/, '')] = team_key # Without leading pipe
        end

        swimmers = @phase3_data.dig('data', 'swimmers') || []
        @swimmers_by_key = swimmers.index_by { |s| s['key'] }
      end

      # Eager-load laps for ALL individual results in this source file
      @laps_by_parent_key = staging[:laps].group_by(&:parent_import_key)

      # All relay results for display (relay swimmers need all parent keys)
      @all_relay_results = staging[:mrrs]

      # Eager-load relay teams (add to existing team query)
      relay_team_ids = @all_relay_results.filter_map(&:team_id).uniq
      additional_teams = GogglesDb::Team.includes(:city).where(id: relay_team_ids - team_ids).index_by(&:id)
      @teams_by_id.merge!(additional_teams)

      # Eager-load relay swimmers and laps for ALL relay results in this source file
      @relay_swimmers_by_parent_key = staging[:relay_swimmers].group_by(&:parent_import_key)
      @relay_laps_by_parent_key = staging[:relay_laps].group_by(&:parent_import_key)

      # Build swimmer lookup for relay swimmers (add to existing swimmer query if needed)
      relay_swimmer_ids = @relay_swimmers_by_parent_key.values.flatten.filter_map(&:swimmer_id).uniq
      additional_swimmers = GogglesDb::Swimmer.where(id: relay_swimmer_ids - swimmer_ids).index_by(&:id)
      @swimmers_by_id.merge!(additional_swimmers)

      # Build relay swimmer name lookup from source data for unmatched swimmers
      # Maps: {mrr_import_key => {relay_order => {name, key}}}
      relay_import_keys = @all_relay_results.to_set(&:import_key)
      @relay_swimmer_names = DataFix::RelayNamesBuilder.new(source_resolver).build_from_source(source_path, relay_import_keys)
    end

    # Toggle the opt-in Phase 5 individual-result overwrite reconciliation.
    def toggle_individual_result_overwrite
      file_path = @file_path
      source_path = @source_path
      phase5_path = source_resolver.default_phase_path_for(source_path, 5)
      phase1_path = source_resolver.default_phase_path_for(source_path, 1)
      unless File.exist?(phase5_path) && File.exist?(phase1_path)
        redirect_to(review_results_path(file_path: source_path, phase5_v2: 1),
                    alert: I18n.t('data_import.data_fix.individual_result_overwrite_phases_missing')) && return
      end

      payload = JSON.parse(File.read(phase5_path))
      phase_meta = payload['_meta'] = payload['_meta'].is_a?(Hash) ? payload['_meta'] : {}
      enabled = ActiveModel::Type::Boolean.new.cast(params[:enabled])

      if enabled
        phase1_data = PhaseFileManager.new(phase1_path).data
        meeting_id = phase1_data['id'] || phase1_data['meeting_id']
        import_rows = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).to_a
        candidates = DataFix::IndividualResultOverwriteReconciler.new(
          meeting_id: meeting_id,
          import_rows: import_rows
        ).discover
        phase_meta['individual_result_overwrite'] = {
          'enabled' => true,
          'snapshot' => DataFix::IndividualResultOverwriteReconciler.snapshot(candidates)
        }
        notice = I18n.t('data_import.data_fix.individual_result_overwrite_enabled', count: candidates.size)
      else
        phase_meta['individual_result_overwrite'] = {
          'enabled' => false,
          'snapshot' => DataFix::IndividualResultOverwriteReconciler.snapshot([])
        }
        notice = I18n.t('data_import.data_fix.individual_result_overwrite_disabled')
      end

      File.write(phase5_path, JSON.pretty_generate(payload))
      redirect_to(review_results_path(file_path: source_path, phase5_v2: 1), notice: notice)
    rescue JSON::ParserError => e
      redirect_to(review_results_path(file_path: file_path, phase5_v2: 1), alert: "Invalid Phase 5 metadata: #{e.message}")
    end

    def update_individual_result_overwrite_candidate
      phase5_path = DataFix::OverwriteMetadata.overwrite_phase5_path_for(params[:file_path])
      @edited_source_path = edited_source_for(phase5_path)
      payload, overwrite = DataFix::OverwriteMetadata.read_overwrite_metadata!(phase5_path)
      raise ArgumentError, 'Individual-result overwrite mode is disabled' unless overwrite['enabled'] == true

      snapshot = DataFix::IndividualResultOverwriteReconciler.update_selection(
        snapshot: overwrite['snapshot'],
        candidate_id: params[:candidate_id],
        selected: params[:selected]
      )
      overwrite['snapshot'] = snapshot
      DataFix::OverwriteMetadata.write_phase5_payload!(phase5_path, payload)
      candidate = snapshot['candidates'].find { |entry| entry['id'].to_i == params[:candidate_id].to_i }
      render json: DataFix::OverwriteMetadata.overwrite_counts(snapshot).merge(success: true, candidate_id: params[:candidate_id].to_i,
                                                                               selected: candidate['selected'],
                                                                               merge: candidate['merge'])
    rescue ArgumentError => e
      render json: { success: false, error: e.message }, status: :unprocessable_content
    rescue JSON::ParserError => e
      render json: { success: false, error: "Invalid Phase 5 metadata: #{e.message}" }, status: :unprocessable_content
    end

    def update_individual_result_merge_candidate
      phase5_path = DataFix::OverwriteMetadata.overwrite_phase5_path_for(params[:file_path])
      @edited_source_path = edited_source_for(phase5_path)
      payload, overwrite = DataFix::OverwriteMetadata.read_overwrite_metadata!(phase5_path)
      raise ArgumentError, 'Individual-result overwrite mode is disabled' unless overwrite['enabled'] == true

      snapshot = DataFix::IndividualResultOverwriteReconciler.update_merge_selection(
        snapshot: overwrite['snapshot'],
        candidate_id: params[:candidate_id],
        merge: params[:merge]
      )
      overwrite['snapshot'] = snapshot
      DataFix::OverwriteMetadata.write_phase5_payload!(phase5_path, payload)
      candidate = snapshot['candidates'].find { |entry| entry['id'].to_i == params[:candidate_id].to_i }
      render json: DataFix::OverwriteMetadata.overwrite_counts(snapshot).merge(
        success: true,
        candidate_id: params[:candidate_id].to_i,
        merge: candidate['merge']
      )
    rescue ArgumentError => e
      render json: { success: false, error: e.message }, status: :unprocessable_content
    rescue JSON::ParserError => e
      render json: { success: false, error: "Invalid Phase 5 metadata: #{e.message}" }, status: :unprocessable_content
    end

    def bulk_update_individual_result_overwrite
      phase5_path = DataFix::OverwriteMetadata.overwrite_phase5_path_for(params[:file_path])
      @edited_source_path = edited_source_for(phase5_path)
      payload, overwrite = DataFix::OverwriteMetadata.read_overwrite_metadata!(phase5_path)
      raise ArgumentError, 'Individual-result overwrite mode is disabled' unless overwrite['enabled'] == true

      snapshot = overwrite['snapshot']
      DataFix::IndividualResultOverwriteReconciler.validate_snapshot_shape!(snapshot)
      operation = params[:operation].to_s
      candidates = Array(snapshot['candidates'])
      case operation
      when 'select_all'
        candidates.each do |candidate|
          candidate['selected'] = true
          candidate['merge'] = DataFix::IndividualResultOverwriteReconciler.default_merge?(candidate)
        end
      when 'deselect_all'
        candidates.each do |candidate|
          candidate['selected'] = false
          candidate['merge'] = false
        end
      when 'deselect_zero_timing'
        candidates.each do |candidate|
          next unless candidate['minutes'].to_i.zero? && candidate['seconds'].to_i.zero? && candidate['hundredths'].to_i.zero?

          candidate['selected'] = false
          candidate['merge'] = false
        end
      else
        raise ArgumentError, "Unknown overwrite selection operation: #{operation}"
      end

      overwrite['snapshot'] = snapshot
      DataFix::OverwriteMetadata.write_phase5_payload!(phase5_path, payload)
      render json: DataFix::OverwriteMetadata.overwrite_counts(snapshot).merge(success: true)
    rescue ArgumentError => e
      render json: { success: false, error: e.message }, status: :unprocessable_content
    rescue JSON::ParserError => e
      render json: { success: false, error: "Invalid Phase 5 metadata: #{e.message}" }, status: :unprocessable_content
    end

    # AJAX endpoint: verify if a result already exists in the DB (duplicate detection).
    # For individual results, uses 4-tier classification (perfect/partial/team_mismatch/other_events).
    # If a perfect match is found, auto-fixes the import row immediately.
    # Returns JSON with match info and swimmer's other badges in the season.
    def verify_result
      import_key = params[:import_key]
      result_type = params[:result_type] || 'individual' # 'individual' or 'relay'

      checker = Import::Verification::ResultDuplicateChecker.new

      if result_type == 'relay'
        data_import_row = scoped_import_row(GogglesDb::DataImportMeetingRelayResult, import_key)
        unless data_import_row
          render json: { error: 'Result not found' }, status: :not_found
          return
        end

        result = checker.check_relay(
          meeting_program_id: data_import_row.meeting_program_id,
          team_id: data_import_row.team_id,
          timing: { minutes: data_import_row.minutes, seconds: data_import_row.seconds,
                    hundredths: data_import_row.hundredths }
        )
      else
        data_import_row = scoped_import_row(GogglesDb::DataImportMeetingIndividualResult, import_key)
        unless data_import_row
          render json: { error: 'Result not found' }, status: :not_found
          return
        end

        merge_source = DataFix::OverwriteMetadata.merge_target_for(data_import_row)
        source_path = data_import_row.phase_file_path
        season_id = source_resolver.detect_season_from_pathname(source_path)&.id if source_path.present?
        if merge_source
          result = DataFix::ResultVerifier.new(source_path:, season_id:, checker:)
                                          .verify_row(data_import_row, merge_target: true)
          result[:merge_target] = true
          result[:merge_source_mir_id] = merge_source['id']
          result[:merge_message] = I18n.t('data_import.data_fix.merge_target_no_autofix', mir_id: merge_source['id'])
        else
          # Auto-fix: if exactly 1 perfect match found, apply it immediately (DataFix::ResultVerifier)
          result = DataFix::ResultVerifier.new(source_path:, season_id:, checker:)
                                          .verify_row(data_import_row, merge_target: false)
        end
      end

      render json: result
    end

    # POST data_fix/verify_all_results?file_path= ("Verify all" of Step 5, phase 12): matches every unmatched staged
    # individual result having exactly one perfect duplicate in the DB (DataFix::ResultVerifier, also run after each
    # Phase 5 populate; never touches a merge target, never commits), then reopens Step 5 with its filters and the
    # counts (fixed, partial = possible duplicates left to review, none). The program cards are rendered again.
    def verify_all_results
      message = I18n.t('data_fix.verify_all.progress')
      progress_sink.call(message, 0, 1) # (at once: the season lookup comes first)
      outcome = DataFix::ResultVerifier.new(source_path: @source_path, season_id: pipeline.season&.id)
                                       .verify_all!(progress: progress_sink, message:)
      kept = params.slice(:filter_issues, :filter_new, :filter_unmatched, :page).permit!.to_h
      back = review_results_path(kept.merge(file_path: @source_path, phase5_v2: 1))
      return redirect_to(back, flash: { error: I18n.t('data_fix.verify_all.failed', error: outcome['error']) }) if outcome['error'].present?

      checked = outcome['checked'].to_i
      fixed = outcome['verified'].to_i
      partial = Array(outcome['partial']).size
      redirect_to(back, notice: I18n.t('data_fix.verify_all.done', checked:, fixed:, partial:, none: [checked - fixed - partial, 0].max))
    end

    # Fix a result duplicate: set the existing DB row's ID on the DataImport* record.
    #
    # Supports two modes via params[:mode]:
    #   - "overwrite" (default): overwrite ALL fields from existing DB row → zero-diff on commit.
    #   - "keep_timing": set existing ID + copy association IDs (meeting_program_id, swimmer_id,
    #     team_id, badge_id) from the existing row, but KEEP the import row's timing/rank/points.
    #     Phase 6 will then UPDATE the existing row with the import's timing.
    def confirm_result_duplicate
      import_key = params[:import_key]
      existing_id = params[:existing_id].to_i
      result_type = params[:result_type] || 'individual'
      mode = params[:mode] || 'overwrite' # 'overwrite' or 'keep_timing'

      unless existing_id.positive? && import_key.present?
        render json: { error: 'Missing required params' }, status: :unprocessable_content
        return
      end

      edited_model = result_type == 'relay' ? GogglesDb::DataImportMeetingRelayResult : GogglesDb::DataImportMeetingIndividualResult
      @edited_source_path = scoped_import_row(edited_model, import_key)&.phase_file_path
      if result_type != 'relay'
        data_import_row = scoped_import_row(GogglesDb::DataImportMeetingIndividualResult, import_key)
        merge_source = DataFix::OverwriteMetadata.merge_target_for(data_import_row)
        if merge_source
          render json: { error: I18n.t('data_import.data_fix.merge_target_no_manual_fix', mir_id: merge_source['id']) },
                 status: :unprocessable_content
          return
        end
      end

      if result_type == 'relay'
        data_import_row = scoped_import_row(GogglesDb::DataImportMeetingRelayResult, import_key)
        existing = GogglesDb::MeetingRelayResult.find_by(id: existing_id)
        unless data_import_row && existing
          render json: { error: 'Record not found' }, status: :not_found
          return
        end

        if mode == 'keep_timing'
          data_import_row.update!(
            meeting_relay_result_id: existing.id,
            meeting_program_id: existing.meeting_program_id,
            team_id: existing.team_id,
            team_affiliation_id: existing.team_affiliation_id
          )
        else
          data_import_row.update!(
            meeting_relay_result_id: existing.id,
            meeting_program_id: existing.meeting_program_id,
            team_id: existing.team_id,
            team_affiliation_id: existing.team_affiliation_id,
            rank: existing.rank,
            minutes: existing.minutes,
            seconds: existing.seconds,
            hundredths: existing.hundredths,
            disqualified: existing.disqualified
          )
        end
      else
        data_import_row = scoped_import_row(GogglesDb::DataImportMeetingIndividualResult, import_key)
        existing = GogglesDb::MeetingIndividualResult.find_by(id: existing_id)
        unless data_import_row && existing
          render json: { error: 'Record not found' }, status: :not_found
          return
        end

        wrong_program = if data_import_row.meeting_program_id.to_i.positive?
                          existing.meeting_program_id.to_i != data_import_row.meeting_program_id.to_i
                        else
                          data_import_row.meeting_program_key.present? &&
                            meeting_program_key_for_model(existing.meeting_program) != data_import_row.meeting_program_key.to_s
                        end
        if wrong_program
          render json: { error: I18n.t('data_import.data_fix.duplicate_wrong_program_rejected') }, status: :unprocessable_content
          return
        end

        if mode == 'keep_timing'
          data_import_row.update!(
            meeting_individual_result_id: existing.id,
            meeting_program_id: existing.meeting_program_id,
            swimmer_id: existing.swimmer_id,
            team_id: existing.team_id,
            badge_id: existing.badge_id
          )
        else
          data_import_row.update!(
            meeting_individual_result_id: existing.id,
            meeting_program_id: existing.meeting_program_id,
            swimmer_id: existing.swimmer_id,
            team_id: existing.team_id,
            badge_id: existing.badge_id,
            rank: existing.rank,
            minutes: existing.minutes,
            seconds: existing.seconds,
            hundredths: existing.hundredths,
            disqualified: existing.disqualified,
            standard_points: existing.standard_points,
            meeting_points: existing.meeting_points,
            goggle_cup_points: existing.goggle_cup_points
          )
        end
      end

      render json: { success: true, import_key: import_key, existing_id: existing_id, mode: mode }
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def scoped_import_row(model_class, import_key)
      scope = model_class.where(import_key:)
      if params[:file_path].present?
        source_path = source_resolver.resolve_working_source_path(params[:file_path])
        scope = scope.where(phase_file_path: source_path)
      end
      scope.first
    end

    def meeting_program_key_for_model(program)
      event = program&.meeting_event
      [
        event&.meeting_session&.session_order,
        event&.event_type&.code,
        program&.category_type&.code,
        program&.gender_type&.code
      ].compact.join('-')
    end

    def program_key_for(program)
      "#{program['session_order']}-#{program['event_code']}-#{program['category_code']}-#{program['gender_code']}"
    end

    # Next/previous issue across the Phase 5 pages (Phase5::Paginator splits them by row count): the issue programs
    # per page, then the nearest page holding one, opened on its first / last issue card.
    def results_issue_nav(all_programs, staging)
      counts = if @total_pages.to_i > 1
                 (1..@total_pages).map do |page|
                   Phase5::Paginator.paginate(all_programs, page, staging).first.count { |program| @issue_program_keys.include?(program_key_for(program)) }
                 end
               else
                 [@phase5_programs.count { |program| @issue_program_keys.include?(program_key_for(program)) }]
               end
      DataFix::IssueNav.for_pages(counts, page: @current_page) do |page, edge|
        review_results_path(request.query_parameters.merge(file_path: @file_path, phase5_v2: 1, page:, anchor: "issue-#{edge}"))
      end
    end

    # Source path of a Phase 5 file (for the edit marker of the JSON overwrite endpoints).
    def edited_source_for(phase5_path)
      phase5_path.to_s.sub(/-phase5\.json\z/, '.json')
    end
  end
end
