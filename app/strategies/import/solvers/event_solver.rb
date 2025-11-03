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
        if data_hash['sections'].is_a?(Array)
          data_hash['sections'].each_with_index do |sec, idx|
            rows = sec['rows'] || []
            # Prefer explicit session order from JSON; else use index + 1
            session_order = sec['sessionOrder'] || sec['session_order'] || sec['order'] || (idx + 1)

            # Collect unique events within session
            seen = {}
            events = []
            rows.each_with_index do |row, r_idx|
              # Derive distance and stroke
              distance = row['distance'] || row['distanceInMeters'] || row['evento_distanza'] || row['distanza']
              stroke = row['stroke'] || row['style'] || row['fin_stile'] || row['stile']
              next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

              # Event order if present; else fallback to first appearance order
              event_order = row['eventOrder'] || row['evento_ordine'] || row['event_order'] || (r_idx + 1)

              key = [distance, stroke].join('|')
              next if seen[key]

              event_hash = {
                'key' => key,
                'distance' => distance,
                'stroke' => stroke,
                'event_order' => event_order,
                'session_order' => session_order,
                'heat_type_id' => 3, # Default: Finals
                'heat_type' => 'F'   # Finals code
              }

              # Try to find matching event_type_id based on distance + stroke code
              event_type_id = find_event_type_id(distance, stroke)
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
        else
          # Fallback: no sections, try a flat events array (LT4 style)
          arr = data_hash['events'] || []
          sessions_map = Hash.new { |h, k| h[k] = { 'session_order' => k, 'events' => [], '__seen__' => {} } }

          arr.each_with_index do |ev, idx_ev|
            next if ev['relay'] == true

            # Distance / stroke support for LT4 (eventLength, eventStroke) and generic fields
            distance = ev['distance'] || ev['distanceInMeters'] || ev['eventLength']
            stroke = ev['stroke'] || ev['style'] || ev['eventStroke']

            # Try to derive from eventCode as last resort
            if (distance.to_s.strip.empty? || stroke.to_s.strip.empty?) && ev['eventCode'].to_s.match?(/\A\d{2,4}[A-Z]{2}\z/)
              code = ev['eventCode']
              distance = code.gsub(/[^0-9]/, '') if distance.to_s.strip.empty?
              stroke = code.gsub(/[^A-Z]/, '') if stroke.to_s.strip.empty?
            end
            next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

            session_order = ev['sessionOrder'] || 1
            event_order = ev['eventOrder'] || (idx_ev + 1)
            key = ev['eventCode'].presence || [distance, stroke].join('|')

            bucket = sessions_map[session_order]
            next if bucket['__seen__'][key]

            event_hash = {
              'key' => key,
              'distance' => distance,
              'stroke' => stroke,
              'event_order' => event_order,
              'session_order' => session_order,
              'heat_type_id' => 3, # Default: Finals
              'heat_type' => 'F'   # Finals code
            }

            # Try to find matching event_type_id based on distance + stroke code
            event_type_id = find_event_type_id(distance, stroke)
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
        end

        payload = { 'sessions' => sessions }
        pfm = PhaseFileManager.new(phase_path || default_phase_path_for(source_path))
        meta = {
          'source_path' => source_path,
          'generated_at' => Time.now.utc.iso8601,
          'season_id' => @season.id,
          'lt_format' => lt_format,
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

      # Find EventType ID by constructing the code from distance + stroke
      # Example: distance=200, stroke="RA" => code="200RA" => EventType.id=21
      def find_event_type_id(distance, stroke)
        return nil if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

        code = "#{distance}#{stroke}"
        event_type = GogglesDb::EventType.find_by(code: code)
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

        sessions = Array(@phase1_data.dig('data', 'sessions'))
        session = sessions.find { |s| s['session_order'].to_i == session_order.to_i }
        session&.dig('meeting_session_id')
      end
    end
  end
end
