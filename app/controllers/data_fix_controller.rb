# frozen_string_literal: true

# = DataFixController: phased pipeline (v2)
#
# Delegates to the new phased solvers when an action-level flag is present; otherwise
# redirects to legacy controller actions to preserve current behavior.
#
class DataFixController < ApplicationController
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
        flash.now[:notice] = I18n.t('data_import.messages.phase_rebuilt', phase: 1)
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
        flash.now[:notice] = I18n.t('data_import.messages.phase_rebuilt', phase: 2)
      end
      pfm = PhaseFileManager.new(phase_path)
      @phase2_meta = pfm.meta
      @phase2_data = pfm.data
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
      @per_page = 50 if @per_page <= 0
      @total_count = teams.size
      @total_pages = (@total_count.to_f / @per_page).ceil
      @items = teams.slice((@page - 1) * @per_page, @per_page) || []
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
        flash.now[:notice] = I18n.t('data_import.messages.phase_rebuilt', phase: 3)
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
      # Pagination
      @page = params[:page].to_i
      @page = 1 if @page < 1
      @per_page = params[:per_page].to_i
      @per_page = 50 if @per_page <= 0
      @total_count = swimmers.size
      @total_pages = (@total_count.to_f / @per_page).ceil
      @items = swimmers.slice((@page - 1) * @per_page, @per_page) || []
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
  # rubocop:disable Metrics/AbcSize
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
    team_params = params.permit(:name, :team_id)
    if team_params.key?(:name)
      t['name'] = sanitize_str(team_params[:name])
    end
    if team_params.key?(:team_id)
      raw = team_params[:team_id].to_s.strip
      if raw.present?
        num = raw.to_i
        unless num.positive? && raw =~ /\A\d+\z/
          flash[:warning] = I18n.t('data_import.errors.invalid_request')
          return redirect_to(review_teams_path(file_path:, phase2_v2: 1))
        end
        t['team_id'] = num
      else
        t['team_id'] = nil
      end
    end
    teams[team_index] = t
    data['teams'] = teams

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_teams_path(file_path:, phase2_v2: 1), notice: I18n.t('data_import.messages.updated')
  end
  # rubocop:enable Metrics/AbcSize

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
                                   :venue1, :address1, :poolLength)
    # Validate pool length strictly when provided
    if meeting_params.key?(:poolLength)
      vstr = meeting_params[:poolLength].to_s.strip
      allowed = %w[25 33 50]
      if vstr.present? && !allowed.include?(vstr)
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        return redirect_to(review_sessions_path(file_path:, phase_v2: 1))
      end
    end
    # Normalize values: strip strings, cast integers, booleans
    normalized = {}
    meeting_params.each do |k, v|
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
    
    normalized.each { |k, v| data[k] = v }

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.updated')
  end
  # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

  # Update a single Phase 1 session entry by index
  # rubocop:disable Metrics/AbcSize
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
    data = pfm.data || {}
    sessions = Array(data['meeting_session'])
    if session_index >= sessions.size
      flash[:warning] = I18n.t('data_import.errors.invalid_request')
      redirect_to(review_sessions_path(file_path:, phase_v2: 1)) && return
    end

    sess = sessions[session_index] || {}
    session_params = params.permit(:description, :scheduled_date, :pool_name, city: [:name])
    # Normalize and validate
    if session_params.key?(:scheduled_date)
      sd = session_params[:scheduled_date].to_s.strip
      if sd.present? && !(sd =~ /\A\d{4}-\d{2}-\d{2}\z/)
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        return redirect_to(review_sessions_path(file_path:, phase_v2: 1))
      end
      sess['scheduled_date'] = sd
    end
    if session_params.key?(:description)
      sess['description'] = sanitize_str(session_params[:description])
    end
    if session_params.key?(:pool_name)
      sess['pool_name'] = sanitize_str(session_params[:pool_name])
    end
    if session_params[:city].is_a?(ActionController::Parameters)
      sess['city'] ||= {}
      sess['city']['name'] = sanitize_str(session_params[:city][:name])
    end
    sessions[session_index] = sess
    data['meeting_session'] = sessions

    meta = pfm.meta || {}
    meta['generated_at'] = Time.now.utc.iso8601
    pfm.write!(data: data, meta: meta)

    redirect_to review_sessions_path(file_path:, phase_v2: 1), notice: I18n.t('data_import.messages.updated')
  end
  # rubocop:enable Metrics/AbcSize

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
