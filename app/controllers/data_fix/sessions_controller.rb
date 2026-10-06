# frozen_string_literal: true

module DataFix
  # SessionsController: Phase 1 (meeting + sessions) review & edit actions.
  class SessionsController < BaseController
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
  end
end
