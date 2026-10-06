# frozen_string_literal: true

module DataFix
  # EventsController: Phase 4 (events) review & edit actions, plus the results chunk endpoint.
  class EventsController < BaseController
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
  end
end
