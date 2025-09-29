# frozen_string_literal: true

module Import
  module Solvers
    # Builds Phase 4 payload (Events) from a LT2/LT4 source JSON.
    # - Groups events by sessions when session info is present; otherwise
    #   falls back to source section order and per-section row order.
    # - Keeps a minimal set of attributes: key, distance, stroke, event_order, session_order
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
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def build!(opts = {})
        source_path = opts.fetch(:source_path)
        lt_format = opts.fetch(:lt_format, 2).to_i
        phase_path = opts[:phase_path]
        data_hash = JSON.parse(File.read(source_path))

        sessions = []
        if data_hash['sections'].is_a?(Array)
          data_hash['sections'].each_with_index do |sec, idx|
            rows = (sec['rows'] || [])
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

              events << {
                'key' => key,
                'distance' => distance,
                'stroke' => stroke,
                'event_order' => event_order,
                'session_order' => session_order
              }
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

            bucket['events'] << {
              'key' => key,
              'distance' => distance,
              'stroke' => stroke,
              'event_order' => event_order,
              'session_order' => session_order
            }
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
    end
  end
end
