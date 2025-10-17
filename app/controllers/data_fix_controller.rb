# frozen_string_literal: true

require 'date'

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
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
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
        redirect_to(review_sessions_path(request.query_parameters.except(:rescan)), notice: I18n.t('data_import.messages.phase_rebuilt', phase: 1)) && return
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase1_meta = pfm.meta
      @phase1_data = pfm.data
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
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
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
        redirect_to(review_teams_path(request.query_parameters.except(:rescan)), notice: I18n.t('data_import.messages.phase_rebuilt', phase: 2)) && return
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase2_meta = pfm.meta
      @phase2_data = pfm.data

      # Set API URL for AutoComplete components
      set_api_url

      # Optional filtering
      @q = params[:q].to_s.strip
      teams = Array(@phase2_data['teams'])
      if @q.present?
        qd = @q.downcase
        teams = teams.select do |t|
          name = (t['name'] || t['key']).to_s.downcase
          name.include?(qd)
        end
      end
      # Pagination
      @page = params[:page].to_i
      @page = 1 if @page < 1
      @per_page = params[:per_page].to_i
      @per_page = 50 if @per_page <= 0 || !params.key?(:per_page)
      @total_count = teams.size
      @total_pages = (@total_count.to_f / @per_page).ceil
      start_idx = (@page - 1) * @per_page
      end_idx = [start_idx + @per_page - 1, @total_count - 1].min
      @row_range = @total_count.positive? ? "#{start_idx + 1}..#{end_idx + 1}" : '0..0'
      @items = teams.slice(start_idx, @per_page) || []
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
        Import::Solvers::SwimmerSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )
        # Redirect without rescan parameter to avoid triggering rescan on navigation
        redirect_to(review_swimmers_path(request.query_parameters.except(:rescan)), notice: I18n.t('data_import.messages.phase_rebuilt', phase: 3)) && return
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase3_meta = pfm.meta
      @phase3_data = pfm.data
      # Optional filtering
      @q = params[:q].to_s.strip
      swimmers = Array(@phase3_data['swimmers'])
      if @q.present?
        qd = @q.downcase
        swimmers = swimmers.select do |s|
          last = s['last_name'].to_s.downcase
          first = s['first_name'].to_s.downcase
          key = s['key'].to_s.downcase
          [last, first, key].any? { |v| v.include?(qd) }
        end
      end
      # Pagination (swimmers typically have more entries, default to 100)
      @page = params[:page].to_i
      @page = 1 if @page < 1
      @per_page = params[:per_page].to_i
      @per_page = 100 if @per_page <= 0 || !params.key?(:per_page)
      @total_count = swimmers.size
      @total_pages = (@total_count.to_f / @per_page).ceil
      start_idx = (@page - 1) * @per_page
      end_idx = [start_idx + @per_page - 1, @total_count - 1].min
      @row_range = @total_count.positive? ? "#{start_idx + 1}..#{end_idx + 1}" : '0..0'
      @items = swimmers.slice(start_idx, @per_page) || []
      
      # Set API URL for AutoComplete components
      set_api_url
      
      return render 'data_fix/review_swimmers_v2'
    end

    redirect_to controller: 'data_fix_legacy', action: 'review_swimmers', params: request.query_parameters
  end
  # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/MethodLength, Metrics/CyclomaticComplexity

  def review_events
    if params[:phase4_v2].present?
      @file_path = params[:file_path]
      if @file_path.blank?
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      source_path = resolve_source_path(@file_path)
      season = detect_season_from_pathname(source_path)
      lt_format = detect_layout_type(source_path)
      phase_path = default_phase_path_for(source_path, 4)
      if params[:rescan].present? || !File.exist?(phase_path)
        Import::Solvers::EventSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )
        flash.now[:notice] = I18n.t('data_import.messages.phase_rebuilt', phase: 4)
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase4_meta = pfm.meta
      @phase4_data = pfm.data
      return render 'data_fix/review_events_v2'
    end

    redirect_to controller: 'data_fix_legacy', action: 'review_events', params: request.query_parameters
  end

  def review_results
    if params[:phase5_v2].present?
      @file_path = params[:file_path]
      if @file_path.blank?
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_index_path) && return
      end

      source_path = resolve_source_path(@file_path)
      season = detect_season_from_pathname(source_path)
      lt_format = detect_layout_type(source_path)
      phase_path = default_phase_path_for(source_path, 5)
      if params[:rescan].present? || !File.exist?(phase_path)
        Import::Solvers::ResultSolver.new(season:).build!(
          source_path: source_path,
          lt_format: lt_format
        )
        flash.now[:notice] = I18n.t('data_import.messages.phase_rebuilt', phase: 5)
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase5_meta = pfm.meta
      @phase5_data = pfm.data
      return render 'data_fix/review_results_v2'
    end

    redirect_to controller: 'data_fix_legacy', action: 'review_results', params: request.query_parameters
  end

  # Shared read-only endpoints delegate to legacy for now
  def coded_name
    redirect_to controller: 'data_fix_legacy', action: 'coded_name', params: request.query_parameters
  end

  def teams_for_swimmer
    redirect_to controller: 'data_fix_legacy', action: 'teams_for_swimmer', params: request.query_parameters
  end

  # Update a single Phase 2 team entry by index
  # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
  def update_phase2_team
    file_path = params[:file_path]
    team_index = params[:team_index].to_i
    if file_path.blank? || team_index.negative?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 2)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    teams = Array(data['teams'])
    if team_index >= teams.size
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(review_teams_path(file_path:, phase2_v2: 1)) && return
    end

    t = teams[team_index] || {}

    # Handle nested params from AutoComplete (team[index][field]) and top-level params
    team_params = params[:team]
    if team_params.is_a?(ActionController::Parameters) && team_params[team_index.to_s].present?
      nested = team_params[team_index.to_s].permit(:team_id, :editable_name, :name, :name_variations, :city_id)

      # Update team_id (from AutoComplete)
      if nested[:team_id].present?
        num = nested[:team_id].to_i
        t['team_id'] = num if num.positive?
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

    redirect_to review_teams_path(file_path:, phase2_v2: 1), notice: I18n.t('data_import.messages.updated')
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
    team_index = params[:team_index]&.to_i

    if file_path.blank? || team_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 2)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    teams = Array(data['teams'])

    # Validate team_index
    if team_index.negative? || team_index >= teams.size
      flash[:warning] = "Invalid team index: #{team_index}"
      redirect_to(review_teams_path(file_path:, phase2_v2: 1)) && return
    end

    # Remove the team at the specified index
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

    redirect_to review_teams_path(file_path:, phase2_v2: 1), notice: I18n.t('data_import.messages.updated')
  end

  # Update a single Phase 3 swimmer entry by index
  # rubocop:disable Metrics/AbcSize
  def update_phase3_swimmer
    file_path = params[:file_path]
    swimmer_index = params[:swimmer_index]&.to_i

    if file_path.blank? || swimmer_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 3)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    swimmers = Array(data['swimmers'])

    # Validate swimmer_index
    if swimmer_index.negative? || swimmer_index >= swimmers.size
      flash[:warning] = "Invalid swimmer index: #{swimmer_index}"
      redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
    end

    # Get swimmer params - handle nested params from AutoComplete
    swimmer_params = params[:swimmer] || {}
    
    # Update the swimmer at the specified index
    swimmer = swimmers[swimmer_index]
    swimmer['complete_name'] = swimmer_params[:complete_name]&.strip if swimmer_params.key?(:complete_name)
    swimmer['first_name'] = swimmer_params[:first_name]&.strip if swimmer_params.key?(:first_name)
    swimmer['last_name'] = swimmer_params[:last_name]&.strip if swimmer_params.key?(:last_name)
    swimmer['year_of_birth'] = swimmer_params[:year_of_birth].to_i if swimmer_params.key?(:year_of_birth)
    swimmer['gender_type_code'] = swimmer_params[:gender_type_code]&.strip if swimmer_params.key?(:gender_type_code)
    swimmer['swimmer_id'] = swimmer_params[:id].to_i if swimmer_params.key?(:id)

    data['swimmers'] = swimmers

    # Clear downstream phase data (phase4+) when swimmers are modified
    data['meeting_event'] = [] if data.key?('meeting_event')
    data['meeting_program'] = [] if data.key?('meeting_program')
    data['meeting_individual_result'] = [] if data.key?('meeting_individual_result')
    data['meeting_relay_result'] = [] if data.key?('meeting_relay_result')

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_swimmers_path(file_path:, phase3_v2: 1), notice: I18n.t('data_import.messages.updated')
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

  # Delete a swimmer entry from Phase 3 and clear downstream phase data
  def delete_swimmer
    file_path = params[:file_path]
    swimmer_index = params[:swimmer_index]&.to_i

    if file_path.blank? || swimmer_index.nil?
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(pull_index_path) && return
    end

    source_path = resolve_source_path(file_path)
    phase_path = default_phase_path_for(source_path, 3)
    pfm = PhaseFileManager.new(phase_path)
    data = pfm.data || {}
    swimmers = Array(data['swimmers'])

    # Validate swimmer_index
    if swimmer_index.negative? || swimmer_index >= swimmers.size
      flash[:warning] = "Invalid swimmer index: #{swimmer_index}"
      redirect_to(review_swimmers_path(file_path:, phase3_v2: 1)) && return
    end

    # Remove the swimmer at the specified index
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

    redirect_to review_swimmers_path(file_path:, phase3_v2: 1), notice: I18n.t('data_import.messages.updated')
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
      if vstr.present? && !allowed.include?(vstr)
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

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.updated')
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
end
