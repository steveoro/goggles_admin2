# frozen_string_literal: true

module Import
  module Solvers
    # Builds Phase 5 payload (Results) from a LT2/LT4 source JSON.
    # Minimal scaffold: groups by sessions if available, otherwise by a single bucket,
    # and for each event stores key metadata plus results_count only.
    #
    # This is intentionally minimal to enable UI scaffolding; it can be enriched later
    # with detailed per-result rows when we finalize the structure we want to review/edit.
    class ResultSolver # rubocop:disable Metrics/ClassLength
      def initialize(season:)
        @season = season
      end

      # opts:
      # - :source_path (String)
      # - :lt_format (Integer, 2 or 4)
      # - :phase_path (String, optional custom output path)
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
      def build!(opts = {})
        source_path = opts.fetch(:source_path)
        lt_format = opts.fetch(:lt_format, 2).to_i
        phase_path = opts[:phase_path]
        data_hash = JSON.parse(File.read(source_path))

        sessions = []

        # Priority 1: LT4 format (events array) - Microplus crawler output
        if data_hash['events'].is_a?(Array) && data_hash['events'].any?
          arr = data_hash['events']
          # Per-session aggregator; within each session aggregate by event key (eventCode or distance|stroke)
          sessions_map = Hash.new { |h, k| h[k] = { 'session_order' => k, 'events' => [] } }
          # Track unique event keys per session (to avoid duplicates)
          seen_map = Hash.new { |h, k| h[k] = {} }

          arr.each_with_index do |event, _ev_idx|
            session_order = event['sessionOrder'] || 1
            distance = event['distance'] || event['distanceInMeters'] || event['eventLength']
            stroke = event['stroke'] || event['style'] || event['eventStroke']
            is_relay = event['relay'] == true

            next if distance.blank? || stroke.blank?

            event_code = event['eventCode'].presence || "#{distance}#{stroke}"
            key = event_code
            session_bucket = sessions_map[session_order]
            seen_bucket = seen_map[session_order]
            next if seen_bucket[key]

            # Count results in this event
            results = event['results'] || []
            results_count = results.size

            # Group by gender for individual events (relay events may have mixed genders)
            genders_hash = {}
            results.each do |result|
              gender = result['gender'] || result['gender_type'] || result['gender_type_code'] || event['eventGender'] || 'X'
              genders_hash[gender] ||= { 'gender' => gender, 'results_count' => 0, 'categories' => [] }
              genders_hash[gender]['results_count'] += 1

              category = result['category'] || result['categoryTypeCode']
              genders_hash[gender]['categories'] << category if category && genders_hash[gender]['categories'].exclude?(category)
            end

            session_bucket['events'] << {
              'key' => key,
              'distance' => distance,
              'stroke' => stroke,
              'relay' => is_relay,
              'event_order' => event['eventOrder'] || 1,
              'session_order' => session_order,
              'results_count' => results_count,
              'genders' => genders_hash.values.sort_by { |g| g['gender'] }
            }
            seen_bucket[key] = true
          end

          sessions = sessions_map.values.map do |h|
            h['events'].sort_by! { |e| e['event_order'].to_i }
            h
          end.sort_by { |s| s['session_order'].to_i }

        # Priority 2: LT2 format (sections array) - Legacy/PDF parsed
        elsif data_hash['sections'].is_a?(Array) && data_hash['sections'].any?
          total = data_hash['sections'].size
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

              # Count results in this section
              results_count = rows.size

              # Use first available session order
              session_order = sec['sessionOrder'] || sec['session_order'] || sec['order'] || 1

              events << {
                'key' => relay_code,
                'distance' => distance,
                'stroke' => stroke,
                'relay' => true,
                'gender' => gender,
                'event_order' => idx + 1,
                'session_order' => session_order,
                'results_count' => results_count,
                'genders' => [{ 'gender' => gender, 'results_count' => results_count, 'categories' => [] }]
              }
              seen[key] = true
              broadcast_progress('map result sections', idx + 1, total)
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
              session_order = sec['sessionOrder'] || sec['session_order'] || sec['order'] || (idx + 1)
              seen = {}
              events = []
              rows.each_with_index do |row, r_idx|
                # Check if this is a relay row
                is_relay = row['relay'] == true || sec['relay'] == true

                if is_relay
                  # Parse relay details from section title
                  distance, stroke, relay_code = parse_relay_event_from_title(sec['title'], sec['fin_sesso'])
                  next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

                  key = relay_code
                else
                  # Individual event
                  distance = row['distance'] || row['distanceInMeters'] || row['evento_distanza'] || row['distanza']
                  stroke = row['stroke'] || row['style'] || row['fin_stile'] || row['stile']
                  next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

                  key = [distance, stroke].join('|')
                end

                next if seen[key]

                event_order = row['eventOrder'] || row['evento_ordine'] || row['event_order'] || (r_idx + 1)

                events << {
                  'key' => key,
                  'distance' => distance,
                  'stroke' => stroke,
                  'relay' => is_relay,
                  'gender' => row['gender'] || row['fin_sesso'] || sec['fin_sesso'],
                  'event_order' => event_order,
                  'session_order' => session_order,
                  'results_count' => 0, # unknown in LT2 at this point
                  'genders' => []
                }
                seen[key] = true
              end
              events.sort_by! { |e| e['event_order'].to_i }
              sessions << { 'session_order' => session_order, 'events' => events }
              broadcast_progress('map result sections', idx + 1, total)
            end
          end

        else
          # No recognizable structure found
          Rails.logger.warn("[ResultSolver] No events[] or sections[] found in #{source_path}")
          sessions = []
        end

        payload = { 'sessions' => sessions }
        pfm = PhaseFileManager.new(phase_path || default_phase_path_for(source_path))
        meta = {
          'source_path' => source_path,
          'generated_at' => Time.now.utc.iso8601,
          'season_id' => @season.id,
          'layoutType' => lt_format,
          'phase' => 5
        }
        pfm.write!(data: payload, meta: meta)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      private

      def default_phase_path_for(source_path)
        dir = File.dirname(source_path)
        base = File.basename(source_path, File.extname(source_path))
        File.join(dir, "#{base}-phase5.json")
      end

      # Parse relay event details from section title
      # Example: "4x50 m Misti - M80" with fin_sesso="F"
      # Returns: [distance, stroke, event_code]
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
                        'SL' # Default to freestyle if unknown
                      end

        # Determine mixed gender prefix: 'M' for mixed, 'S' for same gender
        gender_prefix = fin_sesso.to_s.strip.upcase == 'X' ? 'M' : 'S'

        # Build event code: <gender_prefix><participants>X<phase_length><stroke>
        event_code = "#{gender_prefix}#{participants}X#{phase_length}#{stroke_code}"

        [total_distance, stroke_code, event_code]
      end

      # Broadcast progress updates via ActionCable for real-time UI feedback
      def broadcast_progress(message, current, total)
        ActionCable.server.broadcast(
          'ImportStatusChannel',
          { msg: message, progress: current, total: total }
        )
      rescue StandardError => e
        @logger&.warn("[SwimmerSolver] Failed to broadcast progress: #{e.message}")
      end
    end
  end
end
