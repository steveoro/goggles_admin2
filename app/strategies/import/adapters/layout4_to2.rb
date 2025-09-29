# frozen_string_literal: true

module Import
  module Adapters
    # Adapter to normalize a Microplus "layoutType: 4" result JSON
    # into the canonical LT2-like schema consumed by Import::MacroSolver
    # and DataFixController.
    #
    # Public API:
    #   normalized = Import::Adapters::Layout4To2.normalize(data_hash: raw_hash)
    #   # returns a deep-copied Hash matching the LT2 schema expected by MacroSolver
    #
    # Notes:
    # - This adapter is intentionally tolerant: it should return a best-effort structure
    #   even when some optional data is missing, letting the Data-Fix UI fill-in gaps.
    # - We set layoutType to 2 on the returned hash (as per Option A), without touching
    #   the original input hash.
    #
    # rubocop:disable Metrics/ClassLength
    class Layout4To2
      class << self
        def normalize(data_hash:)
          raise ArgumentError, 'data_hash must be a Hash' unless data_hash.is_a?(Hash)

          # Shallow clone + rebuild into canonical structure:
          out = {}

          normalize_header!(data_hash, out)
          normalize_sections!(data_hash, out)

          # Force canonical layoutType in memory:
          out['layoutType'] = 2

          out
        end

        private

        # Header mapping for LT4 -> LT2-like fields
        # LT4 sample keys: title, dates, place, meetingName, competitionType,
        #                  layoutType, seasonId, meetingURL
        #
        # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        def normalize_header!(src, out)
          out['name'] = src['meetingName'].presence || src['title']
          out['meetingURL'] = src['meetingURL']

          # Derive dates ("YYYY-MM-DD,YYYY-MM-DD") into day/month/year parts
          if src['dates'].is_a?(String)
            parts = src['dates'].split(',')
            if parts[0]
              y, m, d = parts[0].split('-')
              assign_date_parts(out, '1', y, m, d)
            end
            if parts[1]
              y2, m2, d2 = parts[1].split('-')
              assign_date_parts(out, '2', y2, m2, d2)
            end
          end

          # Venue/address are typically unknown in LT4; use place as a best-effort fallback
          out['venue1'] = src['place'] if src['place'].present?
          out['address1'] = src['place'] if src['place'].present?

          # Pool length: map from source if available, otherwise leave nil (editable in Step 1)
          out['poolLength'] = src['poolLength'] if src['poolLength'].present?

          # The DataFix controller extracts season_id from the file path; we keep the info if present
          out['season_id'] = src['seasonId'] if src['seasonId'].present?
        end

        def assign_date_parts(out, idx, y, m, d)
          return unless y && m && d

          out["dateYear#{idx}"]  = y
          out["dateMonth#{idx}"] = month_name(m.to_i)
          out["dateDay#{idx}"]   = d
        end

        def month_name(idx)
          # Italian month names expected by existing SessionDate::MONTH_NAMES usage.
          %w[Gennaio Febbraio Marzo Aprile Maggio Giugno Luglio Agosto Settembre Ottobre Novembre Dicembre][idx - 1]
        rescue StandardError
          nil
        end

        # Sections: iterate LT4 events[] and convert each into a canonical section
        # Expected LT4 event keys:
        #   eventCode, eventGender, eventLength, eventStroke, eventDescription, relay, results[]
        # Each result may contain laps[] and either a swimmer key or, for relays, multiple legs.
        def normalize_sections!(src, out)
          out['sections'] = []
          return unless src['events'].is_a?(Array)

          src['events'].each do |evt|
            # Group results by per-row category to generate one canonical section
            # per (event, category, gender) tuple, as expected by MacroSolver.
            grouped = evt['results'].to_a.group_by { |res| res['category'] }

            grouped.each do |cat_code, res_list|
              normalized_cat = evt['relay'] ? normalize_relay_category(cat_code) : cat_code
              title = [evt['eventDescription'].presence || build_title(evt), normalized_cat].compact.join(' - ')
              section = {
                'title' => title,
                'fin_sesso' => evt['eventGender'],
                'fin_sigla_categoria' => normalized_cat,
                'rows' => []
              }

              res_list.each do |res|
                row = if evt['relay']
                        normalize_relay_row(res)
                      else
                        normalize_individual_row(res)
                      end
                # Ensure each row also carries its own category code for downstream logic
                row['fin_sigla_categoria'] ||= normalized_cat
                section['rows'] << row
              end

              out['sections'] << section
            end
          end
        end

        def build_title(evt)
          # Fallback title from eventCode (e.g., "800SL" or "4x50SL"); not localized.
          evt['eventCode'] || 'Evento'
        end

        # Normalize an individual result row into LT2-like row fields
        # LT4 fields seen: ranking, swimmer (composite key), team, timing, category, heat_position, lane, laps[]
        def normalize_individual_row(res)
          swimmer_key = res['swimmer']
          last_name, first_name, year, team = extract_from_swimmer_key(swimmer_key)

          row = {
            'pos' => res['ranking'],
            'name' => [last_name, first_name].compact.join(' ').strip,
            'year' => year,
            'sex' => gender_from_swimmer_key(swimmer_key),
            'team' => res['team'] || team,
            'timing' => res['timing'],
            'score' => res['score'],
            'fin_sigla_categoria' => res['category']
          }.compact

          # Attach laps inline for MacroSolver#process_mir_and_laps
          row['laps'] = if res['laps'].is_a?(Array)
                          res['laps'].map do |lap|
                            inline_key = inline_lap_key(lap['distance'])
                            inline_delta_key = inline_delta_key(lap['distance'])
                            # Also emit inline keys like "lap50" / "delta50" as L2 requires
                            row[inline_key] = lap['timing'] if inline_key
                            row[inline_delta_key] = lap['delta'] if inline_delta_key && lap['delta']

                            {
                              'distance' => lap['distance'],
                              'timing' => lap['timing'],
                              'delta' => lap['delta'],
                              'position' => lap['position']
                            }.compact
                          end
                        else
                          [] # 50m may have empty laps by design
                        end

          row
        end

        # Normalize a relay result row. LT4 typically includes per-leg laps with swimmer keys.
        # We map swimmers to swimmer1..N (name only) and attach relay laps preserving swimmer association.
        def normalize_relay_row(res)
          row = {
            'pos' => res['ranking'],
            'relay' => true,
            'team' => res['team'],
            'timing' => res['timing']
          }.compact

          # Expand swimmers from laps (if provided) or from a dedicated swimmers array if available
          swimmer_keys = collect_swimmer_keys_from_laps(res['laps'])
          swimmer_keys.each_with_index do |skey, idx|
            last_name, first_name, year, _team = extract_from_swimmer_key(skey)
            row["swimmer#{idx + 1}"] = [last_name, first_name].compact.join(' ').strip if skey
            row["year_of_birth#{idx + 1}"] = year if year
            row["gender_type#{idx + 1}"] = gender_from_swimmer_key(skey)
          end

          # Relay laps
          row['laps'] = if res['laps'].is_a?(Array)
                          res['laps'].map do |lap|
                            # Emit inline keys for relays as well (MacroSolver expects lapXX/deltaXX)
                            inline_key = inline_lap_key(lap['distance'])
                            inline_delta_key = inline_delta_key(lap['distance'])
                            row[inline_key] = lap['timing'] if inline_key && lap['timing']
                            row[inline_delta_key] = lap['delta'] if inline_delta_key && lap['delta']

                            {
                              'distance' => lap['distance'],
                              'timing' => lap['timing'],
                              'delta' => lap['delta'],
                              'swimmer' => lap['swimmer'] # keep association for MacroSolver
                            }.compact
                          end
                        else
                          []
                        end

          row
        end

        # Helpers
        def collect_swimmer_keys_from_laps(laps)
          return [] unless laps.is_a?(Array)

          laps.pluck('swimmer').compact.uniq
        end

        # Normalize relay category codes from LT4 to LT2 expected ranges.
        # Examples:
        #  - "U80"   => "60-79"
        #  - "M80"   => "80-99"
        #  - "M100"  => "100-119"
        #  - "M120"  => "120-159" (from here on, 40-year spans)
        #  - "M160"  => "160-199"
        #  - ...
        #  - unknown => "000-999"
        def normalize_relay_category(code)
          return '000-999' if code.to_s.strip.empty?

          up = code.to_s.strip.upcase
          return '60-79' if up == 'U80'

          if (m = up.match(/^M(\d{2,3})$/))
            start_age = m[1].to_i
            end_age = if start_age <= 100
                        start_age + 19
                      elsif start_age == 120
                        159
                      else
                        start_age + 39
                      end
            return format('%d-%d', start_age, end_age)
          end

          '000-999'
        end

        # Convert LT4 "distance" strings like "50m" or "100m" to inline keys expected by L2
        def inline_lap_key(distance_label)
          num = numeric_distance(distance_label)
          return nil unless num

          "lap#{num}"
        end

        def inline_delta_key(distance_label)
          num = numeric_distance(distance_label)
          return nil unless num

          "delta#{num}"
        end

        def numeric_distance(distance_label)
          return nil unless distance_label.is_a?(String)

          # Accept formats like "50m", "800m"; extract leading integer
          md = distance_label.match(/(\d+)/)
          md && md[1]
        end

        # LT4 swimmer key formats:
        #  - Individual: "F|LAST|FIRST|YYYY|TEAM"
        #  - Relay-only unknown gender sometimes lacks gender: "|LAST|FIRST|YYYY|TEAM" or partials
        def extract_from_swimmer_key(skey)
          return [nil, nil, nil, nil] unless skey.is_a?(String)

          parts = skey.split('|')
          # Heuristic: gender may be parts[0] or blank
          if parts.size >= 5
            _gender = parts[0]
            last = parts[1]
            first = parts[2]
            year = parts[3]
            team = parts[4]
            [last, first, year, team]
          else
            # Best-effort for partial keys
            [parts[0], parts[1], parts[2], parts[3]]
          end
        end

        def gender_from_swimmer_key(skey)
          return nil unless skey.is_a?(String)

          g = skey[0]
          %w[F M X].include?(g) ? g : nil
        end
      end
    end
  end
end
