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
        @built_swimmer_id_by_key = {}

        if data_hash['swimmers'].is_a?(Array) || data_hash['swimmers'].is_a?(Hash)
          total = data_hash['swimmers'].size
          if data_hash['swimmers'].is_a?(Array)
            data_hash['swimmers'].each_with_index do |s, idx|
              l, f, yob, gcode, team_name = extract_swimmer_parts(s)
              broadcast_progress('Map swimmers', idx + 1, total)
              next if l.blank? || f.blank? || yob.to_i.zero?

              # Always include leading pipe: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
              key = gcode.present? ? "#{gcode}|#{l}|#{f}|#{yob}" : "|#{l}|#{f}|#{yob}"
              swimmer_entry = build_swimmer_entry(key, l, f, yob.to_i, gcode, team_name: team_name)
              swimmers << swimmer_entry
              register_built_swimmer_entry(swimmer_entry)
              next if team_name.blank?

              # Use swimmer entry's updated key/gender (may have been populated from DB match)
              add_or_replace_badge(badges, build_badge_entry(swimmer_entry['key'], team_name, yob.to_i,
                                                             swimmer_entry['gender_type_code'], meeting_date,
                                                             swimmer_id: swimmer_entry['swimmer_id']))
            end
          else # Hash dictionary: key => swimmerKey, value => details
            data_hash['swimmers'].each_with_index do |(original_key, v), idx|
              l, f, yob, gcode, team_name = extract_swimmer_parts_from_dict_entry(original_key, v)
              broadcast_progress('Map swimmers', idx + 1, total)
              next if l.blank? || f.blank? || yob.to_i.zero?

              # Always include leading pipe: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
              key = gcode.present? ? "#{gcode}|#{l}|#{f}|#{yob}" : "|#{l}|#{f}|#{yob}"
              swimmer_entry = build_swimmer_entry(key, l, f, yob.to_i, gcode, team_name: team_name)
              swimmers << swimmer_entry
              register_built_swimmer_entry(swimmer_entry)
              next if team_name.to_s.strip.empty?

              # Use swimmer entry's updated key/gender (may have been populated from DB match)
              add_or_replace_badge(badges, build_badge_entry(swimmer_entry['key'], team_name, yob.to_i,
                                                             swimmer_entry['gender_type_code'], meeting_date,
                                                             swimmer_id: swimmer_entry['swimmer_id']))
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

                  last, first, = Import::SwimmerNameSplitter.split_complete_name(swimmer_name)
                  next if last.blank? || first.blank?

                  gcode = normalize_gender_code(gtype)
                  # Always include leading pipe: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
                  key = gcode.present? ? "#{gcode}|#{last}|#{first}|#{yob}" : "|#{last}|#{first}|#{yob}"

                  swimmer_entry = build_swimmer_entry(key, last, first, yob.to_i, gcode, team_name: team_name)
                  swimmers << swimmer_entry
                  register_built_swimmer_entry(swimmer_entry)
                  next if team_name.to_s.strip.empty?

                  # Use swimmer entry's updated key/gender (may have been populated from DB match)
                  add_or_replace_badge(badges, build_badge_entry(swimmer_entry['key'], team_name, yob.to_i,
                                                                 swimmer_entry['gender_type_code'], meeting_date,
                                                                 swimmer_id: swimmer_entry['swimmer_id']))
                end
              else
                # Individual result row
                l, f, yob = extract_name_yob_from_row(row)
                next if l.blank? || f.blank? || yob.to_i.zero?

                gcode = gender_code || normalize_gender_code(row['gender'] || row['gender_type'] || row['gender_type_code'])
                # Always include leading pipe: |LAST|FIRST|YOB or GENDER|LAST|FIRST|YOB
                key = gcode.present? ? "#{gcode}|#{l}|#{f}|#{yob}" : "|#{l}|#{f}|#{yob}"
                team_name = row['team']
                swimmer_entry = build_swimmer_entry(key, l, f, yob.to_i, gcode, team_name: team_name)
                swimmers << swimmer_entry
                register_built_swimmer_entry(swimmer_entry)
                next if team_name.to_s.strip.empty?

                # Use swimmer entry's updated key/gender (may have been populated from DB match)
                add_or_replace_badge(badges, build_badge_entry(swimmer_entry['key'], team_name, yob.to_i,
                                                               swimmer_entry['gender_type_code'], meeting_date,
                                                               swimmer_id: swimmer_entry['swimmer_id']))
              end
            end
            broadcast_progress('Collect swimmers from sections', sec_idx + 1, total)
          end
        else
          @logger.info('[SwimmerSolver] No LT4 swimmers dict and no LT2 sections found')
        end

        # Deduplicate badges: when both partial-key (|LAST|FIRST|YOB) and full-key (F|LAST|FIRST|YOB)
        # badges exist for the same swimmer+team+season, keep only the full-key one to prevent
        # duplicate badge commits (same swimmer_id+team_id+season_id would fail unique constraint)
        deduplicated_badges = deduplicate_badges(badges)

        payload = {
          'season_id' => @season.id,
          'swimmers' => swimmers.uniq { |h| h['key'] }.sort_by { |h| h['key'] },
          'badges' => deduplicated_badges.sort_by { |h| h['swimmer_key'] }
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
      def extract_swimmer_parts(s) # rubocop:disable Naming/MethodParameterName
        if s.is_a?(String)
          gcode, last, first, yob, team = parse_swimmer_identity_key(s)
          last, first, = Import::SwimmerNameSplitter.resolve_parts(
            last_name: last,
            first_name: first,
            complete_name: [last, first].compact.join(' ')
          )
          return [last, first, yob, normalize_gender_code(gcode), team]
        elsif s.is_a?(Hash)
          last, first, = Import::SwimmerNameSplitter.resolve_parts(
            last_name: s['last_name'],
            first_name: s['first_name'],
            complete_name: s['complete_name']
          )
          return [last, first, s['year_of_birth'], normalize_gender_code(s['gender']), s['team']]
        end
        [nil, nil, nil, nil, nil]
      end

      # Extract swimmer identity from LT4 dictionary entries where key can carry
      # canonical data like: GENDER|LAST|FIRST|YOB|TEAM.
      # Value hashes may only include complete_name/year/gender_type in some sources.
      def extract_swimmer_parts_from_dict_entry(original_key, details)
        details = extract_swimmer_details(details)

        key_gcode, key_last, key_first, key_yob, key_team = parse_swimmer_identity_key(original_key)
        resolved_last, resolved_first, = resolve_swimmer_name_parts(details, key_last, key_first)

        [
          resolved_last,
          resolved_first,
          details['year_of_birth'].presence || key_yob,
          details['gender_type_code'] || key_gcode,
          details['team_name'] || key_team
        ]
      end

      def extract_swimmer_details(raw_details)
        details = raw_details || {}
        {
          'last_name' => safe_str(fetch_first_present(details, 'last_name', 'lastName')),
          'first_name' => safe_str(fetch_first_present(details, 'first_name', 'firstName')),
          'year_of_birth' => fetch_first_present(details, 'year_of_birth', 'year'),
          'gender_type_code' => normalize_gender_code(fetch_first_present(details, 'gender', 'gender_type', 'gender_type_code')),
          'team_name' => safe_str(fetch_first_present(details, 'team', 'team_name')),
          'complete_name' => fetch_first_present(details, 'complete_name', 'completeName')
        }
      end

      def resolve_swimmer_name_parts(details, key_last, key_first)
        resolved_last_name = details['last_name'] || key_last
        resolved_first_name = details['first_name'] || key_first
        full_name = details['complete_name'] || [resolved_last_name, resolved_first_name].compact.join(' ')

        Import::SwimmerNameSplitter.resolve_parts(
          last_name: resolved_last_name,
          first_name: resolved_first_name,
          complete_name: full_name
        )
      end

      # Parse key formats:
      # - GENDER|LAST|FIRST|YOB|TEAM
      # - |LAST|FIRST|YOB|TEAM
      # - LAST|FIRST|YOB|TEAM
      def parse_swimmer_identity_key(swimmer_key)
        parts = swimmer_key.to_s.split('|')
        return [nil, nil, nil, nil, nil] if parts.empty?

        if parts[0].to_s.match?(/\A[MF]\z/i)
          build_swimmer_key_parts(parts, start_index: 1, gender_code: normalize_gender_code(parts[0]))
        elsif parts[0].blank?
          build_swimmer_key_parts(parts, start_index: 1)
        else
          build_swimmer_key_parts(parts, start_index: 0)
        end
      end

      def build_swimmer_key_parts(parts, start_index:, gender_code: nil)
        [
          gender_code,
          safe_str(parts[start_index]),
          safe_str(parts[start_index + 1]),
          safe_str(parts[start_index + 2]),
          safe_str(parts[(start_index + 3)..]&.join('|'))
        ]
      end

      def fetch_first_present(hash, *keys)
        keys.each do |key|
          value = hash[key]
          return value if value.present?
        end
        nil
      end

      def normalize_gender_code(code)
        up = code.to_s.upcase
        return 'M' if up.start_with?('M')
        return 'F' if up.start_with?('F')

        nil
      end

      # Extracts [last_name, first_name, year_of_birth] from a LT2 row.
      # Prefers explicit fields; falls back to parsing 'swimmer' when necessary.
      def extract_name_yob_from_row(row) # rubocop:disable Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
        last = row['last_name'] || row['cognome']
        first = row['first_name'] || row['nome']
        yob = row['year_of_birth'] || row['anno'] || row['yob']
        return [safe_str(last), safe_str(first), yob.to_i] if last.present? && first.present? && yob.to_i.positive?

        # Fallbacks: try to parse combined swimmer field like "LAST FIRST"
        combined = row['swimmer'] || row['atleta']
        if combined.present?
          split_last, split_first, = Import::SwimmerNameSplitter.split_complete_name(combined)
          last ||= split_last
          first ||= split_first
        end
        [safe_str(last), safe_str(first), yob.to_i]
      end

      def safe_str(s) # rubocop:disable Naming/MethodParameterName
        return nil if s.nil?

        s.to_s.strip.presence
      end

      # Build a swimmer entry with fuzzy matches and auto-assignment
      # key: immutable reference key (LAST|FIRST|YOB)
      # last_name, first_name, year_of_birth, gender_type_code: swimmer attributes
      # Also computes individual category_type using CategoryComputer
      def build_swimmer_entry(key, last_name, first_name, year_of_birth, gender_type_code, team_name: nil) # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
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
        entry['gender_guessed'] = false
        entry['similar_on_team'] = false

        # Store top match percentage for filtering (0 if no matches)
        entry['match_percentage'] = matches.first&.dig('percentage') || 0.0

        # Team cross-reference: check if a similar swimmer already exists on the same team
        team_id_for_xref = team_name.present? ? find_team_id_by_key(team_name) : nil
        if team_id_for_xref.to_i.positive?
          cross_ref = find_teammates_with_similar_name(complete_name, year_of_birth, gender_type_code, team_id_for_xref)
          if cross_ref['has_similar']
            entry['similar_on_team'] = true
            entry['team_cross_ref'] = cross_ref
            # Merge cross-ref candidates into fuzzy_matches, sorted by weight.
            # Cross-ref candidates keep their "(Same team)" label but don't override
            # higher-scoring fuzzy matches for auto-assignment.
            current_matches = entry['fuzzy_matches'] || []
            cross_ref_ids = cross_ref['candidates'].to_set { |c| c['id'] }
            current_matches.each do |m|
              next unless cross_ref_ids.include?(m['id'])

              # Update existing match with cross-ref label and flag
              xref_candidate = cross_ref['candidates'].find { |c| c['id'] == m['id'] }
              m['display_label'] = xref_candidate['display_label'] if xref_candidate
              m['from_team_cross_ref'] = true
            end
            # Add truly new candidates (not already in fuzzy_matches)
            existing_ids = current_matches.filter_map { |m| m['id'] }.to_set
            new_candidates = cross_ref['candidates'].reject { |c| existing_ids.include?(c['id']) }
            entry['fuzzy_matches'] = (current_matches + new_candidates).sort_by { |m| -(m['weight'] || 0) }
          end
        end

        # Re-weight matches using team correlation: boost candidates whose badge team
        # is a 100% Phase 2 match, demote candidates with badges but no Phase 2 team match
        current_matches = entry['fuzzy_matches'] || []
        if current_matches.size > 1 && team_name.present?
          target_team_id = find_team_id_by_key(team_name)
          current_matches.each do |m|
            badges = m['badges'] || []
            next if badges.empty?

            has_matching_team = badges.any? { |b| b['phase2_match'] && b['team_id'] == target_team_id }
            has_any_p2_match = badges.any? { |b| b['phase2_match'] }
            if has_matching_team
              m['weight'] = [(m['weight'] + 0.05).round(3), 1.0].min
              m['team_match'] = true
            elsif !has_any_p2_match
              m['weight'] = [(m['weight'] - 0.05).round(3), 0.0].max
            end
            m['percentage'] = (m['weight'] * 100).round(1)
          end
          entry['fuzzy_matches'] = current_matches.sort_by { |m| -(m['weight'] || 0) }
          entry['match_percentage'] = entry['fuzzy_matches'].first&.dig('percentage') || 0.0
        end

        # Handle gender-unknown swimmers: only accept very high confidence matches (>=90%)
        # to infer gender safely. Lower matches could be wrong-gender swimmers with similar names.
        if gender_type_code.blank?
          top_match = matches.first
          if top_match && top_match['percentage'] >= 90.0 && top_match['gender_type_code'].present?
            # High confidence match - safe to infer gender
            entry['gender_type_code'] = top_match['gender_type_code']
            entry['gender_guessed'] = true
            entry['swimmer_id'] = top_match['id']
            entry['complete_name'] = top_match['complete_name']
            entry['last_name'] = top_match['last_name']
            entry['first_name'] = top_match['first_name']

            # Update key to include inferred gender prefix
            parts = key.split('|').compact_blank
            entry['key'] = "#{entry['gender_type_code']}|#{parts[0]}|#{parts[1]}|#{parts[2]}"

            # Recompute category now that we have gender
            meeting_date = @phase1_data&.dig('data', 'header_date')
            if year_of_birth.present? && meeting_date.present? && @categories_cache
              cat_id, cat_code = Import::CategoryComputer.compute_category(
                year_of_birth: year_of_birth,
                gender_code: entry['gender_type_code'],
                meeting_date: meeting_date,
                season: @season,
                categories_cache: @categories_cache
              )
              entry['category_type_id'] = cat_id
              entry['category_type_code'] = cat_code
            end

            # Force match_percentage below 90 so it appears in "needs review" filter
            entry['match_percentage'] = 89.9
            @logger&.info("[SwimmerSolver] Gender guessed for '#{key}' -> #{entry['gender_type_code']} " \
                          "from match ID #{top_match['id']} (#{top_match['percentage']}%)")
          else
            # No high-confidence match - leave unmatched for manual review
            @logger&.info("[SwimmerSolver] No high-confidence match for '#{key}' (gender unknown) - requires manual review")
          end
          return entry
        end

        # Auto-assign top match if confidence >= 60% (lower threshold for more auto-matching)
        # Use refreshed fuzzy_matches (may include cross-ref candidates)
        current_matches = entry['fuzzy_matches'] || []
        if current_matches.present? && auto_assignable?(current_matches.first, complete_name)
          top_match = current_matches.first
          entry['swimmer_id'] = top_match['id']
          entry['complete_name'] = top_match['complete_name']
          entry['last_name'] = top_match['last_name']
          entry['first_name'] = top_match['first_name']

          @logger&.info("[SwimmerSolver] Auto-assigned swimmer '#{key}' -> ID #{top_match['id']} (#{(top_match['weight'] * 100).round(1)}%)")
        end

        # Post-assignment filter: remove cross-ref candidates that match the assigned swimmer_id.
        # If no alternative candidates remain, clear the similar_on_team warning.
        if entry['swimmer_id'].present? && entry['similar_on_team'] && entry['team_cross_ref']
          alt_candidates = entry['team_cross_ref']['candidates'].reject { |c| c['id'] == entry['swimmer_id'] }
          if alt_candidates.empty?
            entry['similar_on_team'] = false
            entry.delete('team_cross_ref')
            @logger&.info("[SwimmerSolver] Cleared similar_on_team for '#{key}' (only self-match in cross-ref)")
          else
            entry['team_cross_ref']['candidates'] = alt_candidates
          end
        end

        entry
      end

      # Find potential swimmer matches using GogglesDb fuzzy finder with Jaro-Winkler distance
      # Returns array of hashes with swimmer data sorted by match weight
      # Implements fallback matching by last_name + gender + year_of_birth when no matches found
      def find_swimmer_matches(complete_name, year_of_birth, _last_name = nil, gender_code = nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        return [] if complete_name.blank?

        # Primary search: Use CmdFindDbEntity with FuzzySwimmer strategy (full name)
        cmd = GogglesDb::CmdFindDbEntity.call(
          GogglesDb::Swimmer,
          { complete_name: complete_name.to_s.strip, year_of_birth: year_of_birth.to_i }
        )

        # Extract matches (sorted by weight descending)
        matches = cmd.matches.respond_to?(:map) ? cmd.matches : []

        # Fallback: If no matches found, try with a more permissive bias (0.80) which should be
        # enough for a last name only match.
        if matches.empty?
          @logger&.info("[SwimmerSolver] No matches for '#{complete_name}', trying fallback with lower bias")
          fallback_cmd = GogglesDb::CmdFindDbEntity.call(
            GogglesDb::Swimmer,
            { complete_name: complete_name.to_s.strip, year_of_birth: year_of_birth.to_i },
            0.80 # More permissive bias for fallback matching (default is 0.89)
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

        # TODO: Fallback #2: we could try to do a 3rd run, using just the last_name parameter, but this
        # implies ranking any possible resulting match very low (red in color)

        # Batch-load badges for all candidate swimmer IDs to avoid N+1 queries
        candidate_ids = matches.filter_map { |m| m.candidate.id }.uniq
        badges_by_swimmer = if candidate_ids.any?
                              GogglesDb::Badge.where(swimmer_id: candidate_ids, season_id: recent_season_ids)
                                              .includes(:team)
                                              .group_by(&:swimmer_id)
                            else
                              {}
                            end
        p2_team_lookup = phase2_team_lookup_by_id

        # Convert all matches to our format with color-coded display labels
        matches.map do |match_struct| # rubocop:disable Metrics/BlockLength
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

          # Enrich with badge/team data from recent seasons
          swimmer_badges = badges_by_swimmer[swimmer.id] || []
          badge_entries = swimmer_badges.map do |badge|
            team = badge.team
            p2_info = p2_team_lookup[badge.team_id]
            {
              'team_id' => badge.team_id,
              'team_name' => team&.editable_name || team&.name,
              'season_id' => badge.season_id,
              'badge_id' => badge.id,
              'phase2_match' => p2_info.present?,
              'phase2_match_percentage' => p2_info&.dig('match_percentage')
            }
          end

          # Build display label with team info
          team_suffix = if badge_entries.any?
                          team_names = badge_entries.filter_map { |b| b['team_name'] }.uniq.first(2)
                          p2_match = badge_entries.any? { |b| b['phase2_match'] }
                          marker = p2_match ? ' *' : ''
                          " [#{team_names.join(', ')}#{marker}]"
                        else
                          ''
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
            'badges' => badge_entries,
            'display_label' => "#{swimmer.complete_name} (#{swimmer.year_of_birth}, ID: #{swimmer.id}, match: #{percentage}%)#{team_suffix}"
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
        normalized.gsub(/[`’]/, "'").squeeze(' ').upcase
      end

      # Find swimmers on the same team with similar names using Jaro-Winkler distance.
      # This catches cases like "NUGNES GILEMMA" vs "NUNES GILEMMA" on the same team.
      #
      # Returns a hash: { 'has_similar' => bool, 'candidates' => [...] }
      # Each candidate has the same format as fuzzy_matches entries plus 'from_team_cross_ref' flag.
      #
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength
      def find_teammates_with_similar_name(complete_name, year_of_birth, gender_type_code, team_id)
        result = { 'has_similar' => false, 'candidates' => [] }
        return result if complete_name.blank? || team_id.to_i.zero?

        # Query all badges for this team in the current + previous season (limit 2)
        # to catch swimmers registered last season but not yet in the current one.
        season_ids = recent_season_ids(limit: 2)
        teammate_badges = GogglesDb::Badge.where(team_id: team_id.to_i, season_id: season_ids)
                                          .includes(:swimmer)
        return result if teammate_badges.empty?

        metric = GogglesDb::DbFinders::BaseStrategy::METRIC
        normalized_search = normalize_swimmer_name(complete_name).downcase

        candidates = []
        teammate_badges.each do |badge|
          swimmer = badge.swimmer
          next if swimmer.nil?
          # Filter by YOB and gender if available
          next if year_of_birth.to_i.positive? && swimmer.year_of_birth != year_of_birth.to_i
          next if gender_type_code.present? && swimmer.gender_type&.code != gender_type_code

          normalized_candidate = normalize_swimmer_name(swimmer.complete_name).downcase
          similarity = metric.getDistance(normalized_search, normalized_candidate)

          # Accept candidates with similarity >= 0.85 (catches typos/spacing differences
          # while filtering out false positives with unrelated names)
          # Skip perfect matches (already handled by standard fuzzy matching)
          next if similarity < 0.85 || similarity >= 1.0

          percentage = (similarity * 100).round(1)
          color_class = case percentage
                        when 90..100 then 'success'
                        when 70...90 then 'warning'
                        when 50...70 then 'danger'
                        end
          candidates << {
            'id' => swimmer.id,
            'complete_name' => swimmer.complete_name,
            'last_name' => swimmer.last_name,
            'first_name' => swimmer.first_name,
            'year_of_birth' => swimmer.year_of_birth,
            'gender_type_code' => swimmer.gender_type&.code,
            'weight' => similarity.round(3),
            'percentage' => percentage,
            'color_class' => color_class,
            'display_label' => "(Same team) #{swimmer.complete_name} (#{swimmer.year_of_birth}, ID: #{swimmer.id}, match: #{percentage}%)",
            'from_team_cross_ref' => true,
            'matching_team_id' => team_id.to_i
          }
        end

        # Deduplicate by swimmer ID (a swimmer with badges in multiple seasons
        # would otherwise appear multiple times). Keep the highest-weight entry.
        candidates = candidates.sort_by { |c| -c['weight'] }
                               .uniq { |c| c['id'] }
        if candidates.any?
          result['has_similar'] = true
          result['candidates'] = candidates
          @logger&.info("[SwimmerSolver] Team cross-ref found #{candidates.size} similar teammate(s) for '#{complete_name}': " \
                        "#{candidates.map { |c| "#{c['complete_name']} (#{c['percentage']}%)" }.join(', ')}")
        end

        result
      rescue StandardError => e
        @logger&.warn("[SwimmerSolver] Error in team cross-ref for '#{complete_name}': #{e.message}")
        result
      end
      # rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/MethodLength

      # Return an array of season IDs for the current season and the N-1 preceding seasons
      # of the same season_type (e.g., FIN Master). Used to broaden badge searches.
      def recent_season_ids(limit: 2)
        @recent_season_ids_cache ||= {}
        @recent_season_ids_cache[limit] ||= GogglesDb::Season
                                            .where(season_type_id: @season.season_type_id)
                                            .where(seasons: { id: ..@season.id })
                                            .order('seasons.id DESC')
                                            .limit(limit)
                                            .pluck(:id)
      end

      # Build a badge entry using category data from swimmer entry when available.
      # Also attempts to match existing badge in DB if all required keys are available.
      # Returns hash with swimmer_key, team_key, season_id, category_type_id, category_type_code,
      # badge number and badge_id (if matched).
      #
      # NOTE: Category data is now computed at swimmer level, so we reuse it from there.
      def build_badge_entry(swimmer_key, team_key, year_of_birth, gender_code, meeting_date, swimmer_id: nil) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        # Resolve swimmer_id and team_id from phase data
        swimmer_id = swimmer_id.to_i.positive? ? swimmer_id.to_i : find_swimmer_id_by_key(swimmer_key)
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
        return nil if swimmer_key.blank?

        return @built_swimmer_id_by_key[swimmer_key] if @built_swimmer_id_by_key&.key?(swimmer_key)

        partial_key = normalize_swimmer_key_for_lookup(swimmer_key)
        return nil if partial_key.blank?

        @built_swimmer_id_by_key&.[](partial_key)
      end

      def register_built_swimmer_entry(swimmer_entry)
        return unless swimmer_entry.is_a?(Hash)

        swimmer_key = swimmer_entry['key']
        swimmer_id = swimmer_entry['swimmer_id']
        return if swimmer_key.blank?

        @built_swimmer_id_by_key ||= {}
        @built_swimmer_id_by_key[swimmer_key] = swimmer_id if swimmer_id.to_i.positive?

        partial_key = normalize_swimmer_key_for_lookup(swimmer_key)
        @built_swimmer_id_by_key[partial_key] = swimmer_id if partial_key.present? && swimmer_id.to_i.positive?
      end

      def normalize_swimmer_key_for_lookup(swimmer_key)
        return nil if swimmer_key.blank?

        parts = swimmer_key.to_s.split('|').compact_blank
        return nil if parts.size < 3

        offset = parts[0].length == 1 && parts[0].match?(/[MF]/) ? 1 : 0
        last_name = parts[offset]
        first_name = parts[offset + 1]
        year_of_birth = parts[offset + 2]
        return nil if [last_name, first_name, year_of_birth].any?(&:blank?)

        "|#{last_name}|#{first_name}|#{year_of_birth}"
      end

      # Find team_id by team_key from phase2 data
      def find_team_id_by_key(team_key)
        return nil unless @phase2_data

        teams = Array(@phase2_data.dig('data', 'teams'))
        team = teams.find { |t| t['key'] == team_key }
        team&.dig('team_id')
      end

      # Build a reverse lookup: team_id => { key, match_percentage } from Phase 2 data.
      # Used to cross-reference badge teams with Phase 2 matched teams.
      def phase2_team_lookup_by_id
        @phase2_team_lookup_by_id ||= if @phase2_data
                                        teams = Array(@phase2_data.dig('data', 'teams'))
                                        teams.each_with_object({}) do |t, hash|
                                          tid = t['team_id'].to_i
                                          next unless tid.positive?

                                          hash[tid] = {
                                            'key' => t['key'],
                                            'match_percentage' => t['match_percentage'] || 0.0
                                          }
                                        end
                                      else
                                        {}
                                      end
      end

      # Add a badge to the array, replacing any existing partial-key badge for the same swimmer+team+season.
      # This ensures that when a full-key badge (F|LAST|FIRST|YOB) is added, any existing partial-key
      # badge (|LAST|FIRST|YOB) for the same swimmer is removed to prevent duplicate commits.
      def add_or_replace_badge(badges, new_badge) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        new_key = new_badge['swimmer_key']
        new_parts = new_key.to_s.split('|').compact_blank

        # Extract normalized identity (last|first|yob without gender)
        new_offset = new_parts[0]&.length == 1 && new_parts[0]&.match?(/[MF]/) ? 1 : 0
        new_last = new_parts[new_offset]&.upcase
        new_first = new_parts[new_offset + 1]&.upcase
        new_yob = new_parts[new_offset + 2]
        new_team = new_badge['team_key']
        new_season = new_badge['season_id']

        # Check if this is a full-key badge (has gender prefix)
        has_gender_prefix = new_key.to_s.match?(/^[MF]\|/)

        if has_gender_prefix
          # Remove any existing partial-key badge for the same swimmer+team+season
          badges.reject! do |existing|
            existing_key = existing['swimmer_key']
            existing_parts = existing_key.to_s.split('|').compact_blank
            existing_offset = existing_parts[0]&.length == 1 && existing_parts[0]&.match?(/[MF]/) ? 1 : 0
            existing_last = existing_parts[existing_offset]&.upcase
            existing_first = existing_parts[existing_offset + 1]&.upcase
            existing_yob = existing_parts[existing_offset + 2]

            # Match by identity + team + season, but only remove partial-key badges
            !existing_key.to_s.match?(/^[MF]\|/) &&
              existing_last == new_last &&
              existing_first == new_first &&
              existing_yob == new_yob &&
              existing['team_key'] == new_team &&
              existing['season_id'] == new_season
          end
        end

        # Add the new badge (unless exact duplicate already exists)
        return if badges.any? { |b| b['swimmer_key'] == new_key && b['team_key'] == new_team && b['season_id'] == new_season }

        badges << new_badge
      end

      # Deduplicate badges by normalized swimmer identity (last_name+first_name+yob) + team_key + season
      # When both partial-key (|LAST|FIRST|YOB) and full-key (F|LAST|FIRST|YOB) badges exist,
      # keep only the most complete one (with gender prefix and category data)
      def deduplicate_badges(badges) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        # Group by normalized identity: extract last|first|yob from swimmer_key
        grouped = badges.group_by do |badge|
          key = badge['swimmer_key']
          parts = key.to_s.split('|').compact_blank
          # Handle both formats: GENDER|LAST|FIRST|YOB or LAST|FIRST|YOB
          offset = parts[0]&.length == 1 && parts[0]&.match?(/[MF]/) ? 1 : 0
          last = parts[offset]
          first = parts[offset + 1]
          yob = parts[offset + 2]
          # Create normalized identity key (case-insensitive)
          "#{last&.upcase}|#{first&.upcase}|#{yob}|#{badge['team_key']}|#{badge['season_id']}"
        end

        # For each group, select the best badge (prefer full key with gender and category)
        grouped.values.map do |group|
          if group.size == 1
            group.first
          else
            # Sort to prefer: 1) has category_type_id, 2) has gender prefix in key, 3) has swimmer_id
            group.max_by do |b|
              score = 0
              score += 4 if b['swimmer_id'].present? # If the swimmer is already in the DB, we can derive the rest
              score += 2 if b['category_type_id'].present?
              score += 1 if b['swimmer_key'].to_s.match?(/^[MF]\|/) # Full keys happen often for new swimmers with all data
              score
            end
          end
        end
      end

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
