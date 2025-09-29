# frozen_string_literal: true

module Import
  module Solvers
    # Builds Phase 5 payload (Results) from a LT2/LT4 source JSON.
    # Minimal scaffold: groups by sessions if available, otherwise by a single bucket,
    # and for each event stores key metadata plus results_count only.
    #
    # This is intentionally minimal to enable UI scaffolding; it can be enriched later
    # with detailed per-result rows when we finalize the structure we want to review/edit.
    class ResultSolver
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
        if data_hash['sections'].is_a?(Array)
          # LT2-ish: we don't have results inline per row; build by unique event per section
          data_hash['sections'].each_with_index do |sec, idx|
            rows = sec['rows'] || []
            session_order = sec['sessionOrder'] || sec['session_order'] || sec['order'] || (idx + 1)
            seen = {}
            events = []
            rows.each_with_index do |row, r_idx|
              distance = row['distance'] || row['distanceInMeters'] || row['evento_distanza'] || row['distanza']
              stroke = row['stroke'] || row['style'] || row['fin_stile'] || row['stile']
              next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

              event_order = row['eventOrder'] || row['evento_ordine'] || row['event_order'] || (r_idx + 1)
              key = [distance, stroke].join('|')
              next if seen[key]

              events << {
                'key' => key,
                'distance' => distance,
                'stroke' => stroke,
                'gender' => row['gender'] || row['fin_sesso'],
                'event_order' => event_order,
                'session_order' => session_order,
                'results_count' => 0, # unknown in LT2 at this point
                'genders' => []
              }
              seen[key] = true
            end
            events.sort_by! { |e| e['event_order'].to_i }
            sessions << { 'session_order' => session_order, 'events' => events }
          end
        else
          # LT4: events array with results
          arr = data_hash['events'] || []
          # Per-session aggregator; within each session aggregate by event key (eventCode or distance|stroke)
          sessions_map = Hash.new { |h, k| h[k] = { 'session_order' => k, 'events_map' => {} } }

          arr.each_with_index do |ev, idx_ev|
            next if ev['relay'] == true

            distance = ev['distance'] || ev['distanceInMeters'] || ev['eventLength']
            stroke = ev['stroke'] || ev['style'] || ev['eventStroke']
            if (distance.to_s.strip.empty? || stroke.to_s.strip.empty?) && ev['eventCode'].to_s.match?(/\A\d{2,4}[A-Z]{2}\z/)
              code = ev['eventCode']
              distance = code.gsub(/[^0-9]/, '') if distance.to_s.strip.empty?
              stroke = code.gsub(/[^A-Z]/, '') if stroke.to_s.strip.empty?
            end
            next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?

            session_order = ev['sessionOrder'] || 1
            event_order = ev['eventOrder'] || (idx_ev + 1)
            key = ev['eventCode'].presence || [distance, stroke].join('|')
            gender = (ev['eventGender'] || ev['gender']).to_s
            results = Array(ev['results'])

            bucket = sessions_map[session_order]
            emap = bucket['events_map']
            # Initialize event aggregate if missing
            unless emap[key]
              emap[key] = {
                'key' => key,
                'distance' => distance,
                'stroke' => stroke,
                'event_order' => event_order,
                'session_order' => session_order,
                'results_count' => 0,
                'genders_map' => Hash.new { |h2, g| h2[g] = { 'gender' => g, 'categories' => Hash.new(0), 'results_count' => 0 } }
              }
            end
            agg = emap[key]
            # Update minimal fields keeping the earliest event_order
            agg['event_order'] = [agg['event_order'].to_i, event_order.to_i].min

            # Aggregate results into genders/categories
            if gender.present?
              agg['genders_map'][gender] # ensure group exists
            end
            results.each do |res|
              g = (res['gender'] || gender).to_s
              c = res['category'] || res['categoryTypeCode'] || res['category_code'] || res['cat'] || res['category_type_code']
              c = c.to_s
              agg['genders_map'][g]['results_count'] += 1
              agg['genders_map'][g]['categories'][c] += 1 if c.present?
              agg['results_count'] += 1
            end
          end

          # Finalize sessions/events arrays
          sessions = sessions_map.values.map do |h|
            events = h['events_map'].values.map do |eagg|
              genders_summary = eagg['genders_map'].values.map do |gh|
                {
                  'gender' => gh['gender'],
                  'results_count' => gh['results_count'],
                  'categories' => gh['categories'].map { |cc, cnt| { 'category' => cc, 'results_count' => cnt } }.sort_by { |hcat| hcat['category'].to_s }
                }
              end.sort_by { |hg| hg[:gender].to_s }

              {
                'key' => eagg['key'],
                'distance' => eagg['distance'],
                'stroke' => eagg['stroke'],
                'event_order' => eagg['event_order'],
                'session_order' => eagg['session_order'],
                'results_count' => eagg['results_count'],
                'genders' => genders_summary
              }
            end.sort_by { |evh| evh['event_order'].to_i }

            { 'session_order' => h['session_order'], 'events' => events }
          end.sort_by { |s| s['session_order'].to_i }
        end

        payload = { 'sessions' => sessions }
        pfm = PhaseFileManager.new(phase_path || default_phase_path_for(source_path))
        meta = {
          'source_path' => source_path,
          'generated_at' => Time.now.utc.iso8601,
          'season_id' => @season.id,
          'lt_format' => lt_format,
          'phase' => 5
        }
        pfm.write!(data: payload, meta: meta)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/MethodLength, Metrics/CyclomaticComplexity

      private

      def default_phase_path_for(source_path)
        dir = File.dirname(source_path)
        base = File.basename(source_path, File.extname(source_path))
        File.join(dir, "#{base}-phase5.json")
      end
    end
  end
end
