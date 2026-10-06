# frozen_string_literal: true

module DataFix
  # ResultsController: Phase 5 (results) review, per-row overwrite metadata and result verification endpoints.
  class ResultsController < BaseController

    def review_results
      return if params[:phase5_v2].blank?

      source_path = @source_path
      season = source_resolver.detect_season_from_pathname(source_path)
      lt_format = source_resolver.detect_layout_type(source_path)
      phase_path = source_resolver.default_phase_path_for(source_path, 5)

      # Build/rebuild phase 5 JSON scaffold (for summary display)
      return unless ensure_phase_file!(phase_path: phase_path, phase: 5,
                                       review_path: method(:review_results_path)) do
        Import::Solvers::ResultSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )

        # Populate data_import_* tables immediately after rescan (before redirect)
        populator = Import::Phase5Populator.new(
          source_path: source_path,
          phase1_path: source_resolver.default_phase_path_for(source_path, 1),
          phase2_path: source_resolver.default_phase_path_for(source_path, 2),
          phase3_path: source_resolver.default_phase_path_for(source_path, 3),
          phase4_path: source_resolver.default_phase_path_for(source_path, 4)
        )
        broadcast_progress('Populating phase 5...', 0, 100)
        populate_stats = populator.populate!
        "Phase 5 rebuilt. Populated DB: #{populate_stats[:mir_created]} results, #{populate_stats[:laps_created]} laps"
      end

      @retry_needed = source_resolver.sync_phase_retry_flag!(phase_path: phase_path, source_path: source_path)

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

        # ALWAYS run server-side issue detection BEFORE pagination
        # This ensures we know about issues regardless of filtering or pagination
        filter_data = DataFix::IssueDetector.load_filter_data(source_path, staging)
        @programs_with_issues = DataFix::IssueDetector.detect_programs_with_issues(all_programs, filter_data, staging)
        @issue_count = @programs_with_issues.size

        # Server-side filtering: only show programs with issues if filter is active
        # Auto-activate filter if there are issues and no explicit filter param
        @filter_active = params[:filter_issues] == '1' || (@issue_count.positive? && !params[:filter_issues].to_i.zero?)
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
      else
        @phase5_meta = {}
        @phase5_programs = []
        @total_programs_count = 0
        @current_page = 1
        @total_pages = 1
      end

      # Populate data_import_* tables for detailed review (triggered by populate_db only)
      if params[:populate_db].present?
        phase1_path = source_resolver.default_phase_path_for(source_path, 1)
        phase2_path = source_resolver.default_phase_path_for(source_path, 2)
        phase3_path = source_resolver.default_phase_path_for(source_path, 3)
        phase4_path = source_resolver.default_phase_path_for(source_path, 4)

        populator = Import::Phase5Populator.new(
          source_path: source_path,
          phase1_path: phase1_path,
          phase2_path: phase2_path,
          phase3_path: phase3_path,
          phase4_path: phase4_path
        )
        broadcast_progress('Populating DB from phase 5 data...', 0, 100)
        @populate_stats = populator.populate!
        flash.now[:info] =
          "Populated DB: #{@populate_stats[:mir_created]} results, #{@populate_stats[:laps_created]} laps, " \
          "#{@populate_stats[:relay_results_created]} relay results, #{@populate_stats[:relay_swimmers_created]} relay swimmers, " \
          "#{@populate_stats[:relay_laps_created]} relay laps, #{@populate_stats[:programs_matched]} programs matched"

        # populate! rewrote the staging tables: reload before rendering
        staging = DataFix::StagingRows.load_staging_rows(source_path)
      end

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

      # Broadcast ready status to clear progress modal
      broadcast_progress('Review results: ready', 100, 100)
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
        data_import_row = GogglesDb::DataImportMeetingRelayResult.find_by(import_key: import_key)
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
        data_import_row = GogglesDb::DataImportMeetingIndividualResult.find_by(import_key: import_key)
        unless data_import_row
          render json: { error: 'Result not found' }, status: :not_found
          return
        end

        merge_source = DataFix::OverwriteMetadata.merge_target_for(data_import_row)
        if merge_source
          result = checker.check_individual(
            swimmer_id: data_import_row.swimmer_id,
            meeting_program_id: data_import_row.meeting_program_id,
            timing: { minutes: data_import_row.minutes, seconds: data_import_row.seconds,
                      hundredths: data_import_row.hundredths },
            team_id: data_import_row.team_id,
            season_id: source_resolver.detect_season_from_pathname(data_import_row.phase_file_path)&.id
          )
          result[:merge_target] = true
          result[:merge_source_mir_id] = merge_source['id']
          result[:merge_message] = I18n.t('data_import.data_fix.merge_target_no_autofix', mir_id: merge_source['id'])
        else
          source_path = data_import_row.phase_file_path
          season_id = source_resolver.detect_season_from_pathname(source_path)&.id if source_path.present?

          result = checker.check_individual(
            swimmer_id: data_import_row.swimmer_id,
            meeting_program_id: data_import_row.meeting_program_id,
            timing: { minutes: data_import_row.minutes, seconds: data_import_row.seconds,
                      hundredths: data_import_row.hundredths },
            team_id: data_import_row.team_id,
            season_id: season_id
          )

          # Auto-fix: if exactly 1 perfect match found, apply it immediately
          if result[:perfect_matches]&.length == 1
            perfect = result[:perfect_matches].first
            existing = GogglesDb::MeetingIndividualResult.find_by(id: perfect['id'])
            if existing
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
              result[:auto_fixed] = true
              result[:auto_fixed_id] = existing.id
            end
          end
        end
      end

      render json: result
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

      if result_type != 'relay'
        data_import_row = GogglesDb::DataImportMeetingIndividualResult.find_by(import_key: import_key)
        merge_source = DataFix::OverwriteMetadata.merge_target_for(data_import_row)
        if merge_source
          render json: { error: I18n.t('data_import.data_fix.merge_target_no_manual_fix', mir_id: merge_source['id']) },
                 status: :unprocessable_content
          return
        end
      end

      if result_type == 'relay'
        data_import_row = GogglesDb::DataImportMeetingRelayResult.find_by(import_key: import_key)
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
        data_import_row = GogglesDb::DataImportMeetingIndividualResult.find_by(import_key: import_key)
        existing = GogglesDb::MeetingIndividualResult.find_by(id: existing_id)
        unless data_import_row && existing
          render json: { error: 'Record not found' }, status: :not_found
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
  end
end
