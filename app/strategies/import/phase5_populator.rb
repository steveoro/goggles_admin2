# frozen_string_literal: true

module Import
  #
  # = Phase5Populator
  #
  # Populates temporary data_import_* tables from source result file.
  # Reads phases 1-4 JSON for entity IDs, generates import_keys using MacroSolver patterns,
  # and inserts individual results + laps into GogglesDb data_import tables.
  #
  # == Usage:
  #   populator = Import::Phase5Populator.new(
  #     source_path: '/path/to/source.json',
  #     phase1_path: '/path/to/phase1.json',
  #     phase2_path: '/path/to/phase2.json',
  #     phase3_path: '/path/to/phase3.json',
  #     phase4_path: '/path/to/phase4.json'
  #   )
  #   populator.populate!
  #
  # @author Steve A.
  #
  class Phase5Populator # rubocop:disable Metrics/ClassLength
    attr_reader :source_path, :phase1_path, :phase2_path, :phase3_path, :phase4_path,
                :source_data, :phase1_data, :phase2_data, :phase3_data, :phase4_data,
                :stats

    def initialize(source_path:, phase1_path:, phase2_path:, phase3_path:, phase4_path:)
      @source_path = source_path
      @phase1_path = phase1_path
      @phase2_path = phase2_path
      @phase3_path = phase3_path
      @phase4_path = phase4_path
      @stats = { mir_created: 0, laps_created: 0, programs_matched: 0, mirs_matched: 0, errors: [] }
    end

    # Main entry point: truncate existing data, load phase files, populate tables
    def populate!
      truncate_tables!
      load_phase_files!
      populate_individual_results!
      stats
    end

    private

    # Clear existing data_import_* records
    def truncate_tables!
      GogglesDb::DataImportMeetingIndividualResult.delete_all
      GogglesDb::DataImportLap.delete_all
    end

    # Load all phase JSON files
    def load_phase_files!
      @source_data = JSON.parse(File.read(source_path))
      @phase1_data = JSON.parse(File.read(phase1_path)) if File.exist?(phase1_path)
      @phase2_data = JSON.parse(File.read(phase2_path)) if File.exist?(phase2_path)
      @phase3_data = JSON.parse(File.read(phase3_path)) if File.exist?(phase3_path)
      @phase4_data = JSON.parse(File.read(phase4_path)) if File.exist?(phase4_path)
    end

    # Populate MIR + Laps from source events array (LT4 format)
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def populate_individual_results!
      events = source_data['events'] || []

      events.each_with_index do |event, _idx|
        next if event['relay'] == true # Skip relay events for now

        session_order = event['sessionOrder'] || 1
        distance = extract_distance(event)
        stroke = extract_stroke(event)
        next if distance.blank? || stroke.blank?

        event_code = event['eventCode'].presence || "#{distance}#{stroke}"
        results = Array(event['results'])

        results.each do |result|
          gender = result['gender'] || event['eventGender'] || event['gender']
          category = result['category'] || result['categoryTypeCode'] || result['category_code']
          next if gender.blank? || category.blank?

          # Generate keys
          program_key = build_program_key(session_order, event_code, category, gender)
          swimmer_key = build_swimmer_key(result)
          import_key = GogglesDb::DataImportMeetingIndividualResult.build_import_key(program_key, swimmer_key)

          # Find entity IDs from phase files
          swimmer_id = find_swimmer_id(swimmer_key)
          team_id = find_team_id(result)
          meeting_program_id = find_meeting_program_id(session_order, event_code, category, gender)
          @stats[:programs_matched] += 1 if meeting_program_id

          # Find existing MIR if all IDs present
          meeting_individual_result_id = find_existing_mir(meeting_program_id, swimmer_id, team_id)
          @stats[:mirs_matched] += 1 if meeting_individual_result_id

          # Parse timing from string format "M'SS.HH"
          timing_hash = parse_timing_string(result['timing'])

          # Create MIR record
          mir = create_mir_record(
            import_key: import_key,
            result: result,
            timing: timing_hash,
            swimmer_id: swimmer_id,
            team_id: team_id,
            meeting_program_id: meeting_program_id,
            meeting_individual_result_id: meeting_individual_result_id
          )

          next unless mir

          # Create lap records
          create_lap_records(mir, result, import_key)
        end
      end
    end
    # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

    # Extract distance from event hash
    def extract_distance(event)
      distance = event['distance'] || event['distanceInMeters'] || event['eventLength']
      return distance if distance.present?

      # Try to extract from eventCode
      code = event['eventCode'].to_s
      code.gsub(/[^0-9]/, '') if code.match?(/\A\d{2,4}[A-Z]{2}\z/)
    end

    # Extract stroke from event hash
    def extract_stroke(event)
      stroke = event['stroke'] || event['style'] || event['eventStroke']
      return stroke if stroke.present?

      # Try to extract from eventCode
      code = event['eventCode'].to_s
      code.gsub(/[^A-Z]/, '') if code.match?(/\A\d{2,4}[A-Z]{2}\z/)
    end

    # Build program key: "session_order-event_code-category-gender"
    # Example: "1-100SL-M45-M"
    def build_program_key(session_order, event_code, category, gender)
      "#{session_order}-#{event_code}-#{category}-#{gender}"
    end

    # Parse timing string to hash
    # Format: "M'SS.HH" or "SS.HH" → {minutes: M, seconds: SS, hundredths: HH}
    # Examples: "5'05.84" → {minutes: 5, seconds: 5, hundredths: 84}
    #           "58.45" → {minutes: 0, seconds: 58, hundredths: 45}
    def parse_timing_string(timing_str)
      return { minutes: 0, seconds: 0, hundredths: 0 } if timing_str.blank?

      # Remove spaces, normalize apostrophe (handles both ' and ')
      clean = timing_str.to_s.strip.gsub(/['`]/, "'")

      minutes = 0
      seconds = 0
      hundredths = 0

      # Match: M'SS.HH or SS.HH
      if clean.include?("'")
        parts = clean.split("'")
        minutes = parts[0].to_i
        sec_parts = parts[1].to_s.split('.')
        seconds = sec_parts[0].to_i
        hundredths = sec_parts[1].to_i
      elsif clean.include?('.')
        parts = clean.split('.')
        seconds = parts[0].to_i
        hundredths = parts[1].to_i
      else
        seconds = clean.to_i
      end

      { minutes: minutes, seconds: seconds, hundredths: hundredths }
    end

    # Build swimmer key matching phase 3 format: "LAST|FIRST|YEAR"
    # Source swimmer format: "F|ROSSI|Bianca|1950|CSI Ober Ferrari"
    # Phase 3 key format: "ROSSI|Bianca|1950"
    def build_swimmer_key(result)
      swimmer_str = result['swimmer'] || result['swimmer_name'] || ''
      parts = swimmer_str.split('|')

      # Format: gender|last|first|year|team
      return swimmer_str if parts.size < 4

      last_name = parts[1]
      first_name = parts[2]
      year = parts[3]

      "#{last_name}|#{first_name}|#{year}"
    end

    # Find swimmer_id from phase 3 data
    # swimmer_key format: "LAST|FIRST|YEAR"
    def find_swimmer_id(swimmer_key)
      return nil unless phase3_data

      swimmers = phase3_data.dig('data', 'swimmers') || []
      swimmer = swimmers.find { |s| s['key'] == swimmer_key }
      swimmer&.dig('swimmer_id')
    end

    # Find team_id from phase 2 data
    def find_team_id(result)
      return nil unless phase2_data

      team_name = result['team'] || result['team_name'] || result['teamName']
      return nil if team_name.blank?

      teams = phase2_data.dig('data', 'teams') || []
      # Match by key first (exact match), then try name/editable_name
      team = teams.find { |t| t['key'] == team_name } ||
             teams.find { |t| t['name'] == team_name || t['editable_name'] == team_name }
      team&.dig('team_id')
    end

    # Find meeting_program_id by matching against existing database records
    # Matches: MeetingEvent (by session + event_type) → MeetingProgram (by event + category + gender)
    def find_meeting_program_id(session_order, event_code, category, gender)
      return nil unless phase1_data && phase4_data

      # Step 1: Get meeting_id from phase 1
      meeting_id = phase1_data.dig('data', 'meeting_id')
      return nil unless meeting_id

      # Step 2: Find meeting_session_id from phase 1 data
      sessions = phase1_data.dig('data', 'sessions') || []
      session = sessions.find { |s| s['session_order'].to_i == session_order.to_i }
      meeting_session_id = session&.dig('meeting_session_id')
      return nil unless meeting_session_id

      # Step 3: Parse event_code to get event_type_id
      event_type = parse_event_type(event_code)
      return nil unless event_type

      # Step 4: Find MeetingEvent
      meeting_event = GogglesDb::MeetingEvent
                      .where(meeting_session_id: meeting_session_id, event_type_id: event_type.id)
                      .first
      return nil unless meeting_event

      # Step 5: Parse category and gender to get type IDs
      category_type = parse_category_type(category)
      gender_type = parse_gender_type(gender)
      return nil unless category_type && gender_type

      # Step 6: Find MeetingProgram
      meeting_program = GogglesDb::MeetingProgram
                        .where(
                          meeting_event_id: meeting_event.id,
                          category_type_id: category_type.id,
                          gender_type_id: gender_type.id
                        )
                        .first

      meeting_program&.id
    end

    # Parse event code to EventType (e.g., "200RA" → 200m Breaststroke)
    def parse_event_type(event_code)
      return nil if event_code.blank?

      # Extract distance and stroke code from event_code
      # Format: "200RA", "100SL", "50FA", etc.
      match = event_code.match(/\A(\d{2,4})([A-Z]{2})\z/)
      return nil unless match

      distance = match[1].to_i
      stroke_code = match[2]

      # Stroke codes are already in the correct 2-letter format
      # SL = Stile Libero (Freestyle)
      # DO = Dorso (Backstroke)
      # RA = Rana (Breaststroke)
      # FA = Farfalla (Butterfly)
      # MI = Misti (Individual Medley)
      # MX = Mista (Mixed)

      # Find StrokeType directly by the 2-letter code
      stroke_type = GogglesDb::StrokeType.find_by(code: stroke_code)
      return nil unless stroke_type

      # Filter to individual events (not relays) within standard distances
      GogglesDb::EventType
        .where(length_in_meters: distance, stroke_type_id: stroke_type.id, relay: false)
        .where('length_in_meters <= 1500')
        .first
    end

    # Parse category code to CategoryType (e.g., "M75" → Master 75-79)
    def parse_category_type(category)
      return nil if category.blank?

      # Category format: "M75", "M45", "U25", etc.
      # Use undecorate to get plain code if it's decorated
      code = category.to_s.strip
      GogglesDb::CategoryType.find_by(code: code)
    end

    # Parse gender code to GenderType (e.g., "F" → Female, "M" → Male)
    def parse_gender_type(gender)
      return nil if gender.blank?

      code = gender.to_s.strip.upcase
      GogglesDb::GenderType.find_by(code: code)
    end

    # Find existing MeetingIndividualResult for UPDATE operations
    # Requires all 3 IDs to be present (meeting_program_id, swimmer_id, team_id)
    def find_existing_mir(meeting_program_id, swimmer_id, team_id)
      return nil if meeting_program_id.nil? || swimmer_id.nil? || team_id.nil?

      mir = GogglesDb::MeetingIndividualResult
            .where(
              meeting_program_id: meeting_program_id,
              swimmer_id: swimmer_id,
              team_id: team_id
            )
            .first

      mir&.id
    end

    # Create MIR record
    def create_mir_record(import_key:, result:, timing:, swimmer_id:, team_id:, meeting_program_id:, meeting_individual_result_id:)
      mir = GogglesDb::DataImportMeetingIndividualResult.create!(
        import_key: import_key,
        phase_file_path: source_path,
        meeting_program_id: meeting_program_id,
        swimmer_id: swimmer_id,
        team_id: team_id,
        meeting_individual_result_id: meeting_individual_result_id,
        rank: result['ranking']&.to_i || result['rank']&.to_i || result['position']&.to_i || 0,
        minutes: timing[:minutes],
        seconds: timing[:seconds],
        hundredths: timing[:hundredths],
        disqualified: result['disqualified'] || false,
        disqualification_code_type_id: result['disqualification_code'],
        standard_points: result['standard_points'].to_f,
        meeting_points: result['meeting_points'].to_f,
        reaction_time: result['reaction_time'].to_f
      )
      @stats[:mir_created] += 1
      mir
    rescue ActiveRecord::RecordInvalid => e
      @stats[:errors] << "MIR error for #{import_key}: #{e.message}"
      nil
    end

    # Create lap records for a given MIR
    # Computes both delta timing and from_start timing
    def create_lap_records(_mir, result, mir_import_key)
      laps = result['laps'] || []
      previous_from_start = { minutes: 0, seconds: 0, hundredths: 0 }

      laps.each do |lap|
        # Parse distance: "50m" → 50
        distance_str = lap['distance'] || lap['length_in_meters'] || lap['lengthInMeters'] || lap['length']
        length = distance_str.to_s.gsub(/\D/, '').to_i
        next if length.zero?

        # Parse lap timing from source (this is "from_start" timing)
        from_start = parse_timing_string(lap['timing'])

        # Compute delta timing: current_from_start - previous_from_start
        delta = compute_timing_delta(from_start, previous_from_start)

        lap_import_key = GogglesDb::DataImportLap.build_import_key(mir_import_key, length)

        GogglesDb::DataImportLap.create!(
          import_key: lap_import_key,
          parent_import_key: mir_import_key,
          phase_file_path: source_path,
          meeting_individual_result_id: nil, # Will be set in phase 6
          length_in_meters: length,
          # Delta timing (default columns)
          minutes: delta[:minutes],
          seconds: delta[:seconds],
          hundredths: delta[:hundredths],
          # From-start timing (cumulative from race start)
          minutes_from_start: from_start[:minutes],
          seconds_from_start: from_start[:seconds],
          hundredths_from_start: from_start[:hundredths],
          reaction_time: lap['reaction_time'].to_f
        )
        @stats[:laps_created] += 1

        # Update previous timing for next iteration
        previous_from_start = from_start
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "Lap error for #{lap_import_key}: #{e.message}"
      end
    end

    # Compute delta timing: current - previous
    # Uses Timing wrapper for accurate subtraction
    def compute_timing_delta(current, previous)
      current_timing = Timing.new(
        minutes: current[:minutes],
        seconds: current[:seconds],
        hundredths: current[:hundredths]
      )
      previous_timing = Timing.new(
        minutes: previous[:minutes],
        seconds: previous[:seconds],
        hundredths: previous[:hundredths]
      )
      delta_timing = current_timing - previous_timing

      {
        minutes: delta_timing.minutes,
        seconds: delta_timing.seconds,
        hundredths: delta_timing.hundredths
      }
    end
  end
end
