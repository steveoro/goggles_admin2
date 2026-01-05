# frozen_string_literal: true

module Import
  module Solvers
    # Builds Phase 4 payload (Events) from a LT2/LT4 source JSON.
    # - Groups events by sessions when session info is present; otherwise
    #   falls back to source section order and per-section row order.
    # - Stores event attributes: key, distance, stroke, event_order, session_order,
    #   event_type_id (matched from DB), heat_type_id (default: 3=Finals), heat_type (default: "F")
    #
    # It does not persist any DB records; it only prepares the JSON for UI review.
    class EventSolver
      def initialize(season:)
        @season = season
      end

      # opts:
      # - :source_path (String)
      # - :lt_format (Integer, 2 or 4)
      # - :phase_path (String, optional custom output path)
      # - :phase1_path (String, optional, for meeting_session_id lookups)
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def build!(opts = {})
        source_path = opts.fetch(:source_path)
        lt_format = opts.fetch(:lt_format, 2).to_i
        phase_path = opts[:phase_path]
        data_hash = JSON.parse(File.read(source_path))

        # Load phase1 data for meeting_session_id lookups
        phase1_path = opts[:phase1_path] || default_phase_path_for_phase(source_path, 1)
        @phase1_data = File.exist?(phase1_path) ? JSON.parse(File.read(phase1_path)) : nil

        sessions = []
        # Priority 1: LT4 format (events array) - Microplus crawler output
        if data_hash['events'].is_a?(Array) && data_hash['events'].any?
          arr = data_hash['events']
          sessions_map = Hash.new { |h, k| h[k] = { 'session_order' => k, 'events' => [], '__seen__' => {} } }

          arr.each_with_index do |ev, idx_ev|
            # Distance / stroke support for LT4 (eventLength, eventStroke) and generic fields
            distance = ev['distance'] || ev['distanceInMeters'] || ev['eventLength']
            stroke = ev['stroke'] || ev['style'] || ev['eventStroke']
            is_relay = ev['relay'] == true
            event_gender = ev['eventGender'].to_s.strip.upcase # M, F, or X

            # Try to derive from eventCode
            if distance.to_s.strip.empty? || stroke.to_s.strip.empty?
              code = ev['eventCode'].to_s
              if code.match?(/\A\d{2,4}[A-Z]{2}\z/)
                # Individual event code: "200RA", "100SL"
                distance = code.gsub(/[^0-9]/, '') if distance.to_s.strip.empty?
                stroke = code.gsub(/[^A-Z]/, '') if stroke.to_s.strip.empty?
              elsif code.match?(/\A[MS]?\d+[xX]\d+[A-Z]{2}\z/i)
                # Relay event code: "4x50SL", "S4X50MI", "M4X50SL"
                # Parse participants and phase length
                match = code.match(/(\d+)[xX](\d+)/i)
                if match
                  participants = match[1].to_i
                  phase_length = match[2].to_i
                  distance = (participants * phase_length).to_s if distance.to_s.strip.empty?
                  # Extract stroke code (last 2 letters)
                  stroke = code.match(/([A-Z]{2})\z/)[1] if stroke.to_s.strip.empty?
                  is_relay = true
                end
              end
            end
            next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

            session_order = ev['sessionOrder'] || 1
            event_order = ev['eventOrder'] || (idx_ev + 1)

            # Build event key and find event_type_id
            if is_relay
              # Build full relay code from eventGender:
              # - M or F (same-sex) → prefix 'S' (e.g., S4X50SL)
              # - X (mixed) → prefix 'M' (e.g., M4X50SL)
              gender_prefix = event_gender == 'X' ? 'M' : 'S'
              # Normalize: 4x50 → 4X50
              normalized_distance = distance.to_s.gsub(/x/i, 'X').upcase
              full_relay_code = "#{gender_prefix}#{normalized_distance}#{stroke}".upcase
              key = full_relay_code
              event_type_id = find_relay_event_type_id(full_relay_code)
            else
              key = ev['eventCode'].presence || "#{distance}#{stroke}"
              event_type_id = find_event_type_id(distance, stroke)
            end

            bucket = sessions_map[session_order]
            next if bucket['__seen__'][key]

            event_hash = {
              'key' => key,
              'distance' => distance,
              'stroke' => stroke,
              'relay' => is_relay,
              'event_order' => event_order,
              'session_order' => session_order,
              'heat_type_id' => 3, # Default: Finals
              'heat_type' => 'F'   # Finals code
            }
            event_hash['event_type_id'] = event_type_id if event_type_id.present?

            # Enhance with meeting_session_id and meeting_event_id matching
            enhance_event_with_matching!(event_hash, session_order)

            bucket['events'] << event_hash
            bucket['__seen__'][key] = true
          end

          sessions = sessions_map.values.map do |h|
            h.delete('__seen__')
            h['events'].sort_by! { |e| e['event_order'].to_i }
            h
          end.sort_by { |s| s['session_order'].to_i }

        # Priority 2: LT2 format (sections array) - Legacy/PDF parsed
        elsif data_hash['sections'].is_a?(Array) && data_hash['sections'].any?
          # Check if this is a relay-only file (all sections are relays)
          all_relay = data_hash['sections'].all? do |sec|
            rows = sec['rows'] || []
            rows.any? { |row| row['relay'] == true }
          end

          if all_relay
            # For relay files, group all sections into ONE session with events grouped by gender
            seen = {}
            events = []

            data_hash['sections'].each_with_index do |sec, idx|
              rows = sec['rows'] || []
              next if rows.empty?

              # Parse relay details from section title
              distance, stroke, relay_code = parse_relay_event_from_title(sec['title'], sec['fin_sesso'])
              next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

              # Use relay_code + gender as key to group by unique event/gender combinations
              gender = sec['fin_sesso'].to_s.strip.upcase
              key = "#{relay_code}|#{gender}"
              next if seen[key]

              # Use first available session order (usually from phase1 data)
              session_order = sec['sessionOrder'] || sec['session_order'] || sec['order'] || 1

              event_hash = {
                'key' => relay_code,
                'distance' => distance,
                'stroke' => stroke,
                'relay' => true,
                'gender' => gender,
                'event_order' => idx + 1,
                'session_order' => session_order,
                'heat_type_id' => 3, # Default: Finals
                'heat_type' => 'F'   # Finals code
              }

              # Try to find matching event_type_id
              event_type_id = find_relay_event_type_id(relay_code)
              event_hash['event_type_id'] = event_type_id if event_type_id.present?

              # Enhance with meeting_session_id and meeting_event_id matching
              enhance_event_with_matching!(event_hash, session_order)

              events << event_hash
              seen[key] = true
            end

            # All relay events go in the FIRST session
            first_session_order = events.first&.dig('session_order') || 1
            events.each { |e| e['session_order'] = first_session_order }
            events.sort_by! { |e| e['event_order'].to_i }
            sessions << { 'session_order' => first_session_order, 'events' => events }
          else
            # For individual/mixed files, process sections normally
            data_hash['sections'].each_with_index do |sec, idx|
              rows = sec['rows'] || []
              # Prefer explicit session order from JSON; else use index + 1
              session_order = sec['sessionOrder'] || sec['session_order'] || sec['order'] || (idx + 1)

              # Collect unique events within session
              seen = {}
              events = []
              rows.each_with_index do |row, r_idx|
                # Check if this is a relay row
                is_relay = row['relay'] == true || sec['relay'] == true

                # For relays, parse event details from section title
                if is_relay
                  distance, stroke, relay_code = parse_relay_event_from_title(sec['title'], sec['fin_sesso'])
                  next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?
                else
                  # For individual events, derive distance and stroke from row
                  distance = row['distance'] || row['distanceInMeters'] || row['evento_distanza'] || row['distanza']
                  stroke = row['stroke'] || row['style'] || row['fin_stile'] || row['stile']
                  next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

                  relay_code = nil
                end

                # Event order if present; else fallback to first appearance order
                event_order = row['eventOrder'] || row['evento_ordine'] || row['event_order'] || (r_idx + 1)

                key = relay_code || [distance, stroke].join('|')
                next if seen[key]

                event_hash = {
                  'key' => key,
                  'distance' => distance,
                  'stroke' => stroke,
                  'relay' => is_relay,
                  'event_order' => event_order,
                  'session_order' => session_order,
                  'heat_type_id' => 3, # Default: Finals
                  'heat_type' => 'F'   # Finals code
                }

                # Try to find matching event_type_id
                event_type_id = if relay_code
                                  find_relay_event_type_id(relay_code)
                                else
                                  find_event_type_id(distance, stroke)
                                end
                event_hash['event_type_id'] = event_type_id if event_type_id.present?

                # Enhance with meeting_session_id and meeting_event_id matching
                enhance_event_with_matching!(event_hash, session_order)

                events << event_hash
                seen[key] = true
              end

              # Sort by event_order for stable UI display
              events.sort_by! { |e| e['event_order'].to_i }
              sessions << { 'session_order' => session_order, 'events' => events }
            end
          end
        else
          # No recognizable structure found
          Rails.logger.warn("[EventSolver] No events[] or sections[] found in #{source_path}")
          sessions = []
        end

        payload = { 'sessions' => sessions }
        pfm = PhaseFileManager.new(phase_path || default_phase_path_for(source_path))
        meta = {
          'source_path' => source_path,
          'generated_at' => Time.now.utc.iso8601,
          'season_id' => @season.id,
          'layoutType' => lt_format,
          'phase' => 4
        }
        pfm.write!(data: payload, meta: meta)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      private

      def default_phase_path_for(source_path)
        dir = File.dirname(source_path)
        base = File.basename(source_path, File.extname(source_path))
        File.join(dir, "#{base}-phase4.json")
      end

      def default_phase_path_for_phase(source_path, phase_num)
        dir = File.dirname(source_path)
        base = File.basename(source_path, File.extname(source_path))
        File.join(dir, "#{base}-phase#{phase_num}.json")
      end

      # Find EventType ID for individual events by constructing the code from distance + stroke
      # Example: distance=200, stroke="RA" => code="200RA" => EventType.id=21
      def find_event_type_id(distance, stroke)
        return nil if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

        code = "#{distance}#{stroke}".upcase
        event_type = GogglesDb::EventType.find_by(code: code, relay: false)
        event_type&.id
      end

      # Enhance event hash with meeting_session_id and matching meeting_event_id
      # Modifies event_hash in place to add:
      # - meeting_session_id (from phase1 sessions by session_order)
      # - meeting_event_id (matched from DB if possible)
      def enhance_event_with_matching!(event_hash, session_order)
        # Find meeting_session_id from phase1 data
        meeting_session_id = find_meeting_session_id_by_order(session_order)
        event_hash['meeting_session_id'] = meeting_session_id

        # Guard clause: skip matching if we don't have both required keys
        return unless meeting_session_id && event_hash['event_type_id']

        # Try to match existing MeetingEvent
        existing = GogglesDb::MeetingEvent.find_by(
          meeting_session_id: meeting_session_id,
          event_type_id: event_hash['event_type_id']
        )

        if existing
          event_hash['meeting_event_id'] = existing.id
          Rails.logger.info("[EventSolver] Matched existing MeetingEvent ID=#{existing.id} for #{event_hash['key']}")
        else
          event_hash['meeting_event_id'] = nil
          Rails.logger.debug { "[EventSolver] No existing event found for #{event_hash['key']} (will create new)" }
        end
      rescue StandardError => e
        Rails.logger.error("[EventSolver] Error matching event for #{event_hash['key']}: #{e.message}")
        event_hash['meeting_event_id'] = nil
      end

      # Find meeting_session_id from phase1 data by session_order
      def find_meeting_session_id_by_order(session_order)
        return nil unless @phase1_data

        sessions = Array(@phase1_data.dig('data', 'meeting_session'))
        session = sessions.find { |s| s['session_order'].to_i == session_order.to_i }
        session&.dig('id')
      end

      # Parse relay event details from section title
      # Example: "4x50 m Misti - M80" with fin_sesso="F"
      # Returns: [distance, stroke, event_code]
      # - distance: total event length (e.g., 200 for 4x50)
      # - stroke: stroke code (e.g., "MI" for mixed relay, "SL" for freestyle)
      # - event_code: full event type code (e.g., "S4X50MI" or "M4X50SL")
      def parse_relay_event_from_title(title, fin_sesso)
        return [nil, nil, nil] if title.to_s.strip.empty?

        # Match pattern like "4x50 m" or "4X50m" from title
        match = title.match(/(\d+)\s*[xX]\s*(\d+)\s*m/i)
        return [nil, nil, nil] unless match

        participants = match[1].to_i
        phase_length = match[2].to_i
        total_distance = participants * phase_length

        # Determine stroke from title keywords (italian)
        stroke_code = case title
                      when /misti|medley/i
                        'MI' # Mixed relay (backstroke, breaststroke, butterfly, freestyle) - stroke_type_id=10
                      when /stile\s*libero|freestyle/i
                        'SL' # Freestyle
                      when /dorso|backstroke/i
                        'DO' # Backstroke
                      when /rana|breaststroke/i
                        'RA' # Breaststroke
                      when /farfalla|delfino|butterfly/i
                        'FA' # Butterfly
                      else
                        raise "Unable detect stroke code from title '#{title}'"
                      end

        # Determine mixed gender prefix: 'M' for mixed, 'S' for same gender
        gender_prefix = fin_sesso.to_s.strip.upcase == 'X' ? 'M' : 'S'

        # Build event code: <gender_prefix><participants>X<phase_length><stroke>
        event_code = "#{gender_prefix}#{participants}X#{phase_length}#{stroke_code}"

        [total_distance, stroke_code, event_code]
      end

      # Find relay EventType ID by event code
      # Example: "S4X50MX" => finds EventType with code="S4X50MX"
      def find_relay_event_type_id(event_code)
        return nil if event_code.to_s.strip.empty?

        event_type = GogglesDb::EventType.find_by(code: event_code, relay: true)
        event_type&.id
      end
    end
  end
end
