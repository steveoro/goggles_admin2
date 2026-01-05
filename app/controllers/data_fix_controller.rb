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

  # Phase 5 pagination constant: max rows (results + laps) per page
  PHASE5_MAX_ROWS_PER_PAGE = 2500

  # Expose issue detection helpers to views
  helper_method :swimmer_has_missing_data?, :relay_result_has_issues?

  # rubocop:disable Metrics/AbcSize
  def review_sessions
    return unless params[:phase_v2].present?

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
    return unless meeting_id.present?

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
  # rubocop:enable Metrics/AbcSize
  # ---------------------------------------------------------------------------

  # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/CyclomaticComplexity
  def review_teams
    return unless params[:phase2_v2].present?

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

    # Safety: rebuild Phase 2 file if teams dictionary is missing (older generator or corrupted file)
    if @phase2_data['teams'].nil?
      Import::Solvers::TeamSolver.new(season:).build!(
        source_path: source_path,
        lt_format: lt_format
      )
      redirect_to(review_teams_path(request.query_parameters),
                  notice: I18n.t('data_import.messages.phase_rebuilt', phase: 2)) && return
    end

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

    # Filter teams needing review: unmatched (no team_id) OR match < 90% (yellow/red matches)
    # This shows ALL teams that need manual verification at a glance
    if params[:unmatched].present?
      teams = teams.select do |t|
        t['team_id'].nil? || (t['match_percentage'] || 0.0) < 90.0
      end
    end

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
  end
  # ---------------------------------------------------------------------------

  def review_swimmers
    return unless params[:phase3_v2].present?

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

    # Safety: rebuild Phase 3 file if swimmers dictionary is missing (older generator or corrupted file)
    if @phase3_data['swimmers'].nil?
      phase1_path = default_phase_path_for(source_path, 1)
      phase2_path = default_phase_path_for(source_path, 2)
      Import::Solvers::SwimmerSolver.new(season:).build!(
        source_path: source_path,
        lt_format: lt_format,
        phase1_path: phase1_path,
        phase2_path: phase2_path
      )
      redirect_to(review_swimmers_path(request.query_parameters),
                  notice: I18n.t('data_import.messages.phase_rebuilt', phase: 3)) && return
    end
    @source_path = source_path
    base_dir = File.dirname(source_path)

    # Extract season and meeting date for category computation
    season = detect_season_from_pathname(source_path)
    phase1_path = default_phase_path_for(source_path, 1)
    meeting_date = if File.exist?(phase1_path)
                     phase1_data = JSON.parse(File.read(phase1_path))
                     phase1_data.dig('data', 'meeting', 'header_date')
                   end

    detector = Phase3::RelayEnrichmentDetector.new(
      source_path: source_path,
      phase3_swimmers: @phase3_data.fetch('swimmers', []),
      season: season,
      meeting_date: meeting_date
    )
    @show_new_relay_swimmers = params[:show_new_relay_swimmers].present?
    @relay_enrichment_summary = filter_relay_enrichment_summary(detector.detect, @show_new_relay_swimmers)
    @auxiliary_phase3_files = Dir.glob(File.join(base_dir, '*-phase3*.json'))
                                 .reject { |path| path == phase_path }
                                 .sort
    stored_auxiliary = Array(@phase3_meta['auxiliary_phase3_paths']).filter_map do |stored_path|
      next if stored_path.blank?

      begin
        Pathname.new(File.expand_path(stored_path, base_dir)).to_s
      rescue StandardError
        nil
      end
    end
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

    # Filter swimmers needing review: unmatched (no swimmer_id) OR match < 90% (yellow/red matches)
    # This shows ALL swimmers that need manual verification at a glance
    if params[:unmatched].present?
      swimmers = swimmers.select do |s|
        s['swimmer_id'].nil? || (s['match_percentage'] || 0.0) < 90.0
      end
    end

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
  end
  # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/CyclomaticComplexity
  # ---------------------------------------------------------------------------

  def review_events # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
    return unless params[:phase4_v2].present?

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
                                                          .includes(:heat_type, :meeting_session, event_type: :stroke_type)
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
  end
  # ---------------------------------------------------------------------------

  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def review_results
    return unless params[:phase5_v2].present?

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
      broadcast_progress('Populating phase 5...', 0, 100)
      populate_stats = populator.populate!

      # Redirect without rescan parameter to avoid triggering rescan on navigation
      redirect_to(review_results_path(request.query_parameters.except(:rescan)),
                  notice: "Phase 5 rebuilt. Populated DB: #{populate_stats[:mir_created]} results, #{populate_stats[:laps_created]} laps") && return
    end

    # Load phase5 JSON with program groups
    if File.exist?(phase_path)
      phase5_json = JSON.parse(File.read(phase_path))
      @phase5_meta = { 'name' => phase5_json['name'], 'source_file' => phase5_json['source_file'] }
      all_programs = phase5_json['programs'] || []
      @total_programs_count = all_programs.size # Track unfiltered count

      # ALWAYS run server-side issue detection BEFORE pagination
      # This ensures we know about issues regardless of filtering or pagination
      filter_data = load_filter_data(source_path)
      @programs_with_issues = detect_programs_with_issues(all_programs, filter_data)
      @issue_count = @programs_with_issues.size

      # Server-side filtering: only show programs with issues if filter is active
      # Auto-activate filter if there are issues and no explicit filter param
      @filter_active = params[:filter_issues] == '1' || (@issue_count.positive? && !params[:filter_issues].to_i.zero?)
      all_programs = @programs_with_issues if @filter_active && @issue_count.positive?

      # Sort programs by event order from phase4 (individual events first, then relays)
      phase4_path = default_phase_path_for(source_path, 4)
      all_programs = sort_programs_by_event_order(all_programs, phase4_path)

      # Apply pagination to prevent UI slowdown
      @current_page = [params[:page].to_i, 1].max
      @phase5_programs, @total_pages = paginate_phase5_programs(all_programs, @current_page)
    else
      @phase5_meta = {}
      @phase5_programs = []
      @total_programs_count = 0
      @current_page = 1
      @total_pages = 1
    end

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
      broadcast_progress('Populating DB from phase 5 data...', 0, 100)
      @populate_stats = populator.populate!
      flash.now[:info] =
        "Populated DB: #{@populate_stats[:mir_created]} results, #{@populate_stats[:laps_created]} laps, " \
        "#{@populate_stats[:relay_results_created]} relay results, #{@populate_stats[:relay_swimmers_created]} relay swimmers, " \
        "#{@populate_stats[:relay_laps_created]} relay laps, #{@populate_stats[:programs_matched]} programs matched"
    end

    # Query data_import tables for display (no limit needed - view re-queries per program)
    @all_results = GogglesDb::DataImportMeetingIndividualResult
                   .where(phase_file_path: source_path)
                   .order(:import_key)

    # Also check for relay results to determine if commit button should be visible
    @has_relay_results = GogglesDb::DataImportMeetingRelayResult.exists?(phase_file_path: source_path)

    # Eager-load swimmers and teams to avoid N+1 queries
    # NOTE: Load ALL swimmer/team IDs from source file, not just from @all_results (which is limited)
    # This ensures the view can find swimmers for any program displayed via pagination
    swimmer_ids = GogglesDb::DataImportMeetingIndividualResult
                  .where(phase_file_path: source_path)
                  .pluck(:swimmer_id)
                  .compact.uniq
    team_ids = GogglesDb::DataImportMeetingIndividualResult
               .where(phase_file_path: source_path)
               .pluck(:team_id)
               .compact.uniq
    @swimmers_by_id = GogglesDb::Swimmer.where(id: swimmer_ids).index_by(&:id)
    @teams_by_id = GogglesDb::Team.includes(:city).where(id: team_ids).index_by(&:id)

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
    # Also index by partial key (without gender) for flexible lookup
    if @phase3_data
      badges = @phase3_data.dig('data', 'badges') || []
      @team_key_by_swimmer_key = badges.each_with_object({}) do |badge, hash|
        swimmer_key = badge['swimmer_key']
        team_key = badge['team_key']
        # Index by full key
        hash[swimmer_key] = team_key
        # Also index by partial key (|LAST|FIRST|YOB or LAST|FIRST|YOB)
        partial_key = normalize_swimmer_key_for_lookup(swimmer_key)
        next unless partial_key

        # Store both with and without leading pipe for flexible lookup
        hash[partial_key] = team_key
        hash[partial_key.sub(/^\|/, '')] = team_key # Without leading pipe
      end

      swimmers = @phase3_data.dig('data', 'swimmers') || []
      @swimmers_by_key = swimmers.index_by { |s| s['key'] }
    end

    # Eager-load laps for ALL individual results in this source file
    all_laps = GogglesDb::DataImportLap.where(phase_file_path: source_path).order(:length_in_meters)
    @laps_by_parent_key = all_laps.group_by(&:parent_import_key)

    # Query ALL relay results for display (no limit - relay swimmers need all parent keys)
    @all_relay_results = GogglesDb::DataImportMeetingRelayResult
                         .where(phase_file_path: source_path)
                         .order(:import_key)

    # Eager-load relay teams (add to existing team query)
    relay_team_ids = @all_relay_results.pluck(:team_id).compact.uniq
    additional_teams = GogglesDb::Team.includes(:city).where(id: relay_team_ids - team_ids).index_by(&:id)
    @teams_by_id.merge!(additional_teams)

    # Eager-load relay swimmers and laps for ALL relay results in this source file
    # (No limit - must load all to avoid missing swimmers when view re-queries results)
    @relay_swimmers_by_parent_key = GogglesDb::DataImportMeetingRelaySwimmer
                                    .where(phase_file_path: source_path)
                                    .order(:relay_order)
                                    .group_by(&:parent_import_key)
    @relay_laps_by_parent_key = GogglesDb::DataImportRelayLap
                                .includes(:data_import_meeting_relay_swimmer)
                                .where(phase_file_path: source_path)
                                .order(:length_in_meters)
                                .group_by(&:parent_import_key)

    # Build swimmer lookup for relay swimmers (add to existing swimmer query if needed)
    relay_swimmer_ids = @relay_swimmers_by_parent_key.values.flatten.filter_map(&:swimmer_id).uniq
    additional_swimmers = GogglesDb::Swimmer.where(id: relay_swimmer_ids - swimmer_ids).index_by(&:id)
    @swimmers_by_id.merge!(additional_swimmers)

    # Build relay swimmer name lookup from source data for unmatched swimmers
    # Maps: {mrr_import_key => {relay_order => {name, key}}}
    relay_import_keys = @all_relay_results.pluck(:import_key)
    @relay_swimmer_names = build_relay_swimmer_names_from_source(source_path, relay_import_keys)

    # Broadcast ready status to clear progress modal
    broadcast_progress('Review results: ready', 100, 100)
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  # ---------------------------------------------------------------------------

  # Phase 6: Commit all entities to DB and generate SQL/log report
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def commit_phase6 # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    file_path = params[:file_path]
    if file_path.blank?
      flash.now[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)

    # Gather all phase file paths
    phase1_path = default_phase_path_for(source_path, 1)
    phase2_path = default_phase_path_for(source_path, 2)
    phase3_path = default_phase_path_for(source_path, 3)
    phase4_path = default_phase_path_for(source_path, 4)
    phase5_path = default_phase_path_for(source_path, 5)

    # Validate all phase files exist
    missing_phases = []
    missing_phases << 1 unless File.exist?(phase1_path)
    missing_phases << 2 unless File.exist?(phase2_path)
    missing_phases << 3 unless File.exist?(phase3_path)
    missing_phases << 4 unless File.exist?(phase4_path)
    missing_phases << 5 unless File.exist?(phase5_path)

    if missing_phases.any?
      flash.now[:error] = "Missing phase files: #{missing_phases.join(', ')}. Please complete all phases first."
      redirect_to(review_results_path(file_path: file_path, phase5_v2: 1)) && return
    end

    # Validate Phase 5 data exists in data_import_* tables
    mir_count = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).count
    mrr_count = GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: source_path).count

    if mir_count.zero? && mrr_count.zero?
      flash[:error] = 'No Phase 5 data found. Please rescan Phase 5 (Results) before committing.'
      redirect_to(review_results_path(file_path: file_path, phase5_v2: 1, rescan: 1)) && return
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

    @file_path = file_path
    @log_path = log_full_path
    @sql_filename = sql_full_path
    @commit_success = false

    begin
      # Commit all entities in a transaction (will generate log file via Main)
      @stats = committer.commit_all

      # Guard: if any errors were accumulated, treat as failure even if transaction did not raise
      raise StandardError, "Commit completed with #{@stats[:errors].count} errors. Check #{log_full_path} for details." if @stats[:errors].any?

      # Generate SQL file in results.new directory
      File.write(sql_full_path, committer.sql_log_content)

      # Get season_id for organized archiving
      season_id = JSON.parse(File.read(phase1_path))&.dig('data', 'season_id') || 'unknown'

      # Move source JSON and ALL phase files to 'crawler/data/results.done/<season_id>/'
      done_dir = source_dir.gsub('results.new', 'results.done')
      FileUtils.mkdir_p(done_dir)

      # Move source JSON as backup
      done_source_path = File.join(done_dir, File.basename(source_path))
      FileUtils.mv(source_path, done_source_path)

      # Move phase files (keep them for audit trail)
      moved_files = [source_path]
      [phase1_path, phase2_path, phase3_path, phase4_path, phase5_path].each do |path|
        next unless File.exist?(path)

        done_phase_path = File.join(done_dir, File.basename(path))
        FileUtils.mv(path, done_phase_path)
        moved_files << path
      end

      # Clean up data_import_* tables for this source (use source_path as reference - before move!)
      mir_deleted = GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).delete_all
      lap_deleted = GogglesDb::DataImportLap.where(phase_file_path: source_path).delete_all
      mrr_deleted = GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: source_path).delete_all
      mrs_deleted = GogglesDb::DataImportMeetingRelaySwimmer.where(phase_file_path: source_path).delete_all
      relay_lap_deleted = GogglesDb::DataImportRelayLap.where(phase_file_path: source_path).delete_all
      total_deleted = mir_deleted + lap_deleted + mrr_deleted + mrs_deleted + relay_lap_deleted

      # Append post-commit operations to log file
      File.open(log_full_path, 'a') do |f|
        f.puts
        f.puts '=== POST-COMMIT OPERATIONS ==='
        f.puts "[#{Time.current.strftime('%H:%M:%S')}] moved #{moved_files.size} files to #{done_dir}"
        moved_files.each { |path| f.puts "  - #{File.basename(path)}" }
        f.puts "[#{Time.current.strftime('%H:%M:%S')}] cleaned up #{total_deleted} data_import_* temp records"
        f.puts "  - DataImportMeetingIndividualResult: #{mir_deleted}"
        f.puts "  - DataImportLap: #{lap_deleted}"
        f.puts "  - DataImportMeetingRelayResult: #{mrr_deleted}"
        f.puts "  - DataImportMeetingRelaySwimmer: #{mrs_deleted}"
        f.puts "  - DataImportRelayLap: #{relay_lap_deleted}"
      end

      @season_id = season_id
      @done_dir = done_dir
      @commit_success = true
      @error_message = nil
    rescue StandardError => e
      # Log detailed error and prepare report data
      @error_message = "Phase 6 commit failed: #{e.message}"
      Rails.logger.error("[Phase 6 Commit] #{@error_message}")
      Rails.logger.error(e.backtrace.join("\n"))

      # Ensure stats is available for the report even if commit_all raised early
      @stats ||= committer.stats if committer.respond_to?(:stats)
      @stats ||= { errors: [] }

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
              @first_error_step_label = step_labels[step]
            end
          end
        end
      rescue StandardError
        # Best-effort hinting only; never break the report rendering
      end
    end

    render 'data_fix/commit_phase6_report'
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength
  # ---------------------------------------------------------------------------

  # TEMP test for wrong view syntax:
  def commit_phase6_report
    # (no-op, just render the view)
  end
  # ---------------------------------------------------------------------------

  # Shared read-only endpoints delegate to legacy for now
  def coded_name
    redirect_to controller: 'data_fix_legacy', action: 'coded_name', params: request.query_parameters
  end
  # ---------------------------------------------------------------------------

  def teams_for_swimmer
    redirect_to controller: 'data_fix_legacy', action: 'teams_for_swimmer', params: request.query_parameters
  end
  # ---------------------------------------------------------------------------

  # Filter relay enrichment summary based on swimmer ID and issues.
  # - Always removes legs already matched to a swimmer_id > 0
  # - When show_new is false, hides legs whose only issue is missing_swimmer_id
  def filter_relay_enrichment_summary(summary, show_new)
    # Build swimmer_id lookup from Phase 3 data for double-checking (case-insensitive)
    swimmers_with_id = Set.new
    if @phase3_data
      Array(@phase3_data['swimmers']).each do |s|
        key = s['key']
        sid = s['swimmer_id'].to_i
        if key.present? && sid.positive?
          swimmers_with_id.add(key.downcase) # Normalize to lowercase
        end
      end
    end

    Array(summary).filter_map do |relay|
      swimmers = Array(relay['swimmers'])

      filtered_swimmers = swimmers.reject do |leg|
        issues = leg['issues'] || {}
        phase3_swimmer = leg['phase3_swimmer'] || {}
        swimmer_id = phase3_swimmer['swimmer_id'].to_i
        phase3_key = leg['phase3_key']

        # Matched swimmers are never part of enrichment list
        # Check both the swimmer_id from phase3_swimmer AND the key lookup (case-insensitive)
        key_matched = phase3_key.present? && swimmers_with_id.include?(phase3_key.downcase)
        matched = swimmer_id.positive? || key_matched

        # New swimmers with only missing_swimmer_id (no other blocking issue)
        only_missing_id = issues['missing_swimmer_id'] && !issues['missing_year_of_birth'] && !issues['missing_gender']
        new_non_blocking = !matched && only_missing_id && !show_new

        matched || new_non_blocking
      end

      next if filtered_swimmers.empty?

      # Recompute missing_counts for the filtered swimmers
      missing_counts = filtered_swimmers.each_with_object(Hash.new(0)) do |leg, acc|
        (leg['issues'] || {}).each do |issue_key, flag|
          acc[issue_key] += 1 if flag
        end
      end

      relay.merge('swimmers' => filtered_swimmers, 'missing_counts' => missing_counts)
    end
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

    # Handle direct params from form (team[field])
    # Note: AutoComplete component adds extra fields (team, city, area) which we permit but ignore
    team_params = params[:team]
    if team_params.is_a?(ActionController::Parameters)
      permitted = team_params.permit(:team_id, :editable_name, :name, :name_variations, :city_id,
                                     :team, :city, :area)

      # Update team_id (from AutoComplete)
      if permitted.key?(:team_id)
        team_num = permitted[:team_id].to_i
        t['team_id'] = team_num.positive? ? team_num : nil
      end

      # Update city_id (from City AutoComplete)
      if permitted.key?(:city_id)
        city_num = permitted[:city_id].to_i
        t['city_id'] = city_num.positive? ? city_num : nil
      end

      # Update text fields
      t['editable_name'] = sanitize_str(permitted[:editable_name]) if permitted.key?(:editable_name)
      t['name'] = sanitize_str(permitted[:name]) if permitted.key?(:name)
      t['name_variations'] = sanitize_str(permitted[:name_variations]) if permitted.key?(:name_variations)
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
    selected_paths = Array(params[:auxiliary_paths]).compact_blank

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

    # First, enrich from own badges (same file) - badges often have gender from individual results
    merger.self_enrich!

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
                            swimmers_updated: stats[:swimmers_updated],
                            badges_added: stats[:badges_added])

    # Add warning for ambiguous partial matches
    ambiguous = stats[:partial_matches_ambiguous] || []
    if ambiguous.any?
      ambiguous_names = ambiguous.map { |a| "#{a[:name]} (#{a[:issue]})" }.join(', ')
      warnings << I18n.t('data_import.relay_enrichment.ambiguous_matches', names: ambiguous_names)
    end

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
  # Also handles moving events between sessions via target_session_order
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
  def update_phase4_event
    file_path = params[:file_path]
    session_index = params[:session_index]&.to_i
    event_index = params[:event_index]&.to_i
    target_session_order = params[:target_session_order]&.to_i

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

    # Get current session by reference (not index) to handle sorting correctly
    source_session = sessions[session_index]
    current_session_order = source_session['session_order']&.to_i

    events = Array(source_session['events'])
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

    # Handle autofilled checkbox (unchecked = false, checked = true)
    # Checkbox sends '1' when checked, nothing when unchecked
    event['autofilled'] = event_params[:autofilled] == '1'

    # Handle session change (move event to different session) - compare by session_order
    if target_session_order.present? && target_session_order != current_session_order
      # Validate target session exists in Phase 1 by session_order
      target_phase1_session = phase1_sessions.find { |s| s['session_order'].to_i == target_session_order }
      unless target_phase1_session
        flash[:warning] = "Invalid target session order: #{target_session_order}"
        redirect_to(review_events_path(file_path:, phase4_v2: 1)) && return
      end

      # Find or create the target session in Phase 4 by session_order
      phase4_target_session = sessions.find { |s| s['session_order'].to_i == target_session_order }

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
      end

      # Remove event from source session (use reference, not stale index)
      events.delete_at(event_index)
      source_session['events'] = events

      # Update event's internal session_order to match target session
      event['session_order'] = target_session_order

      # Add event to target session (use reference, not index)
      target_events = Array(phase4_target_session['events'])
      target_events << event
      phase4_target_session['events'] = target_events

      flash_msg = "Event moved to session #{target_session_order} and updated"
    else
      # Just update in place (use reference, not stale index)
      source_session['events'] = events
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

  # Build relay swimmer name lookup from source data
  # Returns: {mrr_import_key => {relay_order => {name: ..., key: ...}}}
  def build_relay_swimmer_names_from_source(source_path, relay_import_keys)
    return {} unless File.exist?(source_path)
    return {} if relay_import_keys.blank?

    source_data = JSON.parse(File.read(source_path))
    result = {}

    # Parse sections for relay results
    sections = source_data['sections'] || []
    sections.each do |section|
      rows = section['rows'] || []
      rows.each do |row|
        next unless row['relay']

        # Build import key for this row (matches Phase5Populator logic)
        session_order = section['session_order'] || 1
        distance = section['event_length'] || section['distance']
        stroke = section['event_stroke'] || section['stroke']
        next if distance.blank? || stroke.blank?

        event_code = "#{distance}#{stroke}"
        category = section['fin_sigla_categoria']
        gender = section['fin_sesso'] || 'X'
        team_key = row['team']
        timing_string = row['timing'] || '0'

        program_key = "#{session_order}-#{event_code}-#{category}-#{gender}"
        # Use same format as GogglesDb::DataImportMeetingRelayResult.build_import_key
        mrr_import_key = "#{program_key}/#{team_key}-#{timing_string}"

        # Only process if this import_key is in our relay results
        next unless relay_import_keys.include?(mrr_import_key)

        # Extract swimmer names from laps
        laps = row['laps'] || []
        result[mrr_import_key] = {}

        laps.each_with_index do |lap, idx|
          relay_order = idx + 1
          swimmer_key_raw = lap['swimmer'] || ''
          swimmer_parts = swimmer_key_raw.split('|')

          # Parse composite key to extract name and build Phase 3 key
          if swimmer_parts.size >= 5
            last_name = swimmer_parts[1]
            first_name = swimmer_parts[2]
            year = swimmer_parts[3]
          elsif swimmer_parts.size >= 4
            last_name = swimmer_parts[0]
            first_name = swimmer_parts[1]
            year = swimmer_parts[2]
          else
            next
          end

          swimmer_key = "#{last_name}|#{first_name}|#{year}"
          swimmer_name = "#{first_name} #{last_name}".strip

          result[mrr_import_key][relay_order] = {
            'name' => swimmer_name,
            'key' => swimmer_key
          }
        end
      end
    end

    result
  rescue StandardError => e
    Rails.logger.error("[DataFixController] Error building relay swimmer names: #{e.message}")
    {}
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

  # Check if a swimmer (from phase3) has missing critical data
  # Returns hash with { missing_gender: bool, missing_year: bool, not_found: bool }
  # Uses partial key matching to handle different key formats
  #
  # @param swimmer_key [String] the swimmer key to check
  # @param swimmers_by_key [Hash] swimmers indexed by key (from phase3)
  # @return [Hash] { missing_gender: bool, missing_year: bool, not_found: bool }
  def swimmer_has_missing_data?(swimmer_key, swimmers_by_key: {})
    return { missing_gender: false, missing_year: false, not_found: true } unless swimmers_by_key.present? && swimmer_key

    # First try exact match
    swimmer = swimmers_by_key[swimmer_key]

    # If not found, try partial key matching (ignoring gender prefix)
    unless swimmer
      partial_key = normalize_swimmer_key_for_lookup(swimmer_key)
      if partial_key
        swimmer = swimmers_by_key.values.find do |s|
          normalize_swimmer_key_for_lookup(s['key']) == partial_key
        end
      end
    end

    # If swimmer not found in Phase 3, this is an issue
    return { missing_gender: true, missing_year: false, not_found: true } unless swimmer

    {
      missing_gender: swimmer['gender_type_code'].blank?,
      missing_year: swimmer['year_of_birth'].blank? || swimmer['year_of_birth'].to_i.zero?,
      not_found: false
    }
  end

  # Normalize swimmer key to partial format for matching
  # Input: "M|LIGABUE|Marco|1971" or "LIGABUE|Marco|1971"
  # Output: "|LIGABUE|Marco|1971"
  def normalize_swimmer_key_for_lookup(key)
    return nil if key.blank?

    parts = key.to_s.split('|')
    return nil if parts.size < 3

    if parts[0].match?(/\A[MF]?\z/i)
      # Format: G|LAST|FIRST|YOB or |LAST|FIRST|YOB
      "|#{parts[1]}|#{parts[2]}|#{parts[3]}"
    else
      # Format: LAST|FIRST|YOB (no gender prefix)
      "|#{parts[0]}|#{parts[1]}|#{parts[2]}"
    end
  end

  # NOTE: build_phase3_category_issues_summary was removed.
  # Category issues are now detected and shown via RelayEnrichmentDetector
  # which includes missing_category in its issue detection.

  # Check if a relay result has any swimmers with missing data
  # Returns { has_issues: bool, issue_count: int, issues: { swimmer_key => {...} } }
  #
  # @param relay_result [DataImportMeetingRelayResult] the relay result to check
  # @param relay_swimmers_by_key [Hash] relay swimmers grouped by parent import_key
  # @param swimmers_by_id [Hash] swimmers indexed by ID
  # @param swimmers_by_key [Hash] swimmers indexed by key (from phase3)
  # @return [Hash] { has_issues: bool, issue_count: int, issues: {...} }
  def relay_result_has_issues?(relay_result, relay_swimmers_by_key:, swimmers_by_id:, swimmers_by_key: {})
    relay_swimmers = relay_swimmers_by_key[relay_result.import_key] || []
    issues = {}

    relay_swimmers.each do |rs|
      # Check both matched swimmers (via swimmer_id) and unmatched (via swimmer_key in phase3)
      if rs.swimmer_id
        swimmer = swimmers_by_id[rs.swimmer_id]
        next unless swimmer

        missing_gender = swimmer.gender_type_id.blank?
        missing_year = swimmer.year_of_birth.blank? || swimmer.year_of_birth.to_i.zero?

        if missing_gender || missing_year
          issues[rs.relay_order] = {
            swimmer_key: "#{swimmer.last_name}|#{swimmer.first_name}|#{swimmer.year_of_birth}",
            missing_gender: missing_gender,
            missing_year: missing_year
          }
        end
      else
        # Unmatched swimmer - check phase3 data via swimmer_key
        swimmer_key = rs.swimmer_key
        swimmer_issues = swimmer_has_missing_data?(swimmer_key, swimmers_by_key: swimmers_by_key)

        if swimmer_issues[:missing_gender] || swimmer_issues[:missing_year]
          issues[rs.relay_order] = {
            swimmer_key: swimmer_key,
            missing_gender: swimmer_issues[:missing_gender],
            missing_year: swimmer_issues[:missing_year]
          }
        end
      end
    end

    {
      has_issues: issues.any?,
      issue_count: issues.size,
      issues: issues
    }
  end

  # Paginate Phase 5 programs to prevent UI slowdown
  # Splits programs across pages when total rows (results + laps) exceed limit
  #
  # @param programs [Array<Hash>] all programs from phase5 JSON
  # @param page [Integer] current page number (1-indexed)
  # @return [Array<Array, Integer>] [programs_for_page, total_pages]
  def paginate_phase5_programs(programs, page)
    return [programs, 1] if programs.empty?

    # Calculate row count for each program (results + laps)
    programs_with_counts = programs.map do |prog|
      program_key = "#{prog['session_order']}-#{prog['event_code']}-#{prog['category_code']}-#{prog['gender_code']}"

      if prog['relay']
        # Count relay results and relay laps
        result_count = GogglesDb::DataImportMeetingRelayResult
                       .where('import_key LIKE ?', "#{program_key}/%")
                       .count
        lap_count = GogglesDb::DataImportRelayLap
                    .joins('INNER JOIN data_import_meeting_relay_results ON data_import_relay_laps.parent_import_key = data_import_meeting_relay_results.import_key')
                    .where('data_import_meeting_relay_results.import_key LIKE ?', "#{program_key}/%")
                    .count
      else
        # Count individual results and laps
        result_count = GogglesDb::DataImportMeetingIndividualResult
                       .where('import_key LIKE ?', "#{program_key}/%")
                       .count
        lap_count = GogglesDb::DataImportLap
                    .joins('INNER JOIN data_import_meeting_individual_results ON data_import_laps.parent_import_key = data_import_meeting_individual_results.import_key')
                    .where('data_import_meeting_individual_results.import_key LIKE ?', "#{program_key}/%")
                    .count
      end

      { program: prog, row_count: result_count + lap_count }
    end

    # Split programs into pages based on PHASE5_MAX_ROWS_PER_PAGE
    pages = []
    current_page_programs = []
    current_page_rows = 0

    programs_with_counts.each do |prog_data|
      # If adding this program exceeds limit, start new page
      if current_page_rows.positive? && (current_page_rows + prog_data[:row_count]) > PHASE5_MAX_ROWS_PER_PAGE
        pages << current_page_programs
        current_page_programs = []
        current_page_rows = 0
      end

      current_page_programs << prog_data[:program]
      current_page_rows += prog_data[:row_count]
    end

    # Add last page if not empty
    pages << current_page_programs unless current_page_programs.empty?

    # Return programs for requested page
    total_pages = [pages.size, 1].max
    page_index = [[page - 1, 0].max, total_pages - 1].min
    [pages[page_index] || [], total_pages]
  end

  # Sort programs by event order from phase4
  # Individual events come first (sorted by session_order, event_order), then relays
  #
  # @param programs [Array<Hash>] programs from phase5 JSON
  # @param phase4_path [String] path to phase4 JSON file
  # @return [Array<Hash>] sorted programs
  def sort_programs_by_event_order(programs, phase4_path)
    return programs unless File.exist?(phase4_path)

    # Build event order map: {session_order => {event_key => event_order}}
    phase4_json = JSON.parse(File.read(phase4_path))
    sessions = phase4_json.dig('data', 'sessions') || []

    event_order_map = {}
    sessions.each do |session|
      session_order = session['session_order'].to_i
      event_order_map[session_order] ||= {}
      (session['events'] || []).each do |event|
        event_order_map[session_order][event['key']] = event['event_order'].to_i
      end
    end

    # Sort programs: individual first, then relay; within each group by session_order and event_order
    programs.sort_by do |prog|
      session_order = prog['session_order'].to_i
      event_code = prog['event_code'].to_s
      event_order = event_order_map.dig(session_order, event_code) || 9999
      is_relay = prog['relay'] ? 1 : 0

      [is_relay, session_order, event_order, prog['category_code'].to_s, prog['gender_code'].to_s]
    end
  rescue JSON::ParserError
    programs
  end

  # Load minimal data needed for filtering programs
  # Loads only what's necessary to detect issues without loading full display data
  #
  # @param source_path [String] source file path
  # @return [Hash] { relay_swimmers_by_parent_key:, swimmers_by_id:, swimmers_by_key: }
  def load_filter_data(source_path)
    # Load phase3 data for unmatched swimmer lookup
    # Index by both full key AND partial key for flexible matching
    phase3_path = default_phase_path_for(source_path, 3)
    swimmers_by_key = {}
    if File.exist?(phase3_path)
      phase3_data = JSON.parse(File.read(phase3_path))
      swimmers = phase3_data.dig('data', 'swimmers') || []
      swimmers.each do |s|
        # Index by full key
        swimmers_by_key[s['key']] = s
        # Also index by partial key (without leading pipe) for flexible lookup
        partial_key = normalize_swimmer_key_for_lookup(s['key'])
        next unless partial_key

        swimmers_by_key[partial_key] = s
        # And without leading pipe
        swimmers_by_key[partial_key.sub(/^\|/, '')] = s
      end
    end

    # Load relay swimmers grouped by parent key
    relay_swimmers_by_parent_key = GogglesDb::DataImportMeetingRelaySwimmer
                                   .where(phase_file_path: source_path)
                                   .order(:relay_order)
                                   .group_by(&:parent_import_key)

    # Load swimmers by ID for BOTH individual AND relay results
    individual_swimmer_ids = GogglesDb::DataImportMeetingIndividualResult
                             .where(phase_file_path: source_path)
                             .pluck(:swimmer_id)
                             .compact.uniq
    relay_swimmer_ids = relay_swimmers_by_parent_key.values.flatten.filter_map(&:swimmer_id).uniq
    all_swimmer_ids = (individual_swimmer_ids + relay_swimmer_ids).uniq
    swimmers_by_id = GogglesDb::Swimmer.where(id: all_swimmer_ids).index_by(&:id)

    {
      relay_swimmers_by_parent_key: relay_swimmers_by_parent_key,
      swimmers_by_id: swimmers_by_id,
      swimmers_by_key: swimmers_by_key
    }
  end

  # Detect programs with issues (missing swimmer data, unmatched swimmers, etc.)
  # Run server-side BEFORE pagination to provide accurate issue counts
  #
  # @param programs [Array<Hash>] all programs from phase5 JSON
  # @param filter_data [Hash] data needed for filtering
  # @return [Array<Hash>] programs with at least one result with issues
  def detect_programs_with_issues(programs, filter_data)
    relay_swimmers_by_parent_key = filter_data[:relay_swimmers_by_parent_key]
    swimmers_by_id = filter_data[:swimmers_by_id]
    swimmers_by_key = filter_data[:swimmers_by_key]

    programs.select do |prog|
      program_key = "#{prog['session_order']}-#{prog['event_code']}-#{prog['category_code']}-#{prog['gender_code']}"

      if prog['relay']
        # Check if any relay results in this program have issues
        relay_results = GogglesDb::DataImportMeetingRelayResult
                        .where('import_key LIKE ?', "#{program_key}/%")

        relay_results.any? do |mrr|
          issue_info = relay_result_has_issues?(
            mrr,
            relay_swimmers_by_key: relay_swimmers_by_parent_key,
            swimmers_by_id: swimmers_by_id,
            swimmers_by_key: swimmers_by_key
          )
          issue_info[:has_issues]
        end
      else
        # Check if any individual results in this program have issues
        individual_results = GogglesDb::DataImportMeetingIndividualResult
                             .where('import_key LIKE ?', "#{program_key}/%")

        individual_results.any? do |mir|
          result_has_issues?(mir, swimmers_by_id: swimmers_by_id, swimmers_by_key: swimmers_by_key)
        end
      end
    end
  end

  # Check if an individual result has issues (missing swimmer data or unmatched swimmer)
  # Issues include:
  #   - swimmer_id is nil (unmatched swimmer)
  #   - matched swimmer missing gender or year of birth
  #   - unmatched swimmer in Phase 3 missing gender
  #
  # @param mir [DataImportMeetingIndividualResult] the individual result to check
  # @param swimmers_by_id [Hash] swimmers indexed by ID
  # @param swimmers_by_key [Hash] swimmers indexed by key (from phase3)
  # @return [Boolean] true if result has issues
  def result_has_issues?(mir, swimmers_by_id:, swimmers_by_key:)
    if mir.swimmer_id
      # Matched swimmer - check if missing gender or year
      swimmer = swimmers_by_id[mir.swimmer_id]
      return false unless swimmer # If swimmer not found in lookup, skip (data loading issue)

      swimmer.gender_type_id.nil? || swimmer.year_of_birth.nil?
    else
      # Unmatched swimmer - check Phase 3 data for missing gender
      return true if mir.swimmer_key.blank? # No key = definite issue

      swimmer_issues = swimmer_has_missing_data?(mir.swimmer_key, swimmers_by_key: swimmers_by_key)
      swimmer_issues[:missing_gender] || swimmer_issues[:missing_year] || swimmer_issues[:not_found]
    end
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
  #-- -------------------------------------------------------------------------
  #++

  # Returns a valid progressive counter that can be used as a leading file name part to
  # respect their creation order.
  #
  # Takes in consideration both the 'results.new' & the 'results.sent' sub-folders so that
  # the next computed file counter is in continuous progression relative to the whole
  # push process. (That is, the counter should reset only after all the files are processed
  # and moved to the 'results.done' folder.)
  #
  # Assumes files have to be processed in order and moved sequentially:
  # 1) 'results.new'  |=> 'results.sent' (staging phase)
  # 2) 'results.sent' |=> 'results.done' (production phase)
  #
  # === Params:
  # - <tt>curr_dir</tt> => current working folder (typically "crawler/data/results.new/<SEASON_ID>")
  # - <tt>sent_dir</tt> => folder storing the files already processed or sent (typically "crawler/data/results.sent/<SEASON_ID>")
  # - <tt>extension</tt> => file extension of the processed files including wildchar (defaults to '*.sql')
  #
  def compute_file_counter(curr_dir, sent_dir, extension = '*.sql')
    # Prepare a sequential counter prefix for the uploadable batch file:
    curr_count = Rails.root.glob("#{curr_dir}/**/#{extension}").count
    sent_count = Rails.root.glob("#{sent_dir}/**/#{extension}").count
    last_counter = if curr_count.positive?
                     File.basename(Rails.root.glob("#{curr_dir}/**/#{extension}").max).split('-').first.to_i
                   elsif sent_count.positive?
                     File.basename(Rails.root.glob("#{sent_dir}/**/#{extension}").max).split('-').first.to_i
                   else
                     0
                   end
    # In case the saved files didn't contain a leading progressive counter in their name, use the file count:
    last_counter = curr_count + sent_count if last_counter.zero?
    last_counter
  end
  #-- -------------------------------------------------------------------------
  #++
end
