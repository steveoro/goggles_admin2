# frozen_string_literal: true

require 'date'
require 'pathname'
require 'json'

# = DataFixController: phased pipeline (v2)
#
# Delegates to the new phased solvers when an action-level flag is present; otherwise
# redirects to legacy controller actions to preserve current behavior.
#
class DataFixController < ApplicationController
  before_action :set_api_url

  # rubocop:disable Metrics/AbcSize
  def review_sessions
    if params[:phase_v2].present?
      @file_path = params[:file_path]
      if @file_path.blank?
        flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      source_path = resolve_source_path(@file_path)
      season = detect_season_from_pathname(source_path)
      lt_format = detect_layout_type(source_path)
      # Use existing phase file unless rescan is requested; build when missing or rescan
      phase_path = default_phase_path_for(source_path, 1)
      if params[:rescan].present? || !File.exist?(phase_path)
        phase_path = Import::Solvers::Phase1Solver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )&.dig('path') || phase_path
        # Redirect without rescan parameter to avoid triggering rescan on navigation
        redirect_to(review_sessions_path(request.query_parameters.except(:rescan)),
                    notice: I18n.t('data_import.messages.phase_rebuilt', phase: 1)) && return
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase1_meta = pfm.meta
      @phase1_data = pfm.data

      # Set API URL for AutoComplete components
      set_api_url

      # Fetch existing meeting sessions if meeting_id is present
      meeting_id = @phase1_data['id']
      @existing_meeting_sessions = []
      if meeting_id.present?
        @existing_meeting_sessions = GogglesDb::MeetingSession.where(meeting_id:)
                                                              .includes(:swimming_pool)
                                                              .order(:session_order)
                                                              .map do |ms|
          {
            'id' => ms.id,
            'session_order' => ms.session_order,
            'scheduled_date' => ms.scheduled_date&.to_s,
            'description' => ms.description,
            'day_part_type_id' => ms.day_part_type_id,
            'swimming_pool_id' => ms.swimming_pool_id,
            'swimming_pool_name' => ms.swimming_pool&.name
          }
        end
      end

      return render 'data_fix/review_sessions_v2'
    end

    # Fallback to legacy controller action
    redirect_to controller: 'data_fix_legacy', action: 'review_sessions', params: request.query_parameters
  end
  # rubocop:enable Metrics/AbcSize

  # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/CyclomaticComplexity
  def review_teams
    if params[:phase2_v2].present?
      @file_path = params[:file_path]
      if @file_path.blank?
        flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      source_path = resolve_source_path(@file_path)
      season = detect_season_from_pathname(source_path)
      lt_format = detect_layout_type(source_path)
      phase_path = default_phase_path_for(source_path, 2)
      if params[:rescan].present? || !File.exist?(phase_path)
        Import::Solvers::TeamSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )
        # Redirect without rescan parameter to avoid triggering rescan on navigation
        redirect_to(review_teams_path(request.query_parameters.except(:rescan)),
                    notice: I18n.t('data_import.messages.phase_rebuilt', phase: 2)) && return
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase2_meta = pfm.meta
      @phase2_data = pfm.data

      # Set API URL for AutoComplete components
      set_api_url

      # Optional filtering
      @q = params[:q].to_s.strip
      teams = Array(@phase2_data['teams'])

      # Filter by search query
      if @q.present?
        qd = @q.downcase
        teams = teams.select do |t|
          name = (t['name'] || t['key']).to_s.downcase
          name.include?(qd)
        end
      end

      # Filter unmatched only (no team_id assigned)
      teams = teams.select { |t| t['team_id'].nil? } if params[:unmatched].present?

      # Pagination (phase-specific params to avoid cross-phase interference)
      @page = params[:teams_page].to_i
      @page = 1 if @page < 1
      @per_page = params[:teams_per_page].to_i
      @per_page = 50 if @per_page <= 0 || !params.key?(:teams_per_page)
      @total_count = teams.size
      @total_pages = (@total_count.to_f / @per_page).ceil
      @row_range = "#{(@page * @per_page) - @per_page + 1}-#{@page * @per_page}"
      # Use Kaminari for pagination
      @items = Kaminari.paginate_array(teams, total_count: @total_count).page(@page).per(@per_page)

      # Broadcast ready status to clear progress modal
      broadcast_progress('Review teams: ready', @total_count, @total_count)
      return render 'data_fix/review_teams_v2'
    end

    redirect_to controller: 'data_fix_legacy', action: 'review_teams', params: request.query_parameters
  end

  def review_swimmers
    if params[:phase3_v2].present?
      @file_path = params[:file_path]
      if @file_path.blank?
        flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      source_path = resolve_source_path(@file_path)
      season = detect_season_from_pathname(source_path)
      lt_format = detect_layout_type(source_path)
      phase_path = default_phase_path_for(source_path, 3)
      if params[:rescan].present? || !File.exist?(phase_path)
        phase1_path = default_phase_path_for(source_path, 1)
        phase2_path = default_phase_path_for(source_path, 2)
        Import::Solvers::SwimmerSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format,
          phase1_path: phase1_path,
          phase2_path: phase2_path
        )
        # Redirect without rescan parameter to avoid triggering rescan on navigation
        redirect_to(review_swimmers_path(request.query_parameters.except(:rescan)),
                    notice: I18n.t('data_import.messages.phase_rebuilt', phase: 3)) && return
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase3_meta = pfm.meta
      @phase3_data = pfm.data
      @source_path = source_path
      base_dir = File.dirname(source_path)

      detector = Phase3::RelayEnrichmentDetector.new(
        source_path: source_path,
        phase3_swimmers: @phase3_data.fetch('swimmers', [])
      )
      @relay_enrichment_summary = detector.detect
      @auxiliary_phase3_files = Dir.glob(File.join(base_dir, '*-phase3*.json'))
                                   .reject { |path| path == phase_path }
                                   .sort
      stored_auxiliary = Array(@phase3_meta['auxiliary_phase3_paths']).map do |stored_path|
        next if stored_path.blank?

        begin
          Pathname.new(File.expand_path(stored_path, base_dir)).to_s
        rescue StandardError
          nil
        end
      end.compact
      @selected_auxiliary_phase3_files = stored_auxiliary & @auxiliary_phase3_files

      # Set API URL for AutoComplete components
      set_api_url

      # Optional filtering
      @q = params[:q].to_s.strip
      swimmers = Array(@phase3_data['swimmers'])

      # Filter by search query
      if @q.present?
        qd = @q.downcase
        swimmers = swimmers.select do |s|
          last = s['last_name'].to_s.downcase
          first = s['first_name'].to_s.downcase
          key = s['key'].to_s.downcase
          [last, first, key].any? { |v| v.include?(qd) }
        end
      end

      # Filter unmatched only (no swimmer_id assigned)
      swimmers = swimmers.select { |s| s['swimmer_id'].nil? } if params[:unmatched].present?

      # Pagination (phase-specific params to avoid cross-phase interference)
      # Swimmers typically have more entries, default to 100
      @page = params[:swimmers_page].to_i
      @page = 1 if @page < 1
      @per_page = params[:swimmers_per_page].to_i
      @per_page = 100 if @per_page <= 0 || !params.key?(:swimmers_per_page)
      @total_count = swimmers.size
      @total_pages = (@total_count.to_f / @per_page).ceil
      @row_range = "#{(@page * @per_page) - @per_page + 1}-#{@page * @per_page}"
      # Use Kaminari for pagination
      @items = Kaminari.paginate_array(swimmers, total_count: @total_count).page(@page).per(@per_page)

      # Broadcast ready status to clear progress modal
      broadcast_progress('Review swimmers: ready', @total_count, @total_count)
      return render 'data_fix/review_swimmers_v2'
    end

    redirect_to controller: 'data_fix_legacy', action: 'review_swimmers', params: request.query_parameters
  end
  # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/CyclomaticComplexity

  def review_events # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
    if params[:phase4_v2].present?
      @file_path = params[:file_path]
      if @file_path.blank?
        flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      source_path = resolve_source_path(@file_path)
      season = detect_season_from_pathname(source_path)
      lt_format = detect_layout_type(source_path)
      phase_path = default_phase_path_for(source_path, 4)
      if params[:rescan].present? || !File.exist?(phase_path)
        phase1_path = default_phase_path_for(source_path, 1)
        Import::Solvers::EventSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format,
          phase1_path: phase1_path
        )
        flash.now[:notice] = I18n.t('data_import.messages.phase_rebuilt', phase: 4)
        # Redirect without rescan parameter to avoid triggering rescan on navigation
        redirect_to(review_events_path(request.query_parameters.except(:rescan)),
                    notice: I18n.t('data_import.messages.phase_rebuilt', phase: 4)) && return
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase4_meta = pfm.meta
      @phase4_data = pfm.data

      # Set API URL for AutoComplete components
      set_api_url

      # Build sessions list for dropdown from Phase 1 (edited sessions) or fallback to Phase 4
      phase1_path = default_phase_path_for(source_path, 1)
      if File.exist?(phase1_path)
        phase1_pfm = PhaseFileManager.new(phase1_path)
        phase1_data = phase1_pfm.data || {}
        phase1_sessions = Array(phase1_data['meeting_session'])
        # Map Phase 1 sessions to simplified format for dropdown
        @sessions = phase1_sessions.each_with_index.map do |sess, idx|
          {
            'session_order' => sess['session_order'] || (idx + 1),
            'description' => sess['description'] || "Session #{idx + 1}",
            'scheduled_date' => sess['scheduled_date']
          }
        end
      else
        # Fallback: use Phase 4 sessions
        @sessions = Array(@phase4_data['sessions']).sort_by { |s| s['session_order'].to_i }
      end
      @sessions = [{ 'session_order' => 1, 'description' => 'Session 1', 'scheduled_date' => nil }] if @sessions.empty?

      # Prepare event_types payload for AutoComplete component
      @event_types_payload = GogglesDb::EventType.all_eventable.map do |event_type|
        {
          'id' => event_type.id,
          'search_column' => event_type.label,
          'label_column' => event_type.long_label
        }
      end

      # Fetch existing meeting events from Phase 1 sessions (if meeting_id is set)
      meeting_id = phase1_data&.dig('id')
      @existing_meeting_events = []
      if meeting_id.present?
        # Get all meeting_session IDs from Phase 1
        meeting_session_ids = phase1_sessions.filter_map { |s| s['id'] }
        if meeting_session_ids.any?
          @existing_meeting_events = GogglesDb::MeetingEvent.where(meeting_session_id: meeting_session_ids)
                                                            .includes(:event_type, :heat_type, :meeting_session)
                                                            .order('meeting_sessions.session_order, meeting_events.event_order')
                                                            .map do |me|
            {
              'id' => me.id,
              'meeting_session_id' => me.meeting_session_id,
              'session_order' => me.meeting_session.session_order,
              'event_order' => me.event_order,
              'event_type_id' => me.event_type_id,
              'event_type_label' => me.event_type&.long_label,
              'heat_type_id' => me.heat_type_id,
              'heat_type_code' => me.heat_type&.code,
              'stroke_type_code' => me.event_type&.stroke_type&.code,
              'distance' => me.event_type&.length_in_meters,
              'begin_time' => me.begin_time&.to_s(:time)
            }
          end
        end
      end

      # Flatten all events across Phase 4 sessions with session tracking
      # Sort by event_order within each session
      # Use session_order as stable identifier instead of array index
      @all_events = []
      phase4_sessions = Array(@phase4_data['sessions']).sort_by { |s| s['session_order'].to_i }
      phase4_sessions.each_with_index do |session, session_idx|
        events = Array(session['events']).sort_by { |e| e['event_order'].to_i }
        session_order = session['session_order'] || (session_idx + 1)
        events.each_with_index do |event, event_idx|
          @all_events << event.merge(
            '_session_index' => session_idx,
            '_event_index' => event_idx,
            '_session_order' => session_order
          )
        end
      end

      return render 'data_fix/review_events_v2'
    end

    redirect_to controller: 'data_fix_legacy', action: 'review_events', params: request.query_parameters
  end

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def review_results
    if params[:phase5_v2].present?
      @file_path = params[:file_path]
      if @file_path.blank?
        flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      source_path = resolve_source_path(@file_path)
      season = detect_season_from_pathname(source_path)
      lt_format = detect_layout_type(source_path)
      phase_path = default_phase_path_for(source_path, 5)

      # Build/rebuild phase 5 JSON scaffold (for summary display)
      if params[:rescan].present? || !File.exist?(phase_path)
        Import::Solvers::ResultSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )

        # Populate data_import_* tables immediately after rescan (before redirect)
        phase1_path = default_phase_path_for(source_path, 1)
        phase2_path = default_phase_path_for(source_path, 2)
        phase3_path = default_phase_path_for(source_path, 3)
        phase4_path = default_phase_path_for(source_path, 4)

        populator = Import::Phase5Populator.new(
          source_path: source_path,
          phase1_path: phase1_path,
          phase2_path: phase2_path,
          phase3_path: phase3_path,
          phase4_path: phase4_path
        )
        populate_stats = populator.populate!

        # Redirect without rescan parameter to avoid triggering rescan on navigation
        redirect_to(review_results_path(request.query_parameters.except(:rescan)),
                    notice: "Phase 5 rebuilt. Populated DB: #{populate_stats[:mir_created]} results, #{populate_stats[:laps_created]} laps") && return
      end

      pfm = PhaseFileManager.new(phase_path)
      @phase5_meta = pfm.meta
      @phase5_data = pfm.data

      # Populate data_import_* tables for detailed review (triggered by populate_db only)
      if params[:populate_db].present?
        phase1_path = default_phase_path_for(source_path, 1)
        phase2_path = default_phase_path_for(source_path, 2)
        phase3_path = default_phase_path_for(source_path, 3)
        phase4_path = default_phase_path_for(source_path, 4)

        populator = Import::Phase5Populator.new(
          source_path: source_path,
          phase1_path: phase1_path,
          phase2_path: phase2_path,
          phase3_path: phase3_path,
          phase4_path: phase4_path
        )
        @populate_stats = populator.populate!
        flash.now[:info] =
          "Populated DB: #{@populate_stats[:mir_created]} results, #{@populate_stats[:laps_created]} laps, #{@populate_stats[:programs_matched]} programs matched, #{@populate_stats[:mirs_matched]} MIRs matched"
      end

      # Query data_import tables for display
      @all_results = GogglesDb::DataImportMeetingIndividualResult
                     .where(phase_file_path: source_path)
                     .order(:import_key)
                     .limit(1000) # Safety limit for now

      # Eager-load swimmers and teams to avoid N+1 queries
      swimmer_ids = @all_results.filter_map(&:swimmer_id).uniq
      team_ids = @all_results.filter_map(&:team_id).uniq
      @swimmers_by_id = GogglesDb::Swimmer.where(id: swimmer_ids).index_by(&:id)
      @teams_by_id = GogglesDb::Team.where(id: team_ids).index_by(&:id)

      # Load phase 2 and phase 3 data for team/badge lookup by key
      phase2_path = default_phase_path_for(source_path, 2)
      phase3_path = default_phase_path_for(source_path, 3)
      @phase2_data = JSON.parse(File.read(phase2_path)) if File.exist?(phase2_path)
      @phase3_data = JSON.parse(File.read(phase3_path)) if File.exist?(phase3_path)

      # Build team lookup by key (for unmatched teams)
      if @phase2_data
        teams = @phase2_data.dig('data', 'teams') || []
        @teams_by_key = teams.index_by { |t| t['key'] }
      end

      # Build badge/team key mapping: swimmer_key => team_key
      if @phase3_data
        badges = @phase3_data.dig('data', 'badges') || []
        @team_key_by_swimmer_key = badges.each_with_object({}) do |badge, hash|
          hash[badge['swimmer_key']] = badge['team_key']
        end
      end

      # Eager-load laps grouped by parent import_key
      import_keys = @all_results.map(&:import_key)
      all_laps = GogglesDb::DataImportLap.where(parent_import_key: import_keys).order(:length_in_meters)
      @laps_by_parent_key = all_laps.group_by(&:parent_import_key)

      return render 'data_fix/review_results_v2'
    end

    redirect_to controller: 'data_fix_legacy', action: 'review_results', params: request.query_parameters
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Phase 6: Commit all entities to DB and generate SQL log
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def commit_phase6
    file_path = params[:file_path]
    if file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)

    # Gather all phase file paths
    phase1_path = default_phase_path_for(source_path, 1)
    phase2_path = default_phase_path_for(source_path, 2)
    phase3_path = default_phase_path_for(source_path, 3)
    phase4_path = default_phase_path_for(source_path, 4)

    # Validate all phase files exist
    missing_phases = []
    missing_phases << 1 unless File.exist?(phase1_path)
    missing_phases << 2 unless File.exist?(phase2_path)
    missing_phases << 3 unless File.exist?(phase3_path)
    missing_phases << 4 unless File.exist?(phase4_path)

    if missing_phases.any?
      flash[:error] = "Missing phase files: #{missing_phases.join(', ')}. Please complete all phases first."
      redirect_to(review_results_path(file_path: file_path, phase5_v2: 1)) && return
    end

    begin
      # Generate paths for output files
      curr_dir = File.dirname(source_path)
      sql_filename = "#{File.basename(source_path, '.json')}.sql"
      sql_path = File.join(curr_dir, sql_filename)
      log_path = File.join(curr_dir, "#{File.basename(source_path, '.json')}.log")

      # Initialize Main with all phase paths and log path
      committer = Import::Committers::Main.new(
        phase1_path: phase1_path,
        phase2_path: phase2_path,
        phase3_path: phase3_path,
        phase4_path: phase4_path,
        source_path: source_path,
        log_path: log_path
      )

      # Commit all entities in a transaction (will generate log file)
      stats = committer.commit_all

      # Check for errors
      raise StandardError, "Commit completed with #{stats[:errors].count} errors. Check #{log_path} for details." if stats[:errors].any?

      # Generate SQL file in results.new directory
      File.write(sql_path, committer.sql_log_content)

      # Get season_id for organized archiving
      season_id = JSON.parse(File.read(phase1_path))&.dig('data', 'season_id') || 'unknown'

      # Move source JSON and ALL phase files to results.done/<season_id>
      done_dir = File.join(curr_dir.gsub('results.new', 'results.done'), season_id.to_s)
      FileUtils.mkdir_p(done_dir)

      # Move source JSON as backup
      done_source_path = File.join(done_dir, File.basename(source_path))
      FileUtils.mv(source_path, done_source_path)

      # Move phase files (keep them for audit trail)
      [phase1_path, phase2_path, phase3_path, phase4_path].each do |path|
        next unless File.exist?(path)

        done_phase_path = File.join(done_dir, File.basename(path))
        FileUtils.mv(path, done_phase_path)
      end

      # Clean up data_import_* tables for this source (use done_source_path as reference)
      GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: done_source_path).delete_all
      GogglesDb::DataImportLap.where(phase_file_path: done_source_path).delete_all

      # Summary message
      flash[:notice] = 'Phase 6 commit successful! ' \
                       "Created: #{stats[:meetings_created]} meetings, #{stats[:teams_created]} teams, " \
                       "#{stats[:swimmers_created]} swimmers, #{stats[:badges_created]} badges, " \
                       "#{stats[:events_created]} events, #{stats[:programs_created]} programs, " \
                       "#{stats[:mirs_created]} results, #{stats[:laps_created]} laps. " \
                       "Updated: #{stats[:meetings_updated]} meetings, #{stats[:teams_updated]} teams, " \
                       "#{stats[:swimmers_updated]} swimmers, #{stats[:sessions_updated]} sessions. " \
                       "Files: #{sql_filename} (SQL) and .log. " \
                       "Phase files archived to results.done/#{season_id}/"
      redirect_to(push_index_path)
    rescue StandardError => e
      # Log detailed error
      error_msg = "Phase 6 commit failed: #{e.message}"
      Rails.logger.error("[Phase 6 Commit] #{error_msg}")
      Rails.logger.error(e.backtrace.join("\n"))

      flash[:error] = "#{error_msg} - Check log file for details."
      redirect_to(review_results_path(file_path: file_path, phase5_v2: 1))
    end
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Shared read-only endpoints delegate to legacy for now
  def coded_name
    redirect_to controller: 'data_fix_legacy', action: 'coded_name', params: request.query_parameters
  end

  def teams_for_swimmer
    redirect_to controller: 'data_fix_legacy', action: 'teams_for_swimmer', params: request.query_parameters
  end

  # Update a single Phase 2 team entry by key
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def update_phase2_team
    file_path = params[:file_path]
    team_key = params[:team_key]
    if file_path.blank? || team_key.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 2)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    teams = Array(data['teams'])

    # Find team by key (not index, since filtering changes indices)
    team_index = teams.find_index { |t| t['key'] == team_key }
    if team_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(review_teams_path(file_path:, phase2_v2: 1)) && return
    end

    t = teams[team_index] || {}

    # Handle both nested params from form (team[index][field]) and direct params from API (team[field])
    team_params = params[:team]
    if team_params.is_a?(ActionController::Parameters)
      # Try nested params first (from form with index)
      nested = if team_params[team_index.to_s].present?
                 team_params[team_index.to_s].permit(:team_id, :editable_name, :name, :name_variations, :city_id)
               else
                 # Direct params (from API or specs)
                 team_params.permit(:team_id, :editable_name, :name, :name_variations, :city_id)
               end

      # Update team_id (from AutoComplete)
      if nested.key?(:team_id)
        team_num = nested[:team_id].to_i
        t['team_id'] = team_num.positive? ? team_num : nil
      end

      # Update city_id (from City AutoComplete)
      if nested.key?(:city_id)
        city_num = nested[:city_id].to_i
        t['city_id'] = city_num.positive? ? city_num : nil
      end

      # Update text fields
      t['editable_name'] = sanitize_str(nested[:editable_name]) if nested.key?(:editable_name)
      t['name'] = sanitize_str(nested[:name]) if nested.key?(:name)
      t['name_variations'] = sanitize_str(nested[:name_variations]) if nested.key?(:name_variations)
    end

    teams[team_index] = t
    data['teams'] = teams

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    # Preserve pagination and filter params
    redirect_params = { file_path:, phase2_v2: 1 }
    redirect_params[:teams_page] = params[:teams_page] if params[:teams_page].present?
    redirect_params[:teams_per_page] = params[:teams_per_page] if params[:teams_per_page].present?
    redirect_params[:q] = params[:q] if params[:q].present?
    redirect_params[:unmatched] = params[:unmatched] if params[:unmatched].present?

    redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Create a new blank team entry in Phase 2 and redirect back to v2 view
  def add_team
    file_path = params[:file_path]
    if file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 2)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    teams = Array(data['teams'])

    # Build minimal blank team payload
    new_index = teams.size
    teams << {
      'key' => "New Team #{new_index + 1}",
      'name' => "New Team #{new_index + 1}",
      'editable_name' => "New Team #{new_index + 1}",
      'name_variations' => nil,
      'team_id' => nil,
      'city_id' => nil
    }

    data['teams'] = teams

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_teams_path(file_path:, phase2_v2: 1), notice: I18n.t('data_import.messages.updated')
  end

  # Delete a team entry from Phase 2 and clear downstream phase data
  def delete_team
    file_path = params[:file_path]
    team_key = params[:team_key]

    if file_path.blank? || team_key.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 2)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    teams = Array(data['teams'])

    # Find and remove team by key (not index, since filtering changes indices)
    team_index = teams.find_index { |t| t['key'] == team_key }
    if team_index.nil?
      flash[:warning] = "Team not found: #{team_key}"
      redirect_to(review_teams_path(file_path:, phase2_v2: 1)) && return
    end

    # Remove the team at the found index
    teams.delete_at(team_index)
    data['teams'] = teams

    # Clear downstream phase data (phase3+) when teams are modified
    # This ensures data consistency across phases
    data['swimmers'] = [] if data.key?('swimmers')
    data['meeting_event'] = [] if data.key?('meeting_event')
    data['meeting_program'] = [] if data.key?('meeting_program')
    data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
    data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    # Preserve pagination and filter params
    redirect_params = { file_path:, phase2_v2: 1 }
    redirect_params[:teams_page] = params[:teams_page] if params[:teams_page].present?
    redirect_params[:teams_per_page] = params[:teams_per_page] if params[:teams_per_page].present?
    redirect_params[:q] = params[:q] if params[:q].present?
    redirect_params[:unmatched] = params[:unmatched] if params[:unmatched].present?

    redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end

  # Update a single Phase 3 swimmer entry by key
  # rubocop:disable Metrics/AbcSize
  def update_phase3_swimmer
    file_path = params[:file_path]
    swimmer_key = params[:swimmer_key]

    if file_path.blank? || swimmer_key.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 3)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    swimmers = Array(data['swimmers'])

    # Find swimmer by key (not index, since filtering changes indices)
    swimmer_index = swimmers.find_index { |s| s['key'] == swimmer_key }
    if swimmer_index.nil?
      flash[:warning] = "Swimmer not found: #{swimmer_key}"
      redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
    end

    # Get swimmer params - handle nested params from AutoComplete
    swimmer_params = params[:swimmer] || {}

    # Update the swimmer at the found index
    swimmer = swimmers[swimmer_index]
    swimmer['complete_name'] = swimmer_params[:complete_name]&.strip if swimmer_params.key?(:complete_name)
    swimmer['first_name'] = swimmer_params[:first_name]&.strip if swimmer_params.key?(:first_name)
    swimmer['last_name'] = swimmer_params[:last_name]&.strip if swimmer_params.key?(:last_name)
    swimmer['year_of_birth'] = swimmer_params[:year_of_birth].to_i if swimmer_params.key?(:year_of_birth)
    swimmer['gender_type_code'] = swimmer_params[:gender_type_code]&.strip if swimmer_params.key?(:gender_type_code)
    if swimmer_params.key?(:id)
      swimmer_id_num = swimmer_params[:id].to_i
      swimmer['swimmer_id'] = swimmer_id_num.positive? ? swimmer_id_num : nil
    end

    data['swimmers'] = swimmers

    # Clear downstream phase data (phase4+) when swimmers are modified
    data['meeting_event'] = [] if data.key?('meeting_event')
    data['meeting_program'] = [] if data.key?('meeting_program')
    data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
    data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    # Preserve pagination and filter params
    redirect_params = { file_path:, phase3_v2: 1 }
    redirect_params[:swimmers_page] = params[:swimmers_page] if params[:swimmers_page].present?
    redirect_params[:swimmers_per_page] = params[:swimmers_per_page] if params[:swimmers_per_page].present?
    redirect_params[:q] = params[:q] if params[:q].present?
    redirect_params[:unmatched] = params[:unmatched] if params[:unmatched].present?

    redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end
  # rubocop:enable Metrics/AbcSize

  # Add a new blank swimmer to Phase 3
  def add_swimmer
    file_path = params[:file_path]

    if file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 3)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    swimmers = Array(data['swimmers'])

    # Create a new blank swimmer entry
    new_index = swimmers.size + 1
    new_swimmer = {
      'key' => "NEW|SWIMMER|#{new_index}",
      'last_name' => 'NEW',
      'first_name' => 'SWIMMER',
      'year_of_birth' => Time.zone.now.year - 30,
      'gender_type_code' => 'M',
      'complete_name' => "NEW SWIMMER #{new_index}",
      'swimmer_id' => nil,
      'fuzzy_matches' => []
    }

    swimmers << new_swimmer
    data['swimmers'] = swimmers

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_swimmers_path(file_path:, phase3_v2: 1), notice: 'Swimmer added'
  end

  # Merge auxiliary Phase 3 files to enrich relay swimmers
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def merge_phase3_swimmers
    file_path = params[:file_path]
    selected_paths = Array(params[:auxiliary_paths]).reject(&:blank?)

    if file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    base_dir = File.dirname(source_path)
    phase_path = default_phase_path_for(source_path, 3)

    unless File.exist?(phase_path)
      flash[:warning] = I18n.t('data_import.relay_enrichment.errors.missing_phase_file')
      redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
    end

    if selected_paths.empty?
      flash[:warning] = I18n.t('data_import.relay_enrichment.errors.no_selection')
      redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
    end

    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    meta = pfm.meta || {}

    warnings = []
    resolved_aux_paths = selected_paths.filter_map do |raw|
      abs_path = Pathname.new(File.expand_path(raw, base_dir)).to_s
      if File.exist?(abs_path)
        abs_path
      else
        warnings << I18n.t('data_import.relay_enrichment.errors.missing_file', file: File.basename(raw))
        nil
      end
    rescue StandardError
      warnings << I18n.t('data_import.relay_enrichment.errors.invalid_path', path: raw)
      nil
    end

    if resolved_aux_paths.empty?
      flash[:warning] = warnings.presence || I18n.t('data_import.relay_enrichment.errors.no_valid_files')
      redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
    end

    merger = Phase3::RelayMergeService.new(data.deep_dup)
    resolved_aux_paths.each do |aux_path|
      payload = JSON.parse(File.read(aux_path))
      aux_data = payload.is_a?(Hash) ? payload['data'] || payload : {}
      merger.merge_from(aux_data)
    rescue JSON::ParserError
      warnings << I18n.t('data_import.relay_enrichment.errors.unreadable_file', file: File.basename(aux_path))
    end

    merged_data = merger.result
    %w[meeting_event meeting_program meeting_individual_result meeting_relay_result].each do |key|
      merged_data[key] = [] if merged_data.key?(key)
    end

    relative_aux_paths = resolved_aux_paths.map do |abs|
      Pathname.new(abs).relative_path_from(Pathname.new(base_dir)).to_s
    rescue StandardError
      abs
    end

    meta['auxiliary_phase3_paths'] = relative_aux_paths
    meta['generated_at'] = Time.now.utc.iso8601

    pfm.write!(data: merged_data, meta: meta)

    stats = merger.stats
    flash[:notice] = I18n.t('data_import.relay_enrichment.merge_success',
                            swimmers_added: stats[:swimmers_added],
                            swimmers_updated: stats[:swimmers_updated],
                            badges_added: stats[:badges_added])
    flash[:warning] = warnings.join(' ') if warnings.present?

    redirect_to review_swimmers_path(file_path:, phase3_v2: 1)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Delete a swimmer entry from Phase 3 and clear downstream phase data
  def delete_swimmer
    file_path = params[:file_path]
    swimmer_key = params[:swimmer_key]

    if file_path.blank? || swimmer_key.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 3)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    swimmers = Array(data['swimmers'])

    # Find and remove swimmer by key (not index, since filtering changes indices)
    swimmer_index = swimmers.find_index { |s| s['key'] == swimmer_key }
    if swimmer_index.nil?
      flash[:warning] = "Swimmer not found: #{swimmer_key}"
      redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
    end

    # Remove the swimmer at the found index
    swimmers.delete_at(swimmer_index)
    data['swimmers'] = swimmers

    # Clear downstream phase data (phase4+) when swimmers are modified
    data['meeting_event'] = [] if data.key?('meeting_event')
    data['meeting_program'] = [] if data.key?('meeting_program')
    data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
    data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    # Preserve pagination and filter params
    redirect_params = { file_path:, phase3_v2: 1 }
    redirect_params[:swimmers_page] = params[:swimmers_page] if params[:swimmers_page].present?
    redirect_params[:swimmers_per_page] = params[:swimmers_per_page] if params[:swimmers_per_page].present?
    redirect_params[:q] = params[:q] if params[:q].present?
    redirect_params[:unmatched] = params[:unmatched] if params[:unmatched].present?

    redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end

  # Update a single Phase 4 event entry by session and event index
  # Also handles moving events between sessions via target_session_index
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def update_phase4_event
    file_path = params[:file_path]
    session_index = params[:session_index]&.to_i
    event_index = params[:event_index]&.to_i
    target_session_index = params[:target_session_index]&.to_i

    if file_path.blank? || session_index.nil? || event_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 4)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    sessions = Array(data['sessions'])

    # Load Phase 1 data to get session structure (for creating missing sessions)
    phase1_path = default_phase_path_for(source_path, 1)
    phase1_sessions = []
    if File.exist?(phase1_path)
      phase1_pfm = PhaseFileManager.new(phase1_path)
      phase1_data = phase1_pfm.data || {}
      phase1_sessions = Array(phase1_data['meeting_session'])
    end

    if session_index.negative? || session_index >= sessions.size
      flash[:warning] = "Invalid session index: #{session_index}"
      redirect_to(review_events_path(file_path:, phase4_v2: 1)) && return
    end

    events = Array(sessions[session_index]['events'])
    if event_index.negative? || event_index >= events.size
      flash[:warning] = "Invalid event index: #{event_index}"
      redirect_to(review_events_path(file_path:, phase4_v2: 1)) && return
    end

    # Get event params
    event_params = params[:event] || {}

    # Update the event at the specified index
    event = events[event_index]
    event['event_order'] = event_params[:event_order]&.to_i if event_params.key?(:event_order)
    event['distance'] = event_params[:distance]&.to_i if event_params.key?(:distance)
    event['stroke'] = event_params[:stroke]&.strip if event_params.key?(:stroke)
    event['heat_type'] = event_params[:heat_type]&.strip if event_params.key?(:heat_type)
    event['begin_time'] = event_params[:begin_time]&.strip if event_params.key?(:begin_time)

    # Handle meeting_event_id from AutoComplete
    raw_id = event_params[:meeting_event_id]
    unless raw_id.nil?
      str = raw_id.to_s.strip
      event['id'] = str.blank? ? nil : str.to_i
    end

    # Handle event_type_id from AutoComplete
    raw_event_type_id = event_params[:event_type_id]
    unless raw_event_type_id.nil?
      str = raw_event_type_id.to_s.strip
      event['event_type_id'] = str.blank? ? nil : str.to_i
    end

    # Handle heat_type_id from dropdown
    event['heat_type_id'] = event_params[:heat_type_id]&.to_i if event_params.key?(:heat_type_id)

    # Handle session change (move event to different session)
    if target_session_index.present? && target_session_index != session_index
      # Validate target session exists in Phase 1
      if target_session_index.negative? || target_session_index >= phase1_sessions.size
        flash[:warning] = "Invalid target session index: #{target_session_index}"
        redirect_to(review_events_path(file_path:, phase4_v2: 1)) && return
      end

      # Get the target session from Phase 1
      target_phase1_session = phase1_sessions[target_session_index]
      target_session_order = target_phase1_session['session_order'] || (target_session_index + 1)

      # Find or create the target session in Phase 4 by session_order
      phase4_target_session = sessions.find { |s| s['session_order'] == target_session_order }
      phase4_target_session_index = sessions.index(phase4_target_session) if phase4_target_session

      unless phase4_target_session
        # Create new session in Phase 4 based on Phase 1 session
        phase4_target_session = {
          'session_order' => target_session_order,
          'description' => target_phase1_session['description'],
          'scheduled_date' => target_phase1_session['scheduled_date'],
          'events' => []
        }
        sessions << phase4_target_session
        sessions.sort_by! { |s| s['session_order'].to_i }
        phase4_target_session_index = sessions.index(phase4_target_session)
      end

      # Remove event from current session
      events.delete_at(event_index)
      sessions[session_index]['events'] = events

      # Add event to target session
      target_events = Array(sessions[phase4_target_session_index]['events'])
      target_events << event
      sessions[phase4_target_session_index]['events'] = target_events

      flash_msg = "Event moved to session #{target_session_order} and updated"
    else
      # Just update in place
      sessions[session_index]['events'] = events
      flash_msg = I18n.t('data_import.messages.updated')
    end

    data['sessions'] = sessions

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_events_path(file_path:, phase4_v2: 1), notice: flash_msg
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  # Add a new blank event to Phase 4
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def add_event
    file_path = params[:file_path]
    session_index = params[:session_index].to_i
    event_type_id = params[:event_type_id]&.to_i

    if file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 4)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    sessions = Array(data['sessions'])

    # Load Phase 1 data to get session structure
    phase1_path = default_phase_path_for(source_path, 1)
    phase1_sessions = []
    if File.exist?(phase1_path)
      phase1_pfm = PhaseFileManager.new(phase1_path)
      phase1_data = phase1_pfm.data || {}
      phase1_sessions = Array(phase1_data['meeting_session'])
    end

    # Get the target session from Phase 1 by index
    if session_index.negative? || session_index >= phase1_sessions.size
      flash[:warning] = "Invalid session index: #{session_index}"
      redirect_to(review_events_path(file_path:, phase4_v2: 1)) && return
    end

    target_phase1_session = phase1_sessions[session_index]
    target_session_order = target_phase1_session['session_order'] || (session_index + 1)

    # Find or create the session in Phase 4 by session_order
    phase4_session = sessions.find { |s| s['session_order'] == target_session_order }
    phase4_session_index = sessions.index(phase4_session) if phase4_session

    unless phase4_session
      # Create new session in Phase 4 based on Phase 1 session
      phase4_session = {
        'session_order' => target_session_order,
        'description' => target_phase1_session['description'],
        'scheduled_date' => target_phase1_session['scheduled_date'],
        'events' => []
      }
      sessions << phase4_session
      sessions.sort_by! { |s| s['session_order'].to_i }
      phase4_session_index = sessions.index(phase4_session)
    end

    events = Array(phase4_session['events'])
    new_order = events.size + 1

    # Determine event details from event_type_id if provided
    if event_type_id.present?
      event_type = GogglesDb::EventType.find_by(id: event_type_id)
      if event_type
        distance = event_type.length_in_meters
        stroke = event_type.stroke_type.code
        key = event_type.label
      else
        distance = 50
        stroke = 'SL'
        key = "#{new_order * 50}SL"
      end
    else
      distance = 50
      stroke = 'SL'
      key = "#{new_order * 50}SL"
      event_type_id = nil
    end

    # Create a new event based on selected event type
    new_event = {
      'id' => nil,
      'event_order' => new_order,
      'event_type_id' => event_type_id,
      'distance' => distance,
      'stroke' => stroke,
      'heat_type' => 'F',
      'heat_type_id' => 3,      # Default ID for "finals"
      'begin_time' => '08:30',  # Default begin time
      'key' => key
    }

    events << new_event
    phase4_session['events'] = events
    sessions[phase4_session_index] = phase4_session
    data['sessions'] = sessions

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    # Calculate the flattened event index for highlighting
    flattened_index = 0
    sessions[0...phase4_session_index].each do |s|
      flattened_index += Array(s['events']).size
    end
    flattened_index += events.size - 1

    redirect_to review_events_path(file_path:, phase4_v2: 1, new_event_index: flattened_index),
                notice: I18n.t('data_import.messages.updated')
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Delete an event entry from Phase 4 and clear downstream phase data
  def delete_event
    file_path = params[:file_path]
    session_index = params[:session_index]&.to_i
    event_index = params[:event_index]&.to_i

    if file_path.blank? || session_index.nil? || event_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 4)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    sessions = Array(data['sessions'])

    if session_index.negative? || session_index >= sessions.size
      flash[:warning] = "Invalid session index: #{session_index}"
      redirect_to(review_events_path(file_path:, phase4_v2: 1)) && return
    end

    events = Array(sessions[session_index]['events'])
    if event_index.negative? || event_index >= events.size
      flash[:warning] = "Invalid event index: #{event_index}"
      redirect_to(review_events_path(file_path:, phase4_v2: 1)) && return
    end

    # Remove the event at the specified index
    events.delete_at(event_index)
    sessions[session_index]['events'] = events
    data['sessions'] = sessions

    # Clear downstream phase data (phase5) when events are modified
    data['meeting_program'] = [] if data.key?('meeting_program')
    data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
    data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_events_path(file_path:, phase4_v2: 1), notice: I18n.t('data_import.messages.updated')
  end

  # Update Phase 1 meeting attributes in the phase file and redirect back to v2 view
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def update_phase1_meeting
    file_path = params[:file_path]
    if file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 1)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}

    meeting_params = params.permit(:season_id, :description, :code, :name, :meetingURL,
                                   :header_year, :header_date, :edition,
                                   :edition_type_id, :timing_type_id,
                                   :cancelled, :confirmed,
                                   :max_individual_events, :max_individual_events_per_session,
                                   :dateDay1, :dateMonth1, :dateYear1,
                                   :dateDay2, :dateMonth2, :dateYear2,
                                   :venue1, :address1, :poolLength,
                                   meeting: [:meeting_id, :meeting])
    # Validate pool length strictly when provided
    if meeting_params.key?(:poolLength)
      vstr = meeting_params[:poolLength].to_s.strip
      allowed = %w[25 33 50]
      if vstr.present? && allowed.exclude?(vstr)
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        return redirect_to(review_sessions_path(file_path:, phase_v2: 1))
      end
    end
    # Normalize values: strip strings, cast integers, booleans (skip nested 'meeting' hash)
    normalized = {}
    meeting_params.except(:meeting).each do |k, v|
      key = k.to_s
      val = v
      case key
      when 'season_id', 'edition', 'edition_type_id', 'timing_type_id',
           'max_individual_events', 'max_individual_events_per_session',
           'dateDay1', 'dateMonth1', 'dateYear1', 'dateDay2', 'dateMonth2', 'dateYear2'
        normalized[key] = val.present? ? val.to_i : nil
      when 'cancelled', 'confirmed'
        normalized[key] = val.present? && val != '0'
      when 'header_date'
        normalized[key] = val.present? ? val.to_s.strip : nil
      when 'poolLength'
        vstr = (val || '').to_s.strip
        normalized[key] = vstr.presence # already validated against allowed values
      else
        normalized[key] = sanitize_str(val)
      end
    end

    # Map 'description' to 'name' for phase file compatibility
    normalized['name'] = normalized.delete('description') if normalized.key?('description')

    # Assign normalized fields to data
    normalized.each { |k, v| data[k] = v }

    # Persist meeting.id if provided via AutoComplete component (meeting[meeting_id])
    raw_mid = meeting_params.dig(:meeting, :meeting_id)
    unless raw_mid.nil?
      str = raw_mid.to_s.strip
      if str.blank?
        data['id'] = nil
      elsif /\A\d+\z/.match?(str)
        data['id'] = str.to_i
      else
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        return redirect_to(review_sessions_path(file_path:, phase_v2: 1))
      end
    end

    # If header_date is set, derive legacy LT2 month fields for compatibility
    if normalized.key?('header_date') && normalized['header_date'].present?
      begin
        hd = Date.parse(normalized['header_date'])
        data['dateMonth1'] = hd.month
        data['dateMonth2'] = hd.month
      rescue StandardError
        # ignore parse errors; keep existing values
      end
    end

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.updated')
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Update a session entry in Phase 1 using service object
  def update_phase1_session
    file_path = params[:file_path]
    session_index = params[:session_index].to_i

    if file_path.blank? || session_index.negative?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 1)
    pfm = PhaseFileManager.new(phase_path)

    updater = Phase1SessionUpdater.new(pfm, session_index, params)
    if updater.call
      redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.updated')
    else
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to review_sessions_path(file_path:, phase_v2: 1)
    end
  end

  # Create a new blank session entry in Phase 1 and redirect back to v2 view
  # Mirrors legacy add_session semantics minimally for v2
  def add_session
    file_path = params[:file_path]
    if file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 1)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    sessions = Array(data['meeting_session'])

    # Build minimal blank session payload
    new_index = sessions.size
    sessions << {
      'id' => nil,
      'description' => "Session #{new_index + 1}",
      'session_order' => new_index + 1,
      'scheduled_date' => nil,
      'day_part_type_id' => nil,
      'swimming_pool' => {
        'id' => nil,
        'name' => nil,
        'nick_name' => nil,
        'address' => nil,
        'pool_type_id' => nil,
        'lanes_number' => nil,
        'maps_uri' => nil,
        'plus_code' => nil,
        'latitude' => nil,
        'longitude' => nil,
        'city' => {
          'id' => nil,
          'name' => nil,
          'area' => nil,
          'zip' => nil,
          'country' => nil,
          'country_code' => nil,
          'latitude' => nil,
          'longitude' => nil
        }
      }
    }

    data['meeting_session'] = sessions

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_sessions_path(file_path:, phase_v2: 1, new_session_index: new_index), notice: I18n.t('data_import.messages.updated')
  end

  # Delete a session entry from Phase 1 and redirect back to v2 view
  def delete_session
    file_path = params[:file_path]
    session_index = params[:session_index]&.to_i

    if file_path.blank? || session_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 1)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    sessions = Array(data['meeting_session'])

    # Validate session_index
    if session_index.negative? || session_index >= sessions.size
      flash[:warning] = "Invalid session index: #{session_index}"
      redirect_to(review_sessions_path(file_path:, phase_v2: 1)) && return
    end

    # Remove the session at the specified index
    sessions.delete_at(session_index)
    data['meeting_session'] = sessions

    # Clear downstream phase data when sessions are modified
    data['meeting_event'] = []
    data['meeting_program'] = []
    data['meeting_individual_result'] = []
    data['meeting_relay_result'] = []
    data['lap'] = []
    data['relay_lap'] = []
    data['meeting_relay_swimmer'] = []

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.deleted')
  end

  # Rebuild meeting_session array from selected meeting using service object
  def rescan_phase1_sessions
    file_path = params[:file_path]
    if file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 1)
    pfm = PhaseFileManager.new(phase_path)

    # Determine meeting id from params or current data
    meeting_id = params[:meeting_id] || pfm.data&.dig('id')

    rescanner = Phase1SessionRescanner.new(pfm, meeting_id)
    rescanner.call

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.updated')
  end

  # Returns an HTML partial with the detailed results for a specific (event_key, gender, category)
  # in Step 5 v2. This reads from the original source JSON (LT4 expected).
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def results_chunk_v2
    file_path = params[:file_path]
    event_key = params[:event_key].to_s
    gender = params[:gender].to_s
    category = params[:category].to_s
    if file_path.blank? || event_key.blank? || gender.blank? || category.blank?
      return render plain: I18n.t('data_import.errors.invalid_request'), status: :bad_request
    end

    source_path = resolve_source_path(file_path)
    begin
      data_hash = JSON.parse(File.read(source_path))
    rescue StandardError => e
      return render plain: e.message, status: :unprocessable_entity
    end

    events = Array(data_hash['events'])
    # Match by eventCode if possible, else fallback to distance|stroke key
    dist_key = nil
    stroke_key = nil
    dist_key, stroke_key = event_key.split('|', 2) if event_key.include?('|')
    matched = events.select do |ev|
      code = ev['eventCode'].to_s
      if code.present?
        code == event_key
      else
        d = ev['distance'] || ev['distanceInMeters'] || ev['eventLength']
        s = ev['stroke'] || ev['style'] || ev['eventStroke']
        d.to_s == dist_key.to_s && s.to_s == stroke_key.to_s
      end
    end

    # Collect results for the requested gender and category
    results = []
    matched.each do |ev|
      Array(ev['results']).each do |res|
        g = (res['gender'] || ev['eventGender']).to_s
        c = res['category'] || res['categoryTypeCode'] || res['category_code'] || res['cat'] || res['category_type_code']
        next unless g == gender && c.to_s == category.to_s

        results << res
      end
    end

    @event_key = event_key
    @gender = gender
    @category = category
    @results = results
    render partial: 'data_fix/results_category_v2', formats: [:html]
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

  private

  # Setter for @api_url
  def set_api_url
    @api_url = "#{GogglesDb::AppParameter.config.settings(:framework_urls).api}/api/v3"
    flash.now[:error] = I18n.t('lookup.errors.api_url_not_set') if @api_url.blank?
  end

  # Minimal string sanitizer for form inputs
  def sanitize_str(val)
    return nil if val.nil?
    return val.strip if val.is_a?(String)

    val
  end

  def handle_phase1
    @file_path = params[:file_path]
    if @file_path.blank?
      flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    season = detect_season_from_pathname(@file_path)
    lt_format = detect_layout_type(@file_path)
    # Build or refresh phase1 file from source
    Import::Solvers::Phase1Solver.new(season:).build!(
      source_path: @file_path,
      lt_format:
        lt_format
    )

    # For now, render legacy page to reuse views, but make it read from original file
    # (We will wire the views to read phase1.json in a subsequent step)
    redirect_to controller: 'data_fix_legacy', action: 'review_sessions', params: request.query_parameters
  end

  def detect_season_from_pathname(file_path)
    season_id = File.dirname(file_path).split('/').last.to_i
    season_id = 212 unless season_id.positive?
    GogglesDb::Season.find(season_id)
  end

  def detect_layout_type(file_path)
    # Cheap detection: scan first chunk for layoutType without parsing full JSON
    begin
      chunk = File.open(file_path, 'rb') { |f| f.read(64 * 1024) }
      if chunk && (m = chunk.match(/"layoutType"\s*:\s*(\d+)/))
        return m[1].to_i
      end
    rescue StandardError
      # ignore
    end
    2
  end

  def default_phase_path_for(source_path, phase_num)
    dir = File.dirname(source_path)
    base = File.basename(source_path, File.extname(source_path))
    File.join(dir, "#{base}-phase#{phase_num}.json")
  end

  # If file_path points to a phase file, resolve original source_path from its meta.
  def resolve_source_path(file_path)
    return file_path if file_path.blank?
    return file_path unless /-phase\d+\.json\z/.match?(file_path)

    pfm = PhaseFileManager.new(file_path)
    meta = pfm.meta
    meta['source_path'].presence || file_path
  rescue StandardError
    file_path
  end

  # Broadcast progress updates via ActionCable for real-time UI feedback
  # Used during long-running operations (team/swimmer/result processing)
  def broadcast_progress(message, current, total)
    ActionCable.server.broadcast(
      'ImportStatusChannel',
      { msg: message, progress: current, total: total }
    )
  rescue StandardError => e
    Rails.logger.warn("[DataFixController] Failed to broadcast progress: #{e.message}")
  end
end
