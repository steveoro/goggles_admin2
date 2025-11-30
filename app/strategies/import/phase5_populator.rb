# frozen_string_literal: true

module Import
  #
  # = Phase5Populator
  #
  # Populates temporary data_import_* tables from source result file.
  # Reads phases 1-4 JSON for entity IDs, generates import_keys using MacroSolver patterns,
  # and inserts individual results + laps into GogglesDb data_import tables.
  #
  # Supports both LT2 and LT4 source formats through automatic normalization:
  # - LT2 (layoutType: 2): Sections/rows structure → normalized to LT4 via Layout2To4 adapter
  # - LT4 (layoutType: 4): Events array structure → used directly
  #
  # Format is auto-detected from the source file's 'layoutType' field. LT2 files are
  # automatically normalized to LT4 format during load, allowing a single code path for
  # all population logic.
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
    attr_reader :source_path, :phase1_path, :phase2_path, :phase3_path, :phase4_path, :phase5_output_path,
                :source_data, :phase1_data, :phase2_data, :phase3_data, :phase4_data,
                :stats, :data_integrator, :programs

    def initialize(source_path:, phase1_path:, phase2_path:, phase3_path:, phase4_path:)
      @source_path = source_path
      @phase1_path = phase1_path
      @phase2_path = phase2_path
      @phase3_path = phase3_path
      @phase4_path = phase4_path
      # Derive phase5 output path from phase4 path
      @phase5_output_path = phase4_path.gsub('phase4', 'phase5')
      @stats = {
        mir_created: 0,
        laps_created: 0,
        relay_results_created: 0,
        relay_swimmers_created: 0,
        relay_laps_created: 0,
        programs_matched: 0,
        mirs_matched: 0,
        errors: []
      }
      # Hash to collect program groups: program_key => program_data
      @programs = {}
    end

    # Main entry point: truncate existing data, load phase files, populate tables
    # Note: LT2 files are normalized to LT4 format during load_phase_files!
    def populate!
      truncate_tables!
      load_phase_files!

      # All files are now in LT4 format (normalized if needed)
      Rails.logger.info('[Phase5Populator] Populating from LT4 format (normalized if LT2)')
      populate_lt4_results!
      write_phase5_output!
      stats
    end

    private

    # Clear existing data_import_* records for the current source file only
    # This allows working on multiple files simultaneously without data loss
    def truncate_tables!
      GogglesDb::DataImportMeetingIndividualResult.where(phase_file_path: source_path).delete_all
      GogglesDb::DataImportLap.where(phase_file_path: source_path).delete_all
      GogglesDb::DataImportMeetingRelayResult.where(phase_file_path: source_path).delete_all
      GogglesDb::DataImportMeetingRelaySwimmer.where(phase_file_path: source_path).delete_all
      GogglesDb::DataImportRelayLap.where(phase_file_path: source_path).delete_all
    end

    # Load all phase JSON files and normalize source to LT4 format
    def load_phase_files!
      @source_data = JSON.parse(File.read(source_path))

      # Detect format before loading other phases
      original_format = detect_source_format

      @phase1_data = JSON.parse(File.read(phase1_path)) if File.exist?(phase1_path)
      @phase2_data = JSON.parse(File.read(phase2_path)) if File.exist?(phase2_path)
      @phase3_data = JSON.parse(File.read(phase3_path)) if File.exist?(phase3_path)
      @phase4_data = JSON.parse(File.read(phase4_path)) if File.exist?(phase4_path)

      # Initialize data integrator for gender/category inference
      season = extract_season
      @data_integrator = Phase5::DataIntegrator.new(
        source_data: @source_data,
        phase3_data: @phase3_data,
        season: season
      )

      # Normalize LT2 files to LT4 format for unified processing
      if original_format == :lt2
        Rails.logger.info('[Phase5Populator] Normalizing LT2 → LT4 format')
        @source_data = Import::Adapters::Layout2To4.normalize(data_hash: @source_data)
        Rails.logger.info('[Phase5Populator] Normalization complete')
      end

      # DEBUG logging
      Rails.logger.info('[Phase5Populator] Loaded phase files:')
      Rails.logger.info("  - source format: #{original_format} → normalized to LT4")
      Rails.logger.info("  - phase1_path: #{phase1_path}, exists: #{File.exist?(phase1_path)}")
      Rails.logger.info("  - phase2_path: #{phase2_path}, exists: #{File.exist?(phase2_path)}, teams: #{@phase2_data&.dig('data', 'teams')&.size || 0}")
      Rails.logger.info("  - phase3_path: #{phase3_path}, exists: #{File.exist?(phase3_path)}, swimmers: #{@phase3_data&.dig('data', 'swimmers')&.size || 0}")
      Rails.logger.info("  - phase4_path: #{phase4_path}, exists: #{File.exist?(phase4_path)}")
    end

    # Detect source file format (LT2 or LT4) based on layoutType field
    def source_format
      @source_format ||= detect_source_format
    end

    def detect_source_format
      layout_type = source_data['layoutType']

      raise "Unknown source format: 'layoutType' field missing in #{source_path}" if layout_type.nil?

      case layout_type.to_i
      when 2
        :lt2
      when 4
        :lt4
      else
        raise "Unknown layoutType #{layout_type} in #{source_path}. Expected 2 (LT2) or 4 (LT4)"
      end
    end

    # Populate from LT4 format (events array)
    # Note: LT2 files are automatically normalized to LT4 format before this runs
    def populate_lt4_results!
      populate_lt4_individual_results!
      populate_lt4_relay_results!
      # NOTE: DSQ results keep rank=0 in DB; display sorting handled in view layer
    end

    # Populate MIR + Laps from source events array (LT4 format)
    # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def populate_lt4_individual_results! # rubocop:disable Metrics/MethodLength
      events = source_data['events'] || []

      events.each_with_index do |event, _event_idx|
        next if event['relay'] == true # Skip relay events for now

        session_order = event['sessionOrder'] || 1
        distance = extract_distance(event)
        stroke = extract_stroke(event)
        next if distance.blank? || stroke.blank?

        # Use key if available (phase4), otherwise use eventCode (normalized LT2)
        event_key = event['key'] || event['eventCode']
        event_code = event['eventCode'].presence || "#{distance}#{stroke}"
        results = Array(event['results'])

        results_x_event_tot = results.count
        results.each_with_index do |result, res_idx|
          gender = result['gender'] || event['eventGender'] || event['gender']
          category = result['category'] || result['categoryTypeCode'] || result['category_code']

          # Broadcast progress every event:
          broadcast_progress("Processing MIRs for event #{event_code} #{category} #{gender} (#{res_idx + 1}/#{results_x_event_tot})...",
                             res_idx + 1, results_x_event_tot)
          next if gender.blank? || category.blank?

          # Find swimmer data from Phase 3 (returns both ID and full key when matched)
          swimmer_data = find_swimmer_data(result)
          swimmer_id = swimmer_data[:swimmer_id]
          swimmer_key = swimmer_data[:swimmer_key] # Full Phase 3 key if matched

          # Generate keys
          program_key = build_program_key(session_order, event_code, category, gender)
          team_key = build_team_key_from_result(result)
          import_key = GogglesDb::DataImportMeetingIndividualResult.build_import_key(program_key, swimmer_key)

          # Find team_id from phase files
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
            swimmer_key: swimmer_key,
            team_id: team_id,
            team_key: team_key,
            meeting_program_id: meeting_program_id,
            meeting_program_key: program_key,
            meeting_individual_result_id: meeting_individual_result_id
          )

          next unless mir

          # Create lap records
          create_lap_records(mir, result, import_key)

          # Register program in phase5 output (metadata only)
          add_to_programs(
            session_order: session_order,
            event_key: event_key,
            event_code: event_code,
            category: category,
            gender: gender,
            meeting_program_id: meeting_program_id,
            relay: false
          )
        end
      end
    end

    # Populate relay results from source events array (LT4 format)
    def populate_lt4_relay_results! # rubocop:disable Metrics/MethodLength
      events = source_data['events'] || []
      relay_events = events.select { |e| e['relay'] == true }
      total_relay = relay_events.size

      events.each_with_index do |event, _event_idx|
        next unless event['relay'] == true # Only process relay events

        # Broadcast progress every relay event
        relay_idx = relay_events.index(event) || 0
        session_order = event['sessionOrder'] || 1
        distance = extract_distance(event)
        stroke = extract_stroke(event)
        next if distance.blank? || stroke.blank?

        # Use key if available (phase4), otherwise use eventCode (normalized LT2)
        event_key = event['key'] || event['eventCode']
        event_code = event['eventCode'].presence || "#{distance}#{stroke}"
        results = Array(event['results'])
        results_x_event_tot = results.size

        results.each_with_index do |result, res_idx|
          # Use data integrator to infer missing gender/category
          integrated = data_integrator.integrate_relay_result(result: result, event: event)

          # Use integrated values (with fallbacks)
          gender = integrated[:gender] || result['gender'] || event['eventGender'] || event['gender'] || 'X'
          category = integrated[:category] || result['category'] || result['categoryTypeCode'] || result['category_code']
          broadcast_progress("Processing MRR for #{event_code} #{category} #{gender} (#{relay_idx + 1}/#{total_relay}, #{res_idx + 1}/#{results_x_event_tot})...",
                             res_idx + 1, results_x_event_tot)
          next if category.blank?

          # Generate keys
          program_key = build_program_key(session_order, event_code, category, gender)
          team_key = build_team_key_from_result(result)
          timing_string = result['timing'] || '0'
          import_key = GogglesDb::DataImportMeetingRelayResult.build_import_key(program_key, team_key, timing_string)

          # Find entity IDs from phase files
          team_id = find_team_id(result)
          meeting_program_id = find_meeting_program_id(session_order, event_code, category, gender)
          @stats[:programs_matched] += 1 if meeting_program_id

          # Find existing MRR if all IDs present (for potential UPDATE)
          meeting_relay_result_id = find_existing_mrr(meeting_program_id, team_id) if meeting_program_id && team_id

          # Parse timing
          timing_hash = parse_timing_string(result['timing'])

          # Create MRR record
          mrr = create_mrr_record(
            import_key: import_key,
            result: result,
            timing_hash: timing_hash,
            team_id: team_id,
            team_key: team_key,
            meeting_program_id: meeting_program_id,
            meeting_program_key: program_key,
            meeting_relay_result_id: meeting_relay_result_id
          )

          next unless mrr

          @stats[:relay_results_created] += 1

          # Create relay swimmers and laps
          create_relay_swimmers(mrr, result, import_key)
          create_relay_laps(mrr, result, import_key)

          # Register program in phase5 output (metadata only)
          add_to_programs(
            session_order: session_order,
            event_key: event_key,
            event_code: event_code,
            category: category,
            gender: gender,
            meeting_program_id: meeting_program_id,
            relay: true
          )
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

    # Build swimmer key from source result
    # Returns partial key for initial lookup: "LAST|FIRST|YEAR"
    # Handles TWO source formats:
    #   - WITH gender prefix: "F|ROSSI|Bianca|1950|CSI Ober Ferrari" (5 parts)
    #   - WITHOUT gender prefix: "ROSSI|Bianca|1950|CSI Ober Ferrari" (4 parts)
    def build_swimmer_key(result)
      swimmer_str = result['swimmer'] || result['swimmer_name'] || ''
      parts = swimmer_str.split('|')

      return swimmer_str if parts.size < 3

      # Detect format: if parts[0] is a single-char gender code (M/F) or empty, it's WITH gender prefix
      # Otherwise, parts[0] is the last_name (no gender prefix)
      if parts[0].match?(/\A[MF]?\z/i)
        # Format: gender|last|first|year|team (5 parts)
        return swimmer_str if parts.size < 4

        last_name = parts[1]
        first_name = parts[2]
        year = parts[3]
      else
        # Format: last|first|year|team (4 parts, no gender prefix)
        last_name = parts[0]
        first_name = parts[1]
        year = parts[2]
      end

      "#{last_name}|#{first_name}|#{year}"
    end

    # Find swimmer data from phase 3: returns { swimmer_id:, swimmer_key: }
    # The returned swimmer_key is the FULL Phase 3 key (with gender prefix) when matched
    # This ensures stored keys are consistent with Phase 3 format
    def find_swimmer_data(result)
      return { swimmer_id: nil, swimmer_key: build_swimmer_key(result) } unless phase3_data

      partial_key = build_swimmer_key(result)
      return { swimmer_id: nil, swimmer_key: partial_key } if partial_key.blank?

      swimmers = phase3_data.dig('data', 'swimmers') || []

      # First try exact match
      swimmer = swimmers.find { |s| s['key'] == partial_key }
      if swimmer&.dig('swimmer_id')
        Rails.logger.info("[Phase5Populator] Found swimmer_id=#{swimmer['swimmer_id']} for exact key=#{partial_key}")
        return { swimmer_id: swimmer['swimmer_id'], swimmer_key: swimmer['key'] }
      end

      # Try partial key matching (ignoring gender prefix)
      normalized_partial = normalize_to_partial_key(partial_key)
      if normalized_partial
        matching_swimmers = swimmers.select do |s|
          normalize_to_partial_key(s['key']) == normalized_partial
        end

        if matching_swimmers.size == 1
          matched = matching_swimmers.first
          Rails.logger.info("[Phase5Populator] Found swimmer_id=#{matched['swimmer_id']} via partial match, using Phase3 key=#{matched['key']}")
          return { swimmer_id: matched['swimmer_id'], swimmer_key: matched['key'] }
        elsif matching_swimmers.size > 1
          # Multiple matches - find one with swimmer_id
          with_id = matching_swimmers.find { |s| s['swimmer_id'].to_i.positive? }
          if with_id
            Rails.logger.info("[Phase5Populator] Found swimmer_id=#{with_id['swimmer_id']} from multiple matches, using Phase3 key=#{with_id['key']}")
            return { swimmer_id: with_id['swimmer_id'], swimmer_key: with_id['key'] }
          end
        end
      end

      Rails.logger.warn("[Phase5Populator] No swimmer match found for key=#{partial_key}")
      { swimmer_id: nil, swimmer_key: partial_key }
    end

    # Find swimmer_id from phase 3 data using flexible key matching
    # Supports both exact match and partial matching (ignoring gender prefix)
    # @deprecated Use find_swimmer_data instead for both ID and full key
    def find_swimmer_id(swimmer_key)
      return nil unless phase3_data
      return nil if swimmer_key.blank?

      # Use unified flexible lookup
      swimmer_id = find_swimmer_id_by_key(swimmer_key)

      # DEBUG logging
      if swimmer_id
        Rails.logger.info("[Phase5Populator] Found swimmer_id=#{swimmer_id} for key=#{swimmer_key}")
      else
        Rails.logger.warn("[Phase5Populator] No swimmer_id found for key=#{swimmer_key}")
      end

      swimmer_id
    end

    # Find team_id from phase 2 data or phase 3 badges
    # First tries Phase 2 teams, then falls back to Phase 3 badges
    # Handles TWO source formats:
    #   - WITH gender prefix: "F|LAST|FIRST|YOB|TeamName" (5 parts)
    #   - WITHOUT gender prefix: "LAST|FIRST|YOB|TeamName" (4 parts)
    def find_team_id(result)
      team_name = result['team'] || result['team_name'] || result['teamName']

      # If no explicit team field, try to extract from swimmer string
      if team_name.blank?
        swimmer_str = result['swimmer'] || result['swimmer_name'] || ''
        parts = swimmer_str.split('|')

        # Detect format based on first part
        if parts[0].match?(/\A[MF]?\z/i)
          # Format: gender|last|first|year|team (5 parts)
          team_name = parts[4] if parts.size >= 5
        elsif parts.size >= 4
          # Format: last|first|year|team (4 parts, no gender prefix)
          team_name = parts[3]
        end
      end

      # Try Phase 2 team lookup first (if we have a team_name)
      if team_name.present? && phase2_data
        teams = phase2_data.dig('data', 'teams') || []
        # Match by key first (exact match), then try name/editable_name
        team = teams.find { |t| t['key'] == team_name } ||
               teams.find { |t| t['name'] == team_name || t['editable_name'] == team_name }
        team_id = team&.dig('team_id')

        if team_id
          Rails.logger.info("[Phase5Populator] Found team_id=#{team_id} from phase2 for team_name=#{team_name}")
          return team_id
        end
      end

      # Fallback: Try to find team_id from Phase 3 badges using swimmer key
      # This works even if team_name is blank - we match by swimmer
      if phase3_data
        swimmer_key = build_swimmer_key(result)
        badge_team_id = find_team_id_from_badges(swimmer_key, team_name)

        if badge_team_id
          Rails.logger.info("[Phase5Populator] Found team_id=#{badge_team_id} from phase3 badge for swimmer_key=#{swimmer_key}")
          return badge_team_id
        end
      end

      Rails.logger.warn("[Phase5Populator] No team_id found for team_name=#{team_name.presence || 'N/A'}")
      nil
    end

    # Find team_id from Phase 3 badges using swimmer key or team key
    def find_team_id_from_badges(swimmer_key, team_name)
      return nil unless phase3_data

      badges = phase3_data.dig('data', 'badges') || []

      # First try to find badge by swimmer key (partial matching)
      partial_key = normalize_to_partial_key(swimmer_key)
      if partial_key
        badge = badges.find do |b|
          badge_partial = normalize_to_partial_key(b['swimmer_key'])
          badge_partial == partial_key && b['team_id'].to_i.positive?
        end
        return badge['team_id'] if badge
      end

      # Fallback: find by team_key matching team_name
      badge = badges.find do |b|
        (b['team_key'] == team_name || b['team_key']&.downcase == team_name&.downcase) &&
          b['team_id'].to_i.positive?
      end

      badge&.dig('team_id')
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
    def create_mir_record(import_key:, result:, timing:, swimmer_id:, swimmer_key:, team_id:, team_key:, meeting_program_id:, meeting_program_key:,
                          meeting_individual_result_id:)
      # DEBUG logging
      Rails.logger.info("[Phase5Populator] Creating MIR: import_key=#{import_key}, swimmer_id=#{swimmer_id}, team_id=#{team_id}, program_id=#{meeting_program_id}")

      raw_rank = result['ranking'] || result['rank'] || result['position'] || result['pos']
      rank_int = raw_rank.to_i
      rank_non_numeric = raw_rank.present? && raw_rank.to_s !~ /^\d+$/

      timing_zero = timing[:minutes].to_i.zero? && timing[:seconds].to_i.zero? && timing[:hundredths].to_i.zero?

      disqualified_flag = !!result['disqualified'] || rank_non_numeric || timing_zero

      # Use find_or_create to handle potential duplicates gracefully
      mir = GogglesDb::DataImportMeetingIndividualResult.find_or_create_by!(import_key: import_key) do |record|
        record.phase_file_path = source_path
        # DB foreign keys (may be nil for unmatched entities)
        record.meeting_program_id = meeting_program_id
        record.swimmer_id = swimmer_id
        record.team_id = team_id
        record.meeting_individual_result_id = meeting_individual_result_id
        # String keys for referencing entities when IDs are nil
        record.swimmer_key = swimmer_key
        record.team_key = team_key
        record.meeting_program_key = meeting_program_key
        # Result data
        record.rank = rank_int
        record.minutes = timing[:minutes]
        record.seconds = timing[:seconds]
        record.hundredths = timing[:hundredths]
        record.disqualified = disqualified_flag
        record.disqualification_code_type_id = result['disqualification_code']
        record.standard_points = result['standard_points'].to_f
        record.meeting_points = result['meeting_points'].to_f
        record.reaction_time = result['reaction_time'].to_f
      end
      @stats[:mir_created] += 1
      mir
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
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

        # Use find_or_create to handle potential duplicates gracefully
        GogglesDb::DataImportLap.find_or_create_by!(import_key: lap_import_key) do |record|
          record.parent_import_key = mir_import_key
          record.meeting_individual_result_key = mir_import_key # Parent MIR reference
          record.phase_file_path = source_path
          record.meeting_individual_result_id = nil # Will be set in phase 6
          record.length_in_meters = length
          # Delta timing (default columns)
          record.minutes = delta[:minutes]
          record.seconds = delta[:seconds]
          record.hundredths = delta[:hundredths]
          # From-start timing (cumulative from race start)
          record.minutes_from_start = from_start[:minutes]
          record.seconds_from_start = from_start[:seconds]
          record.hundredths_from_start = from_start[:hundredths]
          record.reaction_time = lap['reaction_time'].to_f
        end
        @stats[:laps_created] += 1

        # Update previous timing for next iteration
        previous_from_start = from_start
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
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

    # Compute cumulative timing: sum of timing1 + timing2
    # Uses Timing wrapper for accurate addition with overflow handling
    def compute_timing_sum(timing1, timing2)
      timing1_obj = Timing.new(
        minutes: timing1[:minutes],
        seconds: timing1[:seconds],
        hundredths: timing1[:hundredths]
      )
      timing2_obj = Timing.new(
        minutes: timing2[:minutes],
        seconds: timing2[:seconds],
        hundredths: timing2[:hundredths]
      )
      sum_timing = timing1_obj + timing2_obj

      {
        minutes: sum_timing.minutes,
        seconds: sum_timing.seconds,
        hundredths: sum_timing.hundredths
      }
    end

    # Build team key from result (for both individual and relay events)
    # Handles TWO source formats:
    #   - WITH gender prefix: "F|LAST|FIRST|YOB|TeamName" (5 parts, team at index 4)
    #   - WITHOUT gender prefix: "LAST|FIRST|YOB|TeamName" (4 parts, team at index 3)
    def build_team_key_from_result(result)
      team_name = result['team'] || result['team_name'] || result['teamName']

      # If no explicit team field, try to extract from swimmer string
      if team_name.blank?
        swimmer_str = result['swimmer'] || result['swimmer_name'] || ''
        parts = swimmer_str.split('|')

        # Detect format based on first part
        if parts[0].match?(/\A[MF]?\z/i)
          # Format: gender|last|first|year|team (5 parts)
          team_name = parts[4] if parts.size >= 5
        elsif parts.size >= 4
          # Format: last|first|year|team (4 parts, no gender prefix)
          team_name = parts[3]
        end
      end

      (team_name || '').strip
    end

    # Find existing MeetingRelayResult for UPDATE operations
    def find_existing_mrr(meeting_program_id, team_id)
      return nil unless meeting_program_id && team_id

      mrr = GogglesDb::MeetingRelayResult
            .where(meeting_program_id: meeting_program_id, team_id: team_id)
            .first

      mrr&.id
    end

    # Create MRR record
    def create_mrr_record(import_key:, result:, timing_hash:, team_id:, team_key:, meeting_program_id:, meeting_program_key:, meeting_relay_result_id:)
      raw_rank = result['ranking'] || result['rank'] || result['pos']
      rank_int = raw_rank.to_i
      rank_non_numeric = raw_rank.present? && raw_rank.to_s !~ /^\d+$/

      timing_zero = timing_hash[:minutes].to_i.zero? && timing_hash[:seconds].to_i.zero? && timing_hash[:hundredths].to_i.zero?

      disqualified_flag = !!result['disqualified'] || rank_non_numeric || timing_zero

      # Use find_or_create to handle potential duplicates gracefully
      GogglesDb::DataImportMeetingRelayResult.find_or_create_by!(import_key: import_key) do |mrr|
        mrr.phase_file_path = source_path
        # DB foreign keys (may be nil for unmatched entities)
        mrr.meeting_relay_result_id = meeting_relay_result_id
        mrr.meeting_program_id = meeting_program_id
        mrr.team_id = team_id
        # String keys for referencing entities when IDs are nil
        mrr.team_key = team_key
        mrr.meeting_program_key = meeting_program_key
        # Result data
        mrr.rank = rank_int
        mrr.minutes = timing_hash[:minutes]
        mrr.seconds = timing_hash[:seconds]
        mrr.hundredths = timing_hash[:hundredths]
        mrr.disqualified = disqualified_flag
        mrr.standard_points = (result['standard_points'] || result['standardPoints'] || 0).to_f
        mrr.meeting_points = (result['meeting_points'] || result['meetingPoints'] || 0).to_f
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      @stats[:errors] << "MRR error for #{import_key}: #{e.message}"
      nil
    end

    # Create relay swimmer records for a given MRR
    # Uses lap data to extract swimmer info and timing
    def create_relay_swimmers(_mrr, result, mrr_import_key)
      laps = result['laps'] || []

      laps.each_with_index do |lap, idx|
        relay_order = idx + 1

        # Find swimmer data from Phase 3 (returns both ID and full key when matched)
        # Builds a mock result hash for the lap swimmer
        lap_result = { 'swimmer' => lap['swimmer'] }
        swimmer_data = find_swimmer_data(lap_result)
        swimmer_id = swimmer_data[:swimmer_id]
        swimmer_key = swimmer_data[:swimmer_key] # Full Phase 3 key if matched

        # Parse lap timing for MRS (each lap is the swimmer's leg timing)
        delta = parse_timing_string(lap['delta'])

        # Extract distance from lap
        distance_str = lap['distance'] || lap['length_in_meters'] || lap['lengthInMeters']
        length = distance_str.to_s.gsub(/\D/, '').to_i

        rs_import_key = "#{mrr_import_key}-swimmer#{relay_order}"

        # Use find_or_create to handle potential duplicates gracefully
        GogglesDb::DataImportMeetingRelaySwimmer.find_or_create_by!(import_key: rs_import_key) do |rs|
          rs.parent_import_key = mrr_import_key
          rs.phase_file_path = source_path
          # DB foreign keys (may be nil for unmatched entities)
          rs.swimmer_id = swimmer_id
          # String keys for referencing entities when IDs are nil (Full Phase 3 key if matched)
          rs.swimmer_key = swimmer_key
          rs.meeting_relay_result_key = mrr_import_key
          # Leg data
          rs.relay_order = relay_order
          rs.length_in_meters = length
          rs.minutes = delta[:minutes]
          rs.seconds = delta[:seconds]
          rs.hundredths = delta[:hundredths]
        end

        @stats[:relay_swimmers_created] += 1
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        @stats[:errors] << "RelaySwimmer error for #{rs_import_key}: #{e.message}"
      end
    end

    # Create relay lap records for a given MRR
    def create_relay_laps(_mrr, result, mrr_import_key) # rubocop:disable Metrics/AbcSize
      laps = result['laps'] || []
      previous_from_start = { minutes: 0, seconds: 0, hundredths: 0 }

      laps.each_with_index do |lap, idx|
        relay_order = idx + 1

        # Parse distance: "50m" → 50
        distance_str = lap['distance'] || lap['length_in_meters'] || lap['lengthInMeters']
        length = distance_str.to_s.gsub(/\D/, '').to_i
        next if length.zero?

        # Parse delta (split time) from source
        # Real LT4 relay data has only 'delta', not cumulative 'timing'
        delta = parse_timing_string(lap['delta'] || lap['timing'])

        # Compute cumulative timing by adding delta to previous
        from_start = compute_timing_sum(previous_from_start, delta)

        lap_import_key = "#{mrr_import_key}-lap#{relay_order}"
        # Reference the relay swimmer for this leg
        relay_swimmer_import_key = "#{mrr_import_key}-swimmer#{relay_order}"

        # Use find_or_create to handle potential duplicates gracefully
        GogglesDb::DataImportRelayLap.find_or_create_by!(import_key: lap_import_key) do |record|
          record.parent_import_key = mrr_import_key
          record.phase_file_path = source_path
          # String key for referencing parent relay swimmer
          record.meeting_relay_swimmer_key = relay_swimmer_import_key
          # Lap data
          record.length_in_meters = length
          record.minutes = delta[:minutes]
          record.seconds = delta[:seconds]
          record.hundredths = delta[:hundredths]
          record.minutes_from_start = from_start[:minutes]
          record.seconds_from_start = from_start[:seconds]
          record.hundredths_from_start = from_start[:hundredths]
        end

        @stats[:relay_laps_created] += 1
        previous_from_start = from_start
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        @stats[:errors] << "RelayLap error for #{lap_import_key}: #{e.message}"
      end
    end

    # Find swimmer_id from phase 3 using flexible key matching
    # Supports matching by partial key (ignoring gender prefix)
    # Phase 3 keys: "F|ANTONIOLI|Manuela|1983" or "|ANGELINI|Giulio|2002"
    # Lookup keys: "ANTONIOLI|Manuela|1983" (without gender)
    def find_swimmer_id_by_key(swimmer_key)
      return nil if swimmer_key.blank?

      swimmers = phase3_data&.dig('data', 'swimmers') || []

      # First try exact match
      swimmer = swimmers.find { |s| s['key'] == swimmer_key }
      return swimmer['swimmer_id'] if swimmer&.dig('swimmer_id')

      # Build partial key for matching (|LAST|FIRST|YOB)
      partial_key = normalize_to_partial_key(swimmer_key)
      return nil if partial_key.blank?

      # Find swimmers with matching partial key (ignoring gender prefix)
      matching_swimmers = swimmers.select do |s|
        phase3_partial = normalize_to_partial_key(s['key'])
        phase3_partial == partial_key
      end

      # Return swimmer_id if exactly one match found
      if matching_swimmers.size == 1
        matching_swimmers.first&.dig('swimmer_id')
      elsif matching_swimmers.size > 1
        # Multiple matches - try to find one with swimmer_id
        with_id = matching_swimmers.find { |s| s['swimmer_id'].to_i.positive? }
        with_id&.dig('swimmer_id')
      end
    end

    # Normalize any key format to |LAST|FIRST|YOB (partial key without gender)
    # Input formats:
    #   - "F|ANTONIOLI|Manuela|1983" -> "|ANTONIOLI|Manuela|1983"
    #   - "|ANGELINI|Giulio|2002" -> "|ANGELINI|Giulio|2002"
    #   - "ANTONIOLI|Manuela|1983" -> "|ANTONIOLI|Manuela|1983"
    #   - "PRESICCE|Edoardo|2004|TeamName" -> "|PRESICCE|Edoardo|2004"
    def normalize_to_partial_key(key)
      return nil if key.blank?

      parts = key.to_s.split('|')
      return nil if parts.size < 3

      # Detect format based on parts
      if parts[0].match?(/\A[MF]?\z/i)
        # Format: G|LAST|FIRST|YOB or |LAST|FIRST|YOB
        last = parts[1]
        first = parts[2]
        yob = parts[3]
      else
        # Format: LAST|FIRST|YOB|Team (no gender prefix)
        last = parts[0]
        first = parts[1]
        yob = parts[2]
      end

      return nil if last.blank? || first.blank? || yob.to_s.strip.empty?

      "|#{last}|#{first}|#{yob}"
    end

    # Find swimmer_id from composite key format (e.g., "M|ROSSI|Mario|1978|TeamName")
    def find_swimmer_id_from_composite_key(composite_key)
      parts = composite_key.split('|')
      return nil if parts.size < 4

      last_name = parts[1]
      first_name = parts[2]
      year = parts[3]

      swimmer_key = "#{last_name}|#{first_name}|#{year}"
      find_swimmer_id_by_key(swimmer_key)
    end

    # Extract season from phase 1 data for category computation
    def extract_season
      return nil unless phase1_data

      season_id = phase1_data.dig('data', 'season_id')
      return nil unless season_id

      GogglesDb::Season.find_by(id: season_id)
    end

    # Register a program in the programs collection
    # Only stores program metadata (headers), NOT results (results stay in temp tables)
    # Groups by program_key (session + event + category + gender)
    def add_to_programs(session_order:, event_key:, event_code:, category:, gender:, meeting_program_id:, relay: false)
      program_key = build_program_key(session_order, event_code, category, gender)

      # Initialize program header if not exists
      unless @programs.key?(program_key)
        @programs[program_key] = {
          'session_order' => session_order.to_i,
          'event_key' => event_key,        # Links to phase4 events[].key
          'event_code' => event_code,      # Human-readable code (e.g., "S4X50MI")
          'category_code' => category,
          'gender_code' => gender,
          'meeting_program_id' => meeting_program_id,
          'relay' => relay,
          'result_count' => 0
        }
      end

      # Increment result count for this program
      @programs[program_key]['result_count'] += 1
    end

    # Write phase5 output JSON file with program groups
    def write_phase5_output!
      Rails.logger.info("[Phase5Populator] Writing phase5 output to #{phase5_output_path}")

      # Convert programs hash to sorted array
      programs_array = @programs.values.sort_by do |prog|
        [prog['session_order'], prog['event_code'], prog['category_code'], prog['gender_code']]
      end

      output_data = {
        'name' => 'phase5',
        'source_file' => File.basename(source_path),
        'total_programs' => programs_array.size,
        'total_results' => programs_array.sum { |p| p['result_count'] },
        'programs' => programs_array
      }

      File.write(phase5_output_path, JSON.pretty_generate(output_data))
      Rails.logger.info("[Phase5Populator] Phase5 output written: #{programs_array.size} programs, #{output_data['total_results']} results")
    end

    # Broadcast progress updates via ActionCable for real-time UI feedback
    def broadcast_progress(message, current, total)
      ActionCable.server.broadcast(
        'ImportStatusChannel',
        { msg: message, progress: current, total: total }
      )
    rescue StandardError => e
      Rails.logger&.warn("[Phase5Populator] Failed to broadcast progress: #{e.message}")
    end
  end
end
