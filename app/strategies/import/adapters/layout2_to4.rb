# frozen_string_literal: true

module Import
  module Adapters
    # Adapter to normalize a crawler "layoutType: 2" result JSON (sections/rows)
    # into the Microplus-like LT4 schema with events array and lookup dictionaries.
    #
    # Public API:
    #   normalized = Import::Adapters::Layout2To4.normalize(data_hash: lt2_hash)
    #   # returns a deep-copied Hash matching the LT4 schema
    #
    # Why LT2→LT4 direction?
    # - LT4 has cleaner lookup dictionaries for swimmers/teams
    # - Allows Phase5Populator to have single code path (LT4 only)
    # - LT4→LT2 creates huge files (several MB), making it impractical
    # - This adapter keeps memory footprint small while normalizing structure
    #
    # Notes:
    # - This adapter is intentionally tolerant: it returns best-effort structure
    #   even when some optional data is missing
    # - We set layoutType to 4 on the returned hash
    # - Relay support included for LT2 relay files (rare but exist from PDF parser)
    #
    # rubocop:disable Metrics/ClassLength
    class Layout2To4
      class << self
        def normalize(data_hash:)
          raise ArgumentError, 'data_hash must be a Hash' unless data_hash.is_a?(Hash)

          # Build normalized LT4 structure:
          out = {}

          normalize_header!(data_hash, out)
          build_lookup_dictionaries!(data_hash, out)
          normalize_events!(data_hash, out)

          # Force LT4 layoutType in memory:
          out['layoutType'] = 4

          out
        end

        private

        # Header mapping for LT2 -> LT4 fields
        # LT2 header keys: name, meetingURL, dateDay1/2, dateMonth1/2, dateYear1/2,
        #                  venue1, poolLength, season_id, etc.
        # LT4 expected: meetingName, meetingURL, dates (ISO format), place, seasonId, poolLength
        #
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def normalize_header!(src, out)
          out['meetingName'] = src['name']
          out['meetingURL'] = src['meetingURL']
          out['manifestURL'] = src['manifestURL']
          out['resultsPdfURL'] = src['resultsPdfURL']

          # Derive dates into "YYYY-MM-DD,YYYY-MM-DD" format
          dates = []
          if src['dateYear1'] && src['dateMonth1'] && src['dateDay1']
            iso_date = format_iso_date(src['dateYear1'], src['dateMonth1'], src['dateDay1'])
            dates << iso_date if iso_date
          end
          if src['dateYear2'] && src['dateMonth2'] && src['dateDay2']
            iso_date = format_iso_date(src['dateYear2'], src['dateMonth2'], src['dateDay2'])
            dates << iso_date if iso_date
          end
          out['dates'] = dates.join(',') if dates.any?

          # Place: use venue1 or address1 as fallback
          out['place'] = src['venue1'].presence || src['address1'].presence

          # Pool length
          out['poolLength'] = src['poolLength'] if src['poolLength'].present?

          # Season ID
          out['seasonId'] = src['season_id'] if src['season_id'].present?

          # Competition type (not usually in LT2, but pass if present)
          out['competitionType'] = src['competitionType'] if src['competitionType'].present?
        end
        # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

        def format_iso_date(year, month, day)
          return nil unless year && month && day

          # Convert Italian month name to number
          month_num = month_number(month)
          return nil unless month_num

          format('%<y>04d-%<m>02d-%<d>02d', y: year.to_i, m: month_num, d: day.to_i)
        rescue StandardError
          nil
        end

        def month_number(month_name)
          return month_name.to_i if month_name.to_s.match?(/^\d+$/)

          # Italian month names to numbers
          months = {
            'gennaio' => 1, 'febbraio' => 2, 'marzo' => 3, 'aprile' => 4,
            'maggio' => 5, 'giugno' => 6, 'luglio' => 7, 'agosto' => 8,
            'settembre' => 9, 'ottobre' => 10, 'novembre' => 11, 'dicembre' => 12
          }
          months[month_name.to_s.downcase]
        end

        # Build LT4-style lookup dictionaries for swimmers and teams
        # Extracts unique swimmers/teams from all sections/rows
        def build_lookup_dictionaries!(src, out)
          swimmers = {}
          teams = {}

          sections = src['sections'] || []
          sections.each do |section|
            rows = section['rows'] || []
            rows.each do |row|
              # Extract swimmer info
              if row['name'] && row['year']
                swimmer_key = build_swimmer_key(row)
                swimmers[swimmer_key] = {
                  'complete_name' => row['name'],
                  'year_of_birth' => row['year'],
                  'gender_type' => row['sex'] || extract_gender_from_section(section)
                }
              end

              # Extract team info
              teams[row['team']] = { 'name' => row['team'] } if row['team']
            end
          end

          out['swimmers'] = swimmers
          out['teams'] = teams
        end

        # Build composite swimmer key in LT4 format: "GENDER|LAST|FIRST|YEAR|TEAM"
        def build_swimmer_key(row)
          name_parts = (row['name'] || '').split(' ', 2)
          last_name = name_parts[0] || ''
          first_name = name_parts[1] || ''
          gender = row['sex'] || 'M'
          year = row['year'] || ''
          team = row['team'] || ''

          "#{gender}|#{last_name}|#{first_name}|#{year}|#{team}"
        end

        def extract_gender_from_section(section)
          section['fin_sesso'] || 'M'
        end

        # Convert sections array into LT4 events array
        # LT2 sections group by (event, category, gender)
        # LT4 events group by event only, with results containing categories
        #
        def normalize_events!(src, out)
          out['events'] = []
          sections = src['sections'] || []

          # Group sections by event code to merge into single LT4 event
          # For relays, keep separate events per gender (since that determines MeetingProgram)
          events_map = {}

          sections.each do |section|
            event_info = extract_event_info(section)
            # For relays, include gender in key to keep F/M/X separate
            event_key = if event_info[:relay]
                          "#{event_info[:code]}_#{event_info[:gender]}"
                        else
                          event_info[:code]
                        end

            events_map[event_key] ||= {
              'eventCode' => event_info[:code],
              'eventGender' => event_info[:gender],
              'eventLength' => event_info[:distance],
              'eventStroke' => event_info[:stroke],
              'eventDescription' => event_info[:description],
              'relay' => event_info[:relay],
              'results' => []
            }

            # Add all rows as results
            (section['rows'] || []).each do |row|
              result = normalize_result(row, section, event_info[:relay])
              events_map[event_key]['results'] << result
            end
          end

          out['events'] = events_map.values
        end

        # Extract event information from section title and metadata
        def extract_event_info(section)
          title = section['title'] || ''
          is_relay = title.match?(/staffetta|relay|4x/i) || section['rows']&.any? { |r| r['relay'] }

          # Parse title like "50 Stile Libero - M20" or "4x50 Mista - 100-119"
          distance, stroke, category = parse_section_title(title)

          {
            code: build_event_code(distance, stroke),
            gender: section['fin_sesso'] || 'M',
            distance: distance,
            stroke: stroke,
            description: extract_description(title),
            category: section['fin_sigla_categoria'] || category,
            relay: is_relay
          }
        end

        def parse_section_title(title)
          # Examples: "50 Stile Libero - M20", "800 RANA - F35", "4x50 Mista - 100-119"
          distance = nil
          stroke = nil

          # Try relay format first: "4x50 Mista", "4x50 Stile Libero"
          # Then individual with category: "100 Stile Libero - M20"
          # Finally fallback without category: "100 Stile Libero"
          m = title.match(/(\d+x\d+|4x\d+)\s+([^-]+?)\s*-/i) ||
              title.match(/(\d+)\s+([^-]+?)\s*-/i) ||
              title.match(/(\d+)\s+(.+)$/i)
          if m
            distance = m[1]
            stroke = normalize_stroke_name(m[2]&.strip || '')
          end

          # Extract category from end of title
          category = title.match(/-\s*([MF]?\d+[-\d]*)\s*$/i)&.captures&.first

          [distance, stroke, category]
        end

        def normalize_stroke_name(stroke_text)
          # Map Italian stroke names to codes (handles multi-word names)
          normalized = stroke_text.to_s.downcase.strip

          # Try exact matches first
          stroke_map = {
            'stile libero' => 'SL', 'stile' => 'SL', 'libero' => 'SL', 'sl' => 'SL',
            'dorso' => 'DO', 'do' => 'DO',
            'rana' => 'RA', 'ra' => 'RA',
            'farfalla' => 'FA', 'delfino' => 'FA', 'fa' => 'FA',
            'misti' => 'MI', 'mista' => 'MI', 'mi' => 'MI'
          }

          stroke_map[normalized] || stroke_text.to_s.upcase
        end

        def build_event_code(distance, stroke)
          return 'EVENT' unless distance && stroke

          "#{distance}#{stroke}"
        end

        def extract_description(title)
          # Remove category suffix
          title.sub(/-\s*[MF]?\d+[-\d]*\s*$/i, '').strip
        end

        # Convert a single LT2 row into LT4 result format
        def normalize_result(row, section, is_relay)
          if is_relay
            normalize_relay_result(row, section)
          else
            normalize_individual_result(row, section)
          end
        end

        def normalize_individual_result(row, section)
          swimmer_key = build_swimmer_key(row)

          result = {
            'ranking' => row['pos'],
            'swimmer' => swimmer_key,
            'team' => row['team'],
            'timing' => row['timing'],
            'score' => row['score'],
            'category' => section['fin_sigla_categoria'] || row['fin_sigla_categoria'],
            'heat_position' => row['heat_position'],
            'lane' => row['lane']
          }.compact

          # Convert laps if present
          if row['laps'].is_a?(Array) && row['laps'].any?
            result['laps'] = row['laps'].map do |lap|
              {
                'distance' => "#{lap['distance']}m",
                'timing' => lap['timing'],
                'delta' => lap['delta'],
                'position' => lap['position']
              }.compact
            end
          elsif inline_laps?(row)
            # Build laps from inline keys (lap50, lap100, etc.)
            result['laps'] = extract_inline_laps(row)
          end

          result
        end

        def normalize_relay_result(row, section)
          result = {
            'ranking' => row['pos'],
            'team' => row['team'],
            'timing' => row['timing'],
            'category' => section['fin_sigla_categoria'] || row['fin_sigla_categoria']
          }.compact

          # Extract relay swimmers
          relay_swimmers = []
          (1..8).each do |i|
            break unless row["swimmer#{i}"]

            relay_swimmers << {
              'complete_name' => row["swimmer#{i}"],
              'year_of_birth' => row["year_of_birth#{i}"],
              'gender_type' => row["gender_type#{i}"]
            }.compact
          end
          result['swimmers'] = relay_swimmers if relay_swimmers.any?

          # Convert relay laps
          if row['laps'].is_a?(Array) && row['laps'].any?
            result['laps'] = row['laps'].map do |lap|
              swimmer_key = lap['swimmer'] if lap['swimmer']
              {
                'distance' => "#{lap['distance']}m",
                'timing' => lap['timing'],
                'delta' => lap['delta'],
                'swimmer' => swimmer_key
              }.compact
            end
          end

          result
        end

        def inline_laps?(row)
          row.keys.any? { |k| k.to_s.match?(/^lap\d+$/) }
        end

        def extract_inline_laps(row)
          laps = []
          # Common lap distances
          [50, 100, 150, 200, 250, 300, 350, 400, 450, 500, 550, 600, 650, 700, 750, 800].each do |dist|
            lap_key = "lap#{dist}"
            delta_key = "delta#{dist}"

            next unless row[lap_key]

            laps << {
              'distance' => "#{dist}m",
              'timing' => row[lap_key],
              'delta' => row[delta_key]
            }.compact
          end
          laps
        end
      end
    end
    # rubocop:enable Metrics/ClassLength
  end
end
