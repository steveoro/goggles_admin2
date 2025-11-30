# frozen_string_literal: true

module Import
  module Solvers
    # SwimmerSolver: builds Phase 3 payload (swimmers and badges)
    #
    # Typical inputs:
    # - LT4: prefer root 'swimmers' dictionary when present (strings or objects)
    # - LT2: fallback scan of sections when LT4 dict missing
    #
    # NOTE:
    # LayoutType is indicative, what really counts is the actual hierarchical structure
    # found in the data file (regardless of specified layout type).
    #
    # Output (phase3 file):
    # {
    #   "_meta": { ... },
    #   "data": {
    #     "season_id": <int>,
    #     "swimmers": [ { "key": "LAST|FIRST|YOB", "last_name": "LAST", "first_name": "FIRST", "year_of_birth": 1970, "gender_type_code": "F", "swimmer_id": 123 } ],
    #     "badges":   [ { "swimmer_key": "...", "team_key": "...", "season_id": 242, "swimmer_id": 123, "team_id": 456, "category_type_id": 789, "badge_id": 999 } ]
    #   }
    # }
    # NOTE: badge_id will be nil for new badges that don't exist in DB yet
    #
    class SwimmerSolver # rubocop:disable Metrics/ClassLength
      def initialize(season:, logger: Rails.logger)
        @season = season
        @logger = logger
      end

      # Build and persist phase3 file
      # opts:
      # - :source_path (String, required)
      # - :lt_format (Integer, 2 or 4)
      # - :phase_path (String, optional custom output path)
      # - :phase1_path (String, optional, for meeting date extraction and category calculation)
      # - :phase2_path (String, optional, for team_id lookups when matching badges)
      #
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def build!(opts = {})
        source_path = opts.fetch(:source_path)
        lt_format = opts.fetch(:lt_format, 2).to_i
        data_hash = JSON.parse(File.read(source_path))

        # Load phase1 and phase2 data for meeting date and team lookups
        phase1_path = opts[:phase1_path] || default_phase_path_for(source_path, 1)
        phase2_path = opts[:phase2_path] || default_phase_path_for(source_path, 2)
        @phase1_data = File.exist?(phase1_path) ? JSON.parse(File.read(phase1_path)) : nil
        @phase2_data = File.exist?(phase2_path) ? JSON.parse(File.read(phase2_path)) : nil
        meeting_date = @phase1_data&.dig('data', 'header_date')

        # Initialize CategoriesCache for season-aware category lookups
        @categories_cache = PdfResults::CategoriesCache.new(@season)

        swimmers = []
        badges = []

        if data_hash['swimmers'].is_a?(Array) || data_hash['swimmers'].is_a?(Hash)
          total = data_hash['swimmers'].size
          if data_hash['swimmers'].is_a?(Array)
            data_hash['swimmers'].each_with_index do |s, idx|
              l, f, yob, gcode, team_name = extract_swimmer_parts(s)
              broadcast_progress('Map swimmers', idx + 1, total)
              next if l.blank? || f.blank? || yob.to_i.zero?

              # Always include leading pipe: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
              key = gcode.present? ? "#{gcode}|#{l}|#{f}|#{yob}" : "|#{l}|#{f}|#{yob}"
              swimmer_entry = build_swimmer_entry(key, l, f, yob.to_i, gcode)
              swimmers << swimmer_entry
              next if team_name.blank?

              # Use swimmer entry's updated key/gender (may have been populated from DB match)
              badges << build_badge_entry(swimmer_entry['key'], team_name, yob.to_i,
                                          swimmer_entry['gender_type_code'], meeting_date)
            end
          else # Hash dictionary: key => swimmerKey, value => details
            data_hash['swimmers'].each_with_index do |(_original_key, v), idx|
              l = v['last_name'] || v['lastName']
              f = v['first_name'] || v['firstName']
              yob = v['year_of_birth'] || v['year']
              gcode = normalize_gender_code(v['gender'] || v['gender_type_code'])
              team_name = v['team']
              broadcast_progress('Map swimmers', idx + 1, total)
              next if l.blank? || f.blank? || yob.to_i.zero?

              # Always include leading pipe: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
              key = gcode.present? ? "#{gcode}|#{l}|#{f}|#{yob}" : "|#{l}|#{f}|#{yob}"
              swimmer_entry = build_swimmer_entry(key, l, f, yob.to_i, gcode)
              swimmers << swimmer_entry
              next if team_name.to_s.strip.empty?

              # Use swimmer entry's updated key/gender (may have been populated from DB match)
              badges << build_badge_entry(swimmer_entry['key'], team_name, yob.to_i,
                                          swimmer_entry['gender_type_code'], meeting_date)
            end
          end

        elsif data_hash['sections'].is_a?(Array)
          # LT2 fallback: scan sections/rows for swimmers and teams (infer badges)
          total = data_hash['sections'].size
          data_hash['sections'].each_with_index do |sec, sec_idx|
            rows = sec['rows'] || []
            gender_code = normalize_gender_code(sec['fin_sesso'])
            rows.each do |row|
              if row['relay']
                # Extract relay swimmers from swimmer1..swimmer8 fields
                team_name = row['team']
                (1..8).each do |idx|
                  swimmer_name = row["swimmer#{idx}"]
                  break if swimmer_name.blank?

                  yob = row["year_of_birth#{idx}"]
                  gtype = row["gender_type#{idx}"]
                  next if swimmer_name.blank? || yob.to_i.zero?

                  # Parse swimmer name (usually "LAST FIRST" format)
                  parts = swimmer_name.to_s.strip.split
                  next if parts.size < 2

                  first = parts.pop
                  last = parts.join(' ')
                  gcode = normalize_gender_code(gtype)
                  # Always include leading pipe: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
                  key = gcode.present? ? "#{gcode}|#{last}|#{first}|#{yob}" : "|#{last}|#{first}|#{yob}"

                  swimmer_entry = build_swimmer_entry(key, last, first, yob.to_i, gcode)
                  swimmers << swimmer_entry
                  next if team_name.to_s.strip.empty?

                  # Use swimmer entry's updated key/gender (may have been populated from DB match)
                  badges << build_badge_entry(swimmer_entry['key'], team_name, yob.to_i,
                                              swimmer_entry['gender_type_code'], meeting_date)
                end
              else
                # Individual result row
                l, f, yob = extract_name_yob_from_row(row)
                next if l.blank? || f.blank? || yob.to_i.zero?

                gcode = gender_code || normalize_gender_code(row['gender'] || row['gender_type'] || row['gender_type_code'])
                # Always include leading pipe: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
                key = gcode.present? ? "#{gcode}|#{l}|#{f}|#{yob}" : "|#{l}|#{f}|#{yob}"
                swimmer_entry = build_swimmer_entry(key, l, f, yob.to_i, gcode)
                swimmers << swimmer_entry
                team_name = row['team']
                next if team_name.to_s.strip.empty?

                # Use swimmer entry's updated key/gender (may have been populated from DB match)
                badges << build_badge_entry(swimmer_entry['key'], team_name, yob.to_i,
                                            swimmer_entry['gender_type_code'], meeting_date)
              end
            end
            broadcast_progress('Collect swimmers from sections', sec_idx + 1, total)
          end
        else
          @logger.info('[SwimmerSolver] No LT4 swimmers dict and no LT2 sections found')
        end

        payload = {
          'season_id' => @season.id,
          'swimmers' => swimmers.uniq { |h| h['key'] }.sort_by { |h| h['key'] },
          'badges' => badges.uniq { |h| [h['swimmer_key'], h['team_key'], h['season_id']] }.sort_by { |h| h['swimmer_key'] }
        }

        phase_path = opts[:phase_path] || default_phase_path_for(source_path, 3)
        pfm = PhaseFileManager.new(phase_path)
        meta = {
          'generator' => self.class.name,
          'source_path' => source_path,
          'generated_at' => Time.now.utc.iso8601,
          'season_id' => @season.id,
          'layoutType' => lt_format,
          'phase' => 3,
          'parent_checksum' => pfm.checksum(source_path)
        }
        pfm.write!(data: payload, meta: meta)
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity

      private

      def default_phase_path_for(source_path, phase_num)
        dir = File.dirname(source_path)
        base = File.basename(source_path, File.extname(source_path))
        File.join(dir, "#{base}-phase#{phase_num}.json")
      end

      # Accepts string (e.g., "F|LAST|FIRST|YYYY|TEAM") or hash-like objects
      def extract_swimmer_parts(s)
        if s.is_a?(String)
          parts = s.split('|')
          gcode = parts[0].presence
          last = parts[1]
          first = parts[2]
          yob = parts[3]
          team = parts[4]
          return [last, first, yob, normalize_gender_code(gcode), team]
        elsif s.is_a?(Hash)
          return [s['last_name'], s['first_name'], s['year_of_birth'], normalize_gender_code(s['gender']), s['team']]
        end
        [nil, nil, nil, nil, nil]
      end

      def normalize_gender_code(code)
        up = code.to_s.upcase
        return 'M' if up.start_with?('M')
        return 'F' if up.start_with?('F')

        nil
      end

      # Extracts [last_name, first_name, year_of_birth] from a LT2 row.
      # Prefers explicit fields; falls back to parsing 'swimmer' when necessary.
      def extract_name_yob_from_row(row) # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
        last = row['last_name'] || row['cognome']
        first = row['first_name'] || row['nome']
        yob = row['year_of_birth'] || row['anno'] || row['yob']
        return [safe_str(last), safe_str(first), yob.to_i] if last.present? && first.present? && yob.to_i.positive?

        # Fallbacks: try to parse combined swimmer field like "LAST FIRST"
        combined = row['swimmer'] || row['atleta']
        if combined.present?
          parts = combined.to_s.split
          # Heuristic: LAST FIRST (2 tokens)
          if parts.size >= 2
            last ||= parts[0]
            first ||= parts[1]
          end
        end
        [safe_str(last), safe_str(first), yob.to_i]
      end

      def safe_str(s)
        return nil if s.nil?

        s.to_s.strip.presence
      end

      # Build a swimmer entry with fuzzy matches and auto-assignment
      # key: immutable reference key (LAST|FIRST|YOB)
      # last_name, first_name, year_of_birth, gender_type_code: swimmer attributes
      # Also computes individual category_type using CategoryComputer
      def build_swimmer_entry(key, last_name, first_name, year_of_birth, gender_type_code)
        complete_name = "#{last_name} #{first_name}".strip
        search_name = normalize_swimmer_name(complete_name)
        search_last = normalize_swimmer_name(last_name)
        entry = {
          'key' => key,
          'last_name' => last_name,
          'first_name' => first_name,
          'year_of_birth' => year_of_birth,
          'gender_type_code' => gender_type_code,
          'complete_name' => complete_name,
          'swimmer_id' => nil,
          'category_type_id' => nil,
          'category_type_code' => nil
        }

        # Compute category_type if we have all required data
        meeting_date = @phase1_data&.dig('data', 'header_date')
        if year_of_birth.present? && gender_type_code.present? && meeting_date.present? && @categories_cache
          category_type_id, category_type_code = Import::CategoryComputer.compute_category(
            year_of_birth: year_of_birth,
            gender_code: gender_type_code,
            meeting_date: meeting_date,
            season: @season,
            categories_cache: @categories_cache
          )
          entry['category_type_id'] = category_type_id
          entry['category_type_code'] = category_type_code

          if category_type_id
            @logger&.info("[SwimmerSolver] Swimmer '#{key}' -> category #{category_type_code} (ID: #{category_type_id})")
          else
            @logger&.warn("[SwimmerSolver] Could not resolve category for '#{key}' (YOB: #{year_of_birth}, gender: #{gender_type_code})")
          end
        end

        # Find fuzzy matches using CmdFindDbEntity with FuzzySwimmer
        matches = find_swimmer_matches(search_name, year_of_birth, search_last, gender_type_code)
        entry['fuzzy_matches'] = matches

        # Auto-assign top match if confidence >= 60% (lower threshold for more auto-matching)
        if matches.present? && auto_assignable?(matches.first, complete_name)
          top_match = matches.first
          entry['swimmer_id'] = top_match['id']
          entry['complete_name'] = top_match['complete_name']

          # Populate gender from matched swimmer if it was missing
          if entry['gender_type_code'].blank? && top_match['gender_type_code'].present?
            entry['gender_type_code'] = top_match['gender_type_code']
            @logger&.info("[SwimmerSolver] Populated gender '#{top_match['gender_type_code']}' from matched swimmer ID #{top_match['id']}")

            # Update key to include gender prefix now that we have it
            parts = key.split('|').reject(&:blank?)
            # Rebuild key: GENDER|LAST|FIRST|YOB
            entry['key'] = "#{entry['gender_type_code']}|#{parts[0]}|#{parts[1]}|#{parts[2]}"
            @logger&.debug("[SwimmerSolver] Updated key from '#{key}' to '#{entry['key']}'")

            # Recompute category now that we have complete data
            meeting_date = @phase1_data&.dig('data', 'header_date')
            if year_of_birth.present? && meeting_date.present? && @categories_cache
              category_type_id, category_type_code = Import::CategoryComputer.compute_category(
                year_of_birth: year_of_birth,
                gender_code: entry['gender_type_code'],
                meeting_date: meeting_date,
                season: @season,
                categories_cache: @categories_cache
              )
              entry['category_type_id'] = category_type_id
              entry['category_type_code'] = category_type_code
              @logger&.info("[SwimmerSolver] Recomputed category '#{category_type_code}' after gender assignment")
            end
          end

          @logger&.info("[SwimmerSolver] Auto-assigned swimmer '#{key}' -> ID #{top_match['id']} (#{(top_match['weight'] * 100).round(1)}%)")
        end

        entry
      end

      # Find potential swimmer matches using GogglesDb fuzzy finder with Jaro-Winkler distance
      # Returns array of hashes with swimmer data sorted by match weight
      # Implements fallback matching by last_name + gender + year_of_birth when no matches found
      def find_swimmer_matches(complete_name, year_of_birth, last_name = nil, gender_code = nil)
        return [] if complete_name.blank?

        # Primary search: Use CmdFindDbEntity with FuzzySwimmer strategy (full name)
        cmd = GogglesDb::CmdFindDbEntity.call(
          GogglesDb::Swimmer,
          { complete_name: complete_name.to_s.strip, year_of_birth: year_of_birth.to_i }
        )

        # Extract matches (sorted by weight descending)
        matches = cmd.matches.respond_to?(:map) ? cmd.matches : []

        # Fallback: If no matches found, try with a lower bias (0.50) and last name only
        # This handles cases where first name is abbreviated or spelled differently
        if matches.empty? && last_name.present?
          @logger&.info("[SwimmerSolver] No matches for '#{complete_name}', trying fallback with lower bias")
          fallback_cmd = GogglesDb::CmdFindDbEntity.call(
            GogglesDb::Swimmer,
            { complete_name: last_name.to_s.strip, year_of_birth: year_of_birth.to_i },
            0.70 # Lower bias for more permissive matching
          )

          fallback_matches = fallback_cmd.matches.respond_to?(:map) ? fallback_cmd.matches : []
          # Filter by gender if available to reduce false positives
          if gender_code.present?
            gender_type = GogglesDb::GenderType.find_by(code: gender_code)
            fallback_matches = fallback_matches.select { |m| m.candidate.gender_type_id == gender_type&.id } if gender_type
          end

          matches = fallback_matches.take(5) # Limit to top 5 fallback matches
          @logger&.info("[SwimmerSolver] Fallback found #{matches.size} matches")
        end

        # Convert all matches to our format with color-coded display labels
        matches.map do |match_struct|
          swimmer = match_struct.candidate
          weight = match_struct.weight.round(3)
          percentage = (weight * 100).round(1)

          # Color coding based on match percentage
          color_class = case percentage
                        when 90..100 then 'success' # Green - excellent match
                        when 70...90 then 'warning' # Yellow - acceptable/good match
                        when 50...70 then 'danger'  # Red - questionable match
                          # else: no badge pill for very poor match
                        end
          {
            'id' => swimmer.id,
            'complete_name' => swimmer.complete_name,
            'last_name' => swimmer.last_name,
            'first_name' => swimmer.first_name,
            'year_of_birth' => swimmer.year_of_birth,
            'gender_type_code' => swimmer.gender_type&.code,
            'weight' => weight,
            'percentage' => percentage,
            'color_class' => color_class,
            'display_label' => "#{swimmer.complete_name} (#{swimmer.year_of_birth}, ID: #{swimmer.id}, match: #{percentage}%)"
          }
        end
      rescue StandardError => e
        @logger&.warn("[SwimmerSolver] Error finding swimmer matches for '#{complete_name}': #{e.message}")
        []
      end

      # Determine if top match is good enough for auto-assignment
      # Auto-assigns if weight >= 0.60 (60% confidence threshold - lowered to accept more matches)
      def auto_assignable?(match, _search_name)
        return false if match.blank?

        weight = match['weight'].to_f
        weight >= 0.60
      end

      # Normalize swimmer names for matching: remove accents, unify apostrophes and extra spaces
      def normalize_swimmer_name(name)
        base = name.to_s.strip
        return '' if base.empty?

        normalized = I18n.transliterate(base)
        normalized.gsub(/[`’]/, "'").squeeze(' ')
      end

      # Build a badge entry using category data from swimmer entry when available.
      # Also attempts to match existing badge in DB if all required keys are available.
      # Returns hash with swimmer_key, team_key, season_id, category_type_id, category_type_code,
      # badge number and badge_id (if matched).
      #
      # NOTE: Category data is now computed at swimmer level, so we reuse it from there.
      def build_badge_entry(swimmer_key, team_key, year_of_birth, gender_code, meeting_date)
        # Resolve swimmer_id and team_id from phase data
        swimmer_id = find_swimmer_id_by_key(swimmer_key)
        team_id = find_team_id_by_key(team_key)

        badge = {
          'swimmer_key' => swimmer_key,
          'team_key' => team_key,
          'season_id' => @season.id,
          'swimmer_id' => swimmer_id,
          'team_id' => team_id,
          'category_type_id' => nil,
          'category_type_code' => nil,
          'number' => '?',
          'badge_id' => nil
        }

        # Reuse category from swimmer entry if already computed (Phase 3 swimmers now carry this)
        # Fallback to computing if not available
        if year_of_birth.present? && gender_code.present? && meeting_date.present? && @categories_cache
          category_type_id, category_type_code = Import::CategoryComputer.compute_category(
            year_of_birth: year_of_birth,
            gender_code: gender_code,
            meeting_date: meeting_date,
            season: @season,
            categories_cache: @categories_cache
          )
          badge['category_type_id'] = category_type_id
          badge['category_type_code'] = category_type_code
        end

        # Try to match existing badge if we have all required keys
        # Guard clause: skip matching if any key is missing
        return badge unless swimmer_id && team_id && @season.id

        existing_badge = GogglesDb::Badge.find_by(
          season_id: @season.id,
          swimmer_id: swimmer_id,
          team_id: team_id
        )

        if existing_badge
          badge['badge_id'] = existing_badge.id
          badge['category_type_id'] ||= existing_badge.category_type_id
          badge['category_type_code'] ||= existing_badge.category_type&.code
          badge['number'] = existing_badge.number.presence || badge['number']
          @logger&.info("[SwimmerSolver] Matched existing Badge ID=#{existing_badge.id} for '#{swimmer_key}' + '#{team_key}'")
        else
          @logger&.debug("[SwimmerSolver] No existing badge found for '#{swimmer_key}' + '#{team_key}' (will create new)")
        end

        badge
      rescue StandardError => e
        @logger&.error("[SwimmerSolver] Error matching badge for '#{swimmer_key}': #{e.message}")
        badge # Return badge without ID on error
      end

      # Find swimmer_id by swimmer_key from current swimmers being built
      # Note: This looks at swimmers array being built in this phase, not from saved phase3 file
      # Keys now have format: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
      def find_swimmer_id_by_key(swimmer_key)
        # First check phase3 data if available (from previous build)
        # Use include? for partial match to handle keys with/without gender prefix
        if @phase1_data # Reusing phase data loaded at start
          swimmers = Array(@phase3_data&.dig('data', 'swimmers'))
          # Exact match first
          swimmer = swimmers.find { |s| s['key'] == swimmer_key }
          # Fallback: partial match if key contains the swimmer key (handles gender prefix variations)
          swimmer ||= swimmers.find { |s| s['key'].include?(swimmer_key.sub(/^[MF]?\|?/, '|')) }
          return swimmer&.dig('swimmer_id') if swimmer
        end

        # Otherwise, try to find in DB by parsing key
        # Remove leading empty part if present (|LAST|... format)
        parts = swimmer_key.split('|').reject(&:blank?)
        return nil if parts.size < 3

        # Handle both formats: GENDER|LAST|FIRST|YOB or LAST|FIRST|YOB
        offset = parts[0].length == 1 && parts[0].match?(/[MF]/) ? 1 : 0
        last_name = parts[offset]
        first_name = parts[offset + 1]
        year_of_birth = parts[offset + 2].to_i

        # Quick lookup - exact match by name and YOB
        swimmer = GogglesDb::Swimmer.find_by(
          last_name: last_name,
          first_name: first_name,
          year_of_birth: year_of_birth
        )
        swimmer&.id
      end

      # Find team_id by team_key from phase2 data
      def find_team_id_by_key(team_key)
        return nil unless @phase2_data

        teams = Array(@phase2_data.dig('data', 'teams'))
        team = teams.find { |t| t['key'] == team_key }
        team&.dig('team_id')
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
