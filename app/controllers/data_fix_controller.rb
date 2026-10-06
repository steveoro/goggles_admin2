# frozen_string_literal: true

require 'date'
require 'pathname'
require 'json'

# = DataFixController: phased pipeline (v2)
#
# Delegates to the new phased solvers when an action-level flag is present; otherwise
# redirects to legacy controller actions to preserve current behavior.
#
# THESE will be addressed in a future refactoring:
# rubocop:disable-next Metrics/ParameterLists
class DataFixController < ApplicationController
  include FileCounter

  # @api_url is only needed by actions that render review views.
  before_action :set_api_url, only: %i[review_sessions review_teams review_swimmers review_events
                                       review_results commit_phase6_report]

  # Resolves @file_path → @source_path for every action taking a file_path param.
  # (Actions with different params or custom error handling manage their own checks.)
  before_action :set_source_path, except: %i[commit_phase6_report purge coded_name teams_for_swimmer
                                             verify_result confirm_result_duplicate verify_team
                                             results_chunk_v2
                                             update_individual_result_overwrite_candidate
                                             update_individual_result_merge_candidate
                                             bulk_update_individual_result_overwrite]

  TURBO_FILTER_MIN_QUERY_LENGTH = 3

  # Expose issue detection helpers to views
  helper_method :swimmer_has_missing_data?, :relay_result_has_issues?, :phase3_conflict_hint?

  def review_sessions
    return if params[:phase_v2].blank?

    source_path = @source_path
    @season = source_resolver.detect_season_from_pathname(source_path)
    lt_format = source_resolver.detect_layout_type(source_path)
    # Use existing phase file unless rescan is requested; build when missing or rescan
    phase_path = source_resolver.default_phase_path_for(source_path, 1)
    return unless ensure_phase_file!(phase_path: phase_path, phase: 1,
                                     review_path: method(:review_sessions_path)) do
      Import::Solvers::Phase1Solver.new(season: @season).build!(
        source_path: source_path,
        lt_format: lt_format
      )
    end
    @retry_needed = source_resolver.sync_phase_retry_flag!(phase_path: phase_path, source_path: source_path)
    pfm = PhaseFileManager.new(phase_path)
    @phase1_meta = pfm.meta
    @phase1_data = pfm.data

    # Field-level validation cues (non-blocking): highlight missing/invalid
    # required fields in the meeting & session cards below.
    @structure_report = Import::StructureValidator.new(phase1_data: @phase1_data)

    # Extraction-time warnings carried in the LT4 source _meta (e.g. unknown
    # event codes, suspicious dates) - visible here so the operator reviews
    # them before committing anything.
    @source_warnings = Array(source_resolver.parsed_source_json(source_path).dig('_meta', 'warnings'))

    # Fetch existing meeting sessions if meeting_id is present
    meeting_id = @phase1_data['id']
    @existing_meeting_sessions = []
    return if meeting_id.blank?

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
  # ---------------------------------------------------------------------------

  def recompute_source_categories
    file_path = @file_path
    source_path = @source_path
    phase1_path = source_resolver.default_phase_path_for(source_path, 1)
    phase1_data = PhaseFileManager.new(phase1_path).data
    season_id = phase1_data['season_id'] || source_resolver.detect_season_from_pathname(source_path)&.id
    season = GogglesDb::Season.find_by(id: season_id)
    meeting_date = phase1_data['header_date'].presence || source_resolver.source_meeting_date(source_path)

    unless season && meeting_date.present?
      flash[:error] = I18n.t('data_import.errors.category_recompute_missing_inputs')
      redirect_to(review_sessions_path(file_path: source_path, phase_v2: 1)) && return
    end

    cache = PdfResults::CategoriesCache.cached_for(season)
    result = DataFix::CategoryRecomputer.new(
      source_path: source_path,
      season: season,
      meeting_date: meeting_date,
      categories_cache: cache,
      progress: ->(message, current, total) { broadcast_progress(message, current, total) }
    ).call

    invalidated = result[:backup_path].present? ? source_resolver.invalidate_category_dependent_artifacts(source_path) : []
    result[:invalidated_artifacts] = invalidated
    flash[:notice] = {
      body: source_resolver.category_recompute_summary(result),
      sticky: true
    }
    redirect_to(review_sessions_path(file_path: source_path, phase_v2: 1))
  rescue DataFix::CategoryRecomputer::InvalidSource => e
    flash[:error] = e.message
    redirect_to(review_sessions_path(file_path: source_path || file_path, phase_v2: 1))
  rescue StandardError => e
    Rails.logger.error("[DataFixController] category recomputation failed: #{e.class}: #{e.message}")
    flash[:error] = I18n.t('data_import.errors.category_recompute_failed')
    redirect_to(review_sessions_path(file_path: source_path || file_path, phase_v2: 1))
  end
  # ---------------------------------------------------------------------------

  def review_teams
    redirect_to(review_teams_legacy_path(request.query_parameters)) && return if params[:phase2_v2].blank?

    source_path = @source_path
    season = source_resolver.detect_season_from_pathname(source_path)
    lt_format = source_resolver.detect_layout_type(source_path)
    phase_path = source_resolver.default_phase_path_for(source_path, 2)
    return unless ensure_phase_file!(phase_path: phase_path, phase: 2,
                                     review_path: method(:review_teams_path)) do
      Import::Solvers::TeamSolver.new(season:).build!(
        source_path: source_path,
        lt_format: lt_format
      )
    end
    @retry_needed = source_resolver.sync_phase_retry_flag!(phase_path: phase_path, source_path: source_path)
    pfm = PhaseFileManager.new(phase_path)
    @phase2_meta = pfm.meta
    @phase2_data = pfm.data

    # Safety: rebuild Phase 2 file if teams dictionary is missing (older generator or corrupted file).
    # NOTE: an empty array is a valid result for meeting-only sources - only a missing key triggers the rebuild.
    if @phase2_data['teams'].nil?
      Import::Solvers::TeamSolver.new(season:).build!(
        source_path: source_path,
        lt_format: lt_format
      )
      redirect_to(review_teams_path(request.query_parameters.merge(file_path: @file_path)),
                  notice: I18n.t('data_import.messages.phase_rebuilt', phase: 2)) && return
    end

    teams_state_cookie_scope = data_fix_review_cookie_scope(prefix: 'teams', file_path: @file_path)

    teams = Array(@phase2_data['teams'])
    apply_review_filters(
      collection: teams,
      prefix: 'teams',
      cookie_scope: teams_state_cookie_scope,
      default_per_page: 50,
      text_fields: %w[name editable_name name_variations key]
    ) do |list, state|
      case state
      # Filter teams needing review: unmatched (no team_id) OR match < 89% (yellow/red matches)
      # OR similar affiliated team found in season (cross-ref warning)
      # OR phase3-derived conflict hints found for this team
      # This shows ALL teams that need manual verification at a glance
      when 'review'
        list.select do |t|
          # WARNING: adding the 'similar_on_team' check will yield false positives and basically make the filtering useless
          t['team_id'].nil? || (t['match_percentage'] || 0.0) < 89.0 || phase3_conflict_hint?(t) # || t['similar_affiliated'] == true
        end
      # Filter teams where the edited name differs from the original import key
      when 'diff_key'
        list.select do |t|
          editable = t['editable_name'].to_s.strip.downcase
          name = t['name'].to_s.strip.downcase
          key = t['key'].to_s.strip.downcase
          (editable.present? && editable != key) || (name.present? && name != key)
        end
      else
        list
      end
    end

    # Broadcast ready status to clear progress modal
    broadcast_progress('Review teams: ready', @total_count, @total_count)
  end
  # ---------------------------------------------------------------------------

  def review_swimmers
    redirect_to(review_swimmers_legacy_path(request.query_parameters)) && return if params[:phase3_v2].blank?

    source_path = @source_path
    season = source_resolver.detect_season_from_pathname(source_path)
    categories_cache = PdfResults::CategoriesCache.cached_for(season)
    lt_format = source_resolver.detect_layout_type(source_path)
    phase_path = source_resolver.default_phase_path_for(source_path, 3)
    return unless ensure_phase_file!(phase_path: phase_path, phase: 3,
                                     review_path: method(:review_swimmers_path)) do
      Import::Solvers::SwimmerSolver.new(season:, categories_cache:).build!(
        source_path: source_path,
        lt_format: lt_format,
        phase1_path: source_resolver.default_phase_path_for(source_path, 1),
        phase2_path: source_resolver.default_phase_path_for(source_path, 2)
      )
    end
    @retry_needed = source_resolver.sync_phase_retry_flag!(phase_path: phase_path, source_path: source_path)
    pfm = PhaseFileManager.new(phase_path)
    @phase3_meta = pfm.meta
    @phase3_data = pfm.data

    # Safety: rebuild Phase 3 file if swimmers dictionary is missing (older generator or corrupted file)
    if @phase3_data['swimmers'].nil?
      phase1_path = source_resolver.default_phase_path_for(source_path, 1)
      phase2_path = source_resolver.default_phase_path_for(source_path, 2)
      Import::Solvers::SwimmerSolver.new(season:, categories_cache:).build!(
        source_path: source_path,
        lt_format: lt_format,
        phase1_path: phase1_path,
        phase2_path: phase2_path
      )
      redirect_to(review_swimmers_path(request.query_parameters.merge(file_path: @file_path)),
                  notice: I18n.t('data_import.messages.phase_rebuilt', phase: 3)) && return
    end
    @source_path = source_path
    base_dir = File.dirname(source_path)

    # Extract season and meeting date for category computation
    season = source_resolver.detect_season_from_pathname(source_path)
    phase1_path = source_resolver.default_phase_path_for(source_path, 1)
    meeting_date = if File.exist?(phase1_path)
                     PhaseFileManager.new(phase1_path).data&.dig('meeting', 'header_date')
                   end

    detector = Phase3::RelayEnrichmentDetector.new(
      source_path: source_path,
      phase3_swimmers: @phase3_data.fetch('swimmers', []),
      season: season,
      meeting_date: meeting_date,
      categories_cache:
    )
    @show_new_relay_swimmers = params[:show_new_relay_swimmers].present?
    @relay_enrichment_summary = DataFix::RelayEnrichmentFilter.filter_relay_enrichment_summary(detector.detect, @show_new_relay_swimmers, @phase3_data)
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

    swimmers_state_cookie_scope = data_fix_review_cookie_scope(prefix: 'swimmers', file_path: @file_path)

    consistency_stats = DataFix::Phase3Harmonizer.harmonize_phase2_phase3_team_links(source_path: source_path, season_id: season.id)
    if consistency_stats.values.sum.positive?
      summary = []
      summary << "#{consistency_stats[:phase2_conflicts_detected]} conflict(s) detected" if consistency_stats[:phase2_conflicts_detected].positive?
      summary << "#{consistency_stats[:phase2_missing_links_detected]} missing link(s) detected" if consistency_stats[:phase2_missing_links_detected].positive?
      summary << "#{consistency_stats[:phase2_conflict_hints_added]} hint candidate(s) added" if consistency_stats[:phase2_conflict_hints_added].positive?
      flash.now[:notice] = { body: "Cross-phase review: #{summary.join(', ')}.", sticky: true }
    end

    swimmers = Array(@phase3_data['swimmers'])
    duplicate_summary = DataFix::Phase3Harmonizer.annotate_swimmer_badge_duplicates!(swimmers)
    if duplicate_summary[:swimmers_with_duplicates].positive?
      flash.now[:warning] = {
        body: "#{duplicate_summary[:swimmers_with_duplicates]} swimmer(s) show duplicate badges in season(s): #{duplicate_summary[:duplicate_seasons].join(', ')}",
        sticky: true
      }
    end

    apply_review_filters(
      collection: swimmers,
      prefix: 'swimmers',
      cookie_scope: swimmers_state_cookie_scope,
      default_per_page: 100,
      text_fields: %w[last_name first_name complete_name key]
    ) do |list, state|
      case state
      # Filter swimmers needing review: unmatched (no swimmer_id) OR match < 89% (yellow/red matches)
      # OR similar name found on same team (cross-ref warning)
      # OR duplicate badges found in same season with different team_id (manual merge red flag)
      # OR auto-assigned from secondary match due to team priority
      # This shows ALL swimmers that need manual verification at a glance
      when 'review'
        list.select do |s|
          # WARNING: adding the 'similar_on_team' check will yield false positives and basically make the filtering useless
          s['swimmer_id'].nil? || (s['match_percentage'] || 0.0) < 89.0 || s['has_badge_duplicates'] == true || s['auto_assigned_from_secondary_match'] == true
        end
      # Filter swimmers where the current name differs from the original import key
      when 'diff_key'
        list.reject do |s|
          complete_name = s['complete_name'].to_s.strip.downcase
          # Extract LAST|FIRST from key by stripping gender prefix, YOB, and team token
          key_name = s['key'].to_s.sub(/^[MF]\|/i, '').split('|').first(2).join(' ').strip.downcase
          complete_name == key_name
        end
      else
        list
      end
    end

    # Broadcast ready status to clear progress modal
    broadcast_progress('Review swimmers: ready', @total_count, @total_count)
  end
  # ---------------------------------------------------------------------------

  def review_events
    return if params[:phase4_v2].blank?

    source_path = @source_path
    season = source_resolver.detect_season_from_pathname(source_path)
    lt_format = source_resolver.detect_layout_type(source_path)
    phase_path = source_resolver.default_phase_path_for(source_path, 4)
    return unless ensure_phase_file!(phase_path: phase_path, phase: 4,
                                     review_path: method(:review_events_path)) do
      Import::Solvers::EventSolver.new(season:).build!(
        source_path: source_path,
        lt_format: lt_format,
        phase1_path: source_resolver.default_phase_path_for(source_path, 1)
      )
    end
    @retry_needed = source_resolver.sync_phase_retry_flag!(phase_path: phase_path, source_path: source_path)
    pfm = PhaseFileManager.new(phase_path)
    @phase4_meta = pfm.meta
    @phase4_data = pfm.data

    # Build sessions list for dropdown from Phase 1 (edited sessions) or fallback to Phase 4
    phase1_path = source_resolver.default_phase_path_for(source_path, 1)
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

    # Heat types for the per-event card select (tiny immutable table; loaded once)
    @heat_types = GogglesDb::HeatType.all

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
            'begin_time' => me.begin_time&.to_fs(:time)
          }
        end
      end
    end

    # Flatten all events across Phase 4 sessions with session tracking.
    # Display is sorted by session/event order, but we preserve original array indexes
    # so update/delete actions point to the actual event stored in JSON.
    @all_events = []
    sessions_with_index = Array(@phase4_data['sessions']).each_with_index.to_a
    sessions_with_index.sort_by! { |(session, _idx)| session['session_order'].to_i }

    sessions_with_index.each do |session, original_session_idx|
      session_order = session['session_order'] || (original_session_idx + 1)
      events_with_index = Array(session['events']).each_with_index.to_a
      events_with_index.sort_by! { |(event, original_event_idx)| [event['event_order'].to_i, original_event_idx] }

      events_with_index.each do |event, original_event_idx|
        @all_events << event.merge(
          '_session_index' => original_session_idx,
          '_event_index' => original_event_idx,
          '_session_order' => session_order
        )
      end
    end
  end
  # ---------------------------------------------------------------------------

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
  # ---------------------------------------------------------------------------

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
  # ---------------------------------------------------------------------------

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
  # ---------------------------------------------------------------------------

  # Deletes all Data-Fix v2 temporary rows from data_import_* tables.
  # Intended as an operator "clean slate" action from dashboard.
  def purge
    session_count = GogglesDb::DataImportMeetingIndividualResult
                    .where.not(phase_file_path: [nil, ''])
                    .distinct
                    .count(:phase_file_path)

    deleted = {}
    ActiveRecord::Base.transaction do
      deleted[:laps] = GogglesDb::DataImportLap.delete_all
      deleted[:relay_laps] = GogglesDb::DataImportRelayLap.delete_all
      deleted[:relay_swimmers] = GogglesDb::DataImportMeetingRelaySwimmer.delete_all
      deleted[:relay_results] = GogglesDb::DataImportMeetingRelayResult.delete_all
      deleted[:individual_results] = GogglesDb::DataImportMeetingIndividualResult.delete_all
    end

    total_deleted = deleted.values.sum
    flash[:notice] =
      "Clean slate completed: removed #{total_deleted} temp rows across #{deleted.size} tables " \
      "(#{session_count} session(s) from phase_file_path)."
  rescue StandardError => e
    flash[:error] = "Clean slate failed: #{e.message}"
  ensure
    redirect_to(home_index_path)
  end
  # ---------------------------------------------------------------------------

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
  # ---------------------------------------------------------------------------

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
  # ---------------------------------------------------------------------------

  # AJAX endpoint: cross-validate a Phase 2 team match using swimmer badges from Phase 3.
  # Returns JSON with confidence score and swimmer badge details.
  def verify_team
    file_path = params[:file_path]
    team_key = params[:team_key]
    candidate_team_id = params[:candidate_team_id].to_i

    unless file_path.present? && team_key.present? && candidate_team_id.positive?
      render json: { error: 'Missing required params' }, status: :unprocessable_content
      return
    end

    source_path = source_resolver.resolve_working_source_path(file_path)
    phase3_path = source_resolver.default_phase_path_for(source_path, 3)

    unless File.exist?(phase3_path)
      render json: { error: 'Phase 3 file not found. Please run Phase 3 (Swimmers) first.' }, status: :not_found
      return
    end

    phase3_pfm = PhaseFileManager.new(phase3_path)
    phase3_data = phase3_pfm.data || {}
    season_id = phase3_data['season_id'] || source_resolver.detect_season_from_pathname(source_path)&.id

    checker = Import::Verification::TeamSwimmerChecker.new(phase3_data: phase3_data, season_id: season_id)
    result = checker.check(team_key: team_key, candidate_team_id: candidate_team_id)

    render json: result
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

  # Update a single Phase 2 team entry by key
  def update_phase2_team
    file_path = @file_path
    source_path = @source_path
    team_key = params[:team_key]
    if team_key.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    phase_path = source_resolver.default_phase_path_for(source_path, 2)
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
    old_team_id = t['team_id'] # Capture before update for cascade detection

    # Handle direct params from form (team[field])
    # Note: AutoComplete component adds extra fields (team, city, area) which we permit but ignore
    team_params = params[:team]
    permitted = ActionController::Parameters.new
    if team_params.is_a?(ActionController::Parameters)
      permitted = team_params.permit(:team_id, :editable_name, :name, :name_variations, :city_id,
                                     :team, :city, :area)

      # Update team_id (from AutoComplete)
      if permitted.key?(:team_id)
        team_num = permitted[:team_id].to_i
        t['team_id'] = team_num.positive? ? team_num : nil
      end

      # Update text fields
      t['editable_name'] = sanitize_str(permitted[:editable_name]) if permitted.key?(:editable_name)
      t['name'] = sanitize_str(permitted[:name]) if permitted.key?(:name)
      t['name_variations'] = sanitize_str(permitted[:name_variations]) if permitted.key?(:name_variations)
    end

    city_widget_params = params["team_#{team_index}_city"]
    city_widget_value = (city_widget_params.permit(:city_id)[:city_id] if city_widget_params.is_a?(ActionController::Parameters))

    # Update city_id (from hidden binding field or city widget fallback).
    # Explicit blank from the city widget means user requested unmatch.
    if city_widget_value.is_a?(String) && city_widget_value.strip.empty?
      t['city_id'] = nil
    elsif permitted.key?(:city_id)
      city_num = permitted[:city_id].to_i
      t['city_id'] = city_num.positive? ? city_num : nil
    elsif city_widget_value.present?
      city_num = city_widget_value.to_i
      t['city_id'] = city_num.positive? ? city_num : nil
    end

    teams[team_index] = t
    # Keep team_affiliations in sync with team edits (team_id/manual selections)
    affiliations = Array(data['team_affiliations'])
    season_id = data['season_id'] || params[:season_id]
    aff_index = affiliations.find_index { |a| a['team_key'] == team_key }
    if aff_index
      affiliations[aff_index]['team_id'] = t['team_id']
      affiliations[aff_index]['season_id'] ||= season_id
    else
      affiliations << {
        'team_key' => team_key,
        'season_id' => season_id,
        'team_id' => t['team_id'],
        'team_affiliation_id' => nil
      }
      aff_index = affiliations.size - 1
    end

    aff_row = affiliations[aff_index]
    resolved_affiliation_id = nil
    if t['team_id'].to_i.positive? && season_id.to_i.positive?
      resolved_affiliation_id = GogglesDb::TeamAffiliation.find_by(team_id: t['team_id'], season_id: season_id)&.id
    end
    # Always overwrite with deterministic resolution (or nil) to avoid stale bindings.
    aff_row['team_affiliation_id'] = resolved_affiliation_id

    data['team_affiliations'] = affiliations
    data['teams'] = teams

    meta = pfm.meta || {}
    pfm.write!(data: data, meta: meta)

    # Cascade team binding updates to Phase 3 badges and Phase 5 DataImport rows
    phase3_path = source_resolver.default_phase_path_for(source_path, 3)
    new_team_id = t['team_id']
    if File.exist?(phase3_path)
      cascade_count = DataFix::TeamCascade.cascade_team_to_phase3(phase3_path, team_key, new_team_id, season_id)
      phase3_badges = Array(PhaseFileManager.new(phase3_path).data&.dig('badges'))
      cascade_count += DataFix::TeamCascade.cascade_team_to_data_import_rows(
        team_key,
        new_team_id,
        season_id,
        phase_file_path: source_path,
        phase2_affiliations: affiliations,
        phase3_badges: phase3_badges
      )
      flash[:info] = "Team updated. Cascaded team_id to #{cascade_count} downstream record(s)." if cascade_count.positive?
    elsif old_team_id != new_team_id
      cascade_count = DataFix::TeamCascade.cascade_team_to_data_import_rows(
        team_key,
        new_team_id,
        season_id,
        phase_file_path: source_path,
        phase2_affiliations: affiliations
      )
      flash[:info] = "Team updated. Cascaded team_id to #{cascade_count} downstream record(s)." if cascade_count.positive?
    end

    # Preserve pagination and filter params
    redirect_params = review_redirect_params(v2_flag: :phase2_v2,
                                             keep: %i[teams_page teams_per_page q filter_state])

    redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end

  # Create a new blank team entry in Phase 2 and redirect back to v2 view
  def add_team
    file_path = @file_path
    source_path = @source_path
    phase_path = source_resolver.default_phase_path_for(source_path, 2)
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
    pfm.write!(data: data, meta: meta)

    redirect_params = review_redirect_params(v2_flag: :phase2_v2,
                                             keep: %i[teams_page teams_per_page q filter_state])

    redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end

  # Delete a team entry from Phase 2 and clear downstream phase data
  def delete_team
    file_path = @file_path
    source_path = @source_path
    team_key = params[:team_key]

    if team_key.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    phase_path = source_resolver.default_phase_path_for(source_path, 2)
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
    pfm.write!(data: data, meta: meta)

    # Preserve pagination and filter params
    redirect_params = review_redirect_params(v2_flag: :phase2_v2,
                                             keep: %i[teams_page teams_per_page q filter_state])

    redirect_to review_teams_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end

  # Update a single Phase 3 swimmer entry by key
  def update_phase3_swimmer
    file_path = @file_path
    source_path = @source_path
    swimmer_key = params[:swimmer_key]

    if swimmer_key.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    phase_path = source_resolver.default_phase_path_for(source_path, 3)
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
    old_swimmer_id = swimmer['swimmer_id']
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

    # Keep badges in sync with swimmer edits (ID and existing badge lookup)
    badges = Array(data['badges'])
    season_id = data['season_id'] || params[:season_id]
    canonical_swimmer_key = swimmer['key']
    badges.each do |badge|
      bkey = badge['swimmer_key']
      next unless DataFix::SwimmerKey.swimmer_key_match?(bkey, swimmer_key, canonical_swimmer_key)

      badge['swimmer_id'] = swimmer['swimmer_id']
      badge['swimmer_key'] = canonical_swimmer_key if canonical_swimmer_key.present?
      resolved_badge_id = nil
      if swimmer['swimmer_id'].to_i.positive? && badge['team_id'].to_i.positive? && season_id.to_i.positive?
        resolved_badge_id = GogglesDb::Badge.find_by(
          season_id: season_id,
          swimmer_id: swimmer['swimmer_id'],
          team_id: badge['team_id']
        )&.id
      end

      # Always overwrite with deterministic resolution (or nil) to avoid stale bindings.
      badge['badge_id'] = resolved_badge_id
    end
    data['badges'] = badges

    # Clear downstream phase data (phase4+) when swimmers are modified
    data['meeting_event'] = [] if data.key?('meeting_event')
    data['meeting_program'] = [] if data.key?('meeting_program')
    data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
    data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

    meta = pfm.meta || {}
    pfm.write!(data: data, meta: meta)

    cascade_count = DataFix::SwimmerCascade.cascade_swimmer_to_data_import_rows(
      source_path: source_path,
      old_swimmer_key: swimmer_key,
      canonical_swimmer_key: canonical_swimmer_key,
      old_swimmer_id: old_swimmer_id,
      new_swimmer_id: swimmer['swimmer_id'],
      season_id: season_id,
      phase3_badges: badges
    )
    flash[:info] = "Swimmer updated. Cascaded swimmer links to #{cascade_count} downstream record(s)." if cascade_count.positive?

    # Preserve pagination and filter params
    redirect_params = review_redirect_params(v2_flag: :phase3_v2,
                                             keep: %i[swimmers_page swimmers_per_page q filter_state])

    redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end

  # Add a new blank swimmer to Phase 3
  def add_swimmer
    file_path = @file_path
    source_path = @source_path
    phase_path = source_resolver.default_phase_path_for(source_path, 3)
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
    pfm.write!(data: data, meta: meta)

    redirect_params = review_redirect_params(v2_flag: :phase3_v2,
                                             keep: %i[swimmers_page swimmers_per_page q filter_state])

    redirect_to review_swimmers_path(redirect_params), notice: 'Swimmer added' # rubocop:disable Rails/I18nLocaleTexts
  end

  # Merge auxiliary Phase 3 files to enrich relay swimmers
  def merge_phase3_swimmers
    file_path = @file_path
    source_path = @source_path
    selected_paths = Array(params[:auxiliary_paths]).compact_blank
    base_dir = File.dirname(source_path)
    phase_path = source_resolver.default_phase_path_for(source_path, 3)

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

  # Delete a swimmer entry from Phase 3 and clear downstream phase data
  def delete_swimmer
    file_path = @file_path
    source_path = @source_path
    swimmer_key = params[:swimmer_key]

    if swimmer_key.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    phase_path = source_resolver.default_phase_path_for(source_path, 3)
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
    pfm.write!(data: data, meta: meta)

    # Preserve pagination and filter params
    redirect_params = review_redirect_params(v2_flag: :phase3_v2,
                                             keep: %i[swimmers_page swimmers_per_page q filter_state])

    redirect_to review_swimmers_path(redirect_params), notice: I18n.t('data_import.messages.updated')
  end

  # Update a single Phase 4 event entry by session and event index
  # Also handles moving events between sessions via target_session_order
  def update_phase4_event
    file_path = @file_path
    source_path = @source_path
    session_index = params[:session_index]&.to_i
    event_index = params[:event_index]&.to_i
    target_session_order = params[:target_session_order]&.to_i

    if session_index.nil? || event_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    phase_path = source_resolver.default_phase_path_for(source_path, 4)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    sessions = Array(data['sessions'])

    # Load Phase 1 data to get session structure (for creating missing sessions)
    phase1_path = source_resolver.default_phase_path_for(source_path, 1)
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
      event['id'] = str.presence&.to_i
    end

    # Handle event_type_id from AutoComplete
    raw_event_type_id = event_params[:event_type_id]
    unless raw_event_type_id.nil?
      str = raw_event_type_id.to_s.strip
      event['event_type_id'] = str.presence&.to_i
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
    pfm.write!(data: data, meta: meta)

    redirect_to review_events_path(file_path:, phase4_v2: 1), notice: flash_msg
  end

  # Add a new blank event to Phase 4
  def add_event
    file_path = @file_path
    source_path = @source_path
    session_index = params[:session_index].to_i
    event_type_id = params[:event_type_id]&.to_i

    phase_path = source_resolver.default_phase_path_for(source_path, 4)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    sessions = Array(data['sessions'])

    # Load Phase 1 data to get session structure
    phase1_path = source_resolver.default_phase_path_for(source_path, 1)
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

  # Delete an event entry from Phase 4 and clear downstream phase data
  def delete_event
    file_path = @file_path
    source_path = @source_path
    session_index = params[:session_index]&.to_i
    event_index = params[:event_index]&.to_i

    if session_index.nil? || event_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    phase_path = source_resolver.default_phase_path_for(source_path, 4)
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
    pfm.write!(data: data, meta: meta)

    redirect_to review_events_path(file_path:, phase4_v2: 1), notice: I18n.t('data_import.messages.updated')
  end

  # Update Phase 1 meeting attributes in the phase file and redirect back to v2 view
  def update_phase1_meeting
    file_path = @file_path
    source_path = @source_path
    phase_path = source_resolver.default_phase_path_for(source_path, 1)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    old_meeting_id = data['id']

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
        normalized[key] = val.presence&.to_i
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

    # Auto-generate code if not provided but description is present
    if !normalized.key?('code') || normalized['code'].to_s.strip.empty?
      if normalized['name'].present?
        # Use the first session's city name if available, otherwise fall back to address1
        city_name = nil
        if data['meeting_session']&.first
          first_session = data['meeting_session'].first
          city_name = first_session.dig('swimming_pool', 'city', 'name') if first_session['swimming_pool']
        end
        city_name ||= data['address1'] if data['address1'].present?
        city_name ||= ''

        normalized['code'] = GogglesDb::Normalizers::CodedName.for_meeting(
          normalized['name'],
          city_name
        )
      else
        normalized['code'] = ''
      end
    end

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
      # An existing meeting keeps its own manifest flag: the solver-emitted
      # marker applies to newly created meetings only (re-added at commit time
      # by commit_phase6 when no meeting id is selected).
      data.delete('manifest') if data['id'].present?
    end

    # Clear meeting_session if meeting ID changed to force session rebuild
    data['meeting_session'] = [] if old_meeting_id != data['id']

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
    pfm.write!(data: data, meta: meta)

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.updated')
  end

  # Update a session entry in Phase 1 using service object
  def update_phase1_session
    file_path = @file_path
    source_path = @source_path
    session_index = params[:session_index].to_i

    if session_index.negative?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    phase_path = source_resolver.default_phase_path_for(source_path, 1)
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
    file_path = @file_path
    source_path = @source_path
    phase_path = source_resolver.default_phase_path_for(source_path, 1)
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
      'day_part_type_id' => GogglesDb::DayPartType::MORNING_ID,
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
    pfm.write!(data: data, meta: meta)

    redirect_to review_sessions_path(file_path:, phase_v2: 1, new_session_index: new_index), notice: I18n.t('data_import.messages.updated')
  end

  # Delete a session entry from Phase 1 and redirect back to v2 view
  def delete_session
    file_path = @file_path
    source_path = @source_path
    session_index = params[:session_index]&.to_i

    if session_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    phase_path = source_resolver.default_phase_path_for(source_path, 1)
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
    pfm.write!(data: data, meta: meta)

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.deleted')
  end

  # Rebuild meeting_session array from selected meeting using service object
  def rescan_phase1_sessions
    file_path = @file_path
    source_path = @source_path
    phase_path = source_resolver.default_phase_path_for(source_path, 1)
    pfm = PhaseFileManager.new(phase_path)

    # Determine meeting id from params or current data
    meeting_id = params[:meeting_id] || pfm.data&.dig('id')

    rescanner = Phase1SessionRescanner.new(pfm, meeting_id)
    rescanner.call

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.updated')
  end

  # Returns an HTML partial with the detailed results for a specific (event_key, gender, category)
  # in Step 5 v2. This reads from the original source JSON (LT4 expected).
  def results_chunk_v2
    file_path = params[:file_path]
    event_key = params[:event_key].to_s
    gender = params[:gender].to_s
    category = params[:category].to_s
    if file_path.blank? || event_key.blank? || gender.blank? || category.blank?
      return render plain: I18n.t('data_import.errors.invalid_request'), status: :bad_request
    end

    source_path = source_resolver.resolve_working_source_path(file_path)
    begin
      data_hash = source_resolver.parsed_source_json(source_path)
    rescue StandardError => e
      return render plain: e.message, status: :unprocessable_content
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

  private

  # Shared resolver for this request (keeps the parsed_source_json memo hot)
  def source_resolver
    @source_resolver ||= DataFix::SourceResolver.new
  end

  # Resolves @file_path → @source_path (canonical LT4 working copy) for every
  # action taking a file_path param; redirects to the file list when missing.
  def set_source_path
    @file_path = params[:file_path]
    if @file_path.blank?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    @source_path = source_resolver.resolve_working_source_path(@file_path)
    @file_path = @source_path
  end

  # Params hash for redirects back to a phase-review page: the canonical file
  # path + the v2 flag + the preserved pagination/filter params listed in +keep+.
  def review_redirect_params(v2_flag:, keep: [])
    keep.each_with_object({ file_path: @file_path, v2_flag => 1 }) do |key, hash|
      hash[key] = params[key] if params[key].present?
    end
  end

  # Guard for phase-review actions: rebuilds the phase file (via the +rebuild+
  # block) when missing or when a rescan is requested, then redirects back to
  # the same review page minus :rescan. Returns false when a redirect was
  # issued — the caller must return immediately in that case.
  def ensure_phase_file!(phase_path:, phase:, review_path:, &rebuild)
    return true unless params[:rescan].present? || !File.exist?(phase_path)

    rebuild_phase_and_redirect!(phase: phase, review_path: review_path, &rebuild)
    false
  end

  # Runs +rebuild+, then redirects to +review_path+ (a callable returning the
  # review URL for given query params) minus the :rescan flag so that
  # subsequent navigation doesn't trigger another rebuild. The block may
  # return a String to override the default "phase rebuilt" notice.
  def rebuild_phase_and_redirect!(phase:, review_path:, notice: nil)
    built_notice = yield
    notice ||= built_notice if built_notice.is_a?(String)
    query = request.query_parameters.except(:rescan).merge(file_path: @file_path)
    redirect_to(review_path.call(query),
                notice: notice.presence || I18n.t('data_import.messages.phase_rebuilt', phase: phase))
  end

  # Shared filter + pagination block for the phase 2/3 review pages.
  # Sets @filter_state, @q, @page, @per_page, @total_count, @total_pages,
  # @row_range, @items; persists them into the per-file review-state cookie.
  # The block receives (collection, @filter_state) and must return the
  # phase-specific filtered collection (the 'review'/'diff_key' predicates
  # differ per phase); without a block only the text-query filter applies.
  def apply_review_filters(collection:, prefix:, cookie_scope:, default_per_page:, text_fields:)
    @filter_state = data_fix_review_param_or_cookie(param_key: :filter_state, cookie_scope: cookie_scope).to_s
    @filter_state = 'none' unless %w[none review diff_key].include?(@filter_state)
    @q = data_fix_review_param_or_cookie(param_key: :q, cookie_scope: cookie_scope).to_s.strip

    # Filter by search query (ignore if shorter than min chars)
    if @q.present? && @q.length >= TURBO_FILTER_MIN_QUERY_LENGTH
      qd = @q.downcase
      collection = collection.select do |item|
        text_fields.map { |field| item[field] }.compact.any? { |v| v.to_s.downcase.include?(qd) }
      end
    end

    collection = yield(collection, @filter_state) if block_given?

    page_key = "#{prefix}_page".to_sym
    per_page_key = "#{prefix}_per_page".to_sym

    # Reset page to 1 when the filter form is submitted (filter_state or
    # per_page changed without an explicit page param)
    if (params.key?(:filter_state) || params.key?(per_page_key)) && !params.key?(page_key)
      @page = 1
    else
      @page = data_fix_review_param_or_cookie(param_key: page_key, cookie_scope: cookie_scope).to_i
      @page = 1 if @page < 1
    end
    @per_page = data_fix_review_param_or_cookie(param_key: per_page_key, cookie_scope: cookie_scope).to_i
    @per_page = default_per_page if @per_page <= 0
    @total_count = collection.size
    @total_pages = (@total_count.to_f / @per_page).ceil
    @page = @total_pages if @page > @total_pages && @total_pages.positive?
    @row_range = "#{(@page * @per_page) - @per_page + 1}-#{@page * @per_page}"
    @items = Kaminari.paginate_array(collection, total_count: @total_count).page(@page).per(@per_page)

    persist_data_fix_review_state(
      cookie_scope: cookie_scope,
      state: {
        filter_state: @filter_state,
        q: @q,
        page_key => @page,
        per_page_key => @per_page
      }
    )
  end
  def data_fix_review_cookie_scope(prefix:, file_path:)
    basename = File.basename(file_path.to_s, File.extname(file_path.to_s))
    sanitized = basename.gsub(/[^a-zA-Z0-9_-]/, '_').slice(0, 60)
    "data_fix_#{prefix}_#{sanitized}"
  end

  def data_fix_review_param_or_cookie(param_key:, cookie_scope:)
    return params[param_key] if params.key?(param_key)

    cookies["#{cookie_scope}_#{param_key}"]
  end

  def persist_data_fix_review_state(cookie_scope:, state:)
    expires_at = 12.hours.from_now
    state.each do |key, value|
      cookies["#{cookie_scope}_#{key}"] = {
        value: value.to_s,
        expires: expires_at,
        same_site: :lax
      }
    end
  end

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
  # Delegates to DataFix::Phase3Harmonizer (exposed to views via helper_method)
  def phase3_conflict_hint?(team_row)
    DataFix::Phase3Harmonizer.phase3_conflict_hint?(team_row)
  end
  # Delegates to DataFix::IssueDetector (exposed to views via helper_method)
  def swimmer_has_missing_data?(swimmer_key, swimmers_by_key: {}) # rubocop:disable Naming/PredicateMethod
    DataFix::IssueDetector.swimmer_has_missing_data?(swimmer_key, swimmers_by_key: swimmers_by_key)
  end
  # NOTE: build_phase3_category_issues_summary was removed.
  # Category issues are now detected and shown via RelayEnrichmentDetector
  # which includes missing_category in its issue detection.

  # Delegates to DataFix::IssueDetector (exposed to views via helper_method)
  def relay_result_has_issues?(relay_result, **kwargs) # rubocop:disable Naming/PredicateMethod
    DataFix::IssueDetector.relay_result_has_issues?(relay_result, **kwargs)
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
end
