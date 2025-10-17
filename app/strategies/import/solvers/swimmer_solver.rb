# frozen_string_literal: true

module Import
  module Solvers
    # SwimmerSolver: builds Phase 3 payload (swimmers and badges)
    #
    # Inputs:
    # - LT4: prefer root 'swimmers' dictionary when present (strings or objects)
    # - LT2: fallback (TODO) scan of sections when LT4 dict missing
    #
    # Output (phase3 file):
    # {
    #   "_meta": { ... },
    #   "data": {
    #     "season_id": <int>,
    #     "swimmers": [ { "key": "LAST|FIRST|YOB", "last_name": "LAST", "first_name": "FIRST", "year_of_birth": 1970, "gender_type_code": "F" } ],
    #     "badges":   [ { "swimmer_key": "...", "team_key": "Team Name", "season_id": 242 } ]
    #   }
    # }
    #
    class SwimmerSolver
      def initialize(season:, logger: Rails.logger)
        @season = season
        @logger = logger
      end

      # Build and persist phase3 file
      # opts:
      # - :source_path (String, required)
      # - :lt_format (Integer, 2 or 4)
      # - :phase_path (String, optional custom output path)
      #
      # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
      def build!(opts = {})
        source_path = opts.fetch(:source_path)
        lt_format = opts.fetch(:lt_format, 2).to_i
        data_hash = JSON.parse(File.read(source_path))

        swimmers = []
        badges = []

        if lt_format == 4 && (data_hash['swimmers'].is_a?(Array) || data_hash['swimmers'].is_a?(Hash))
          if data_hash['swimmers'].is_a?(Array)
            data_hash['swimmers'].each do |s|
              l, f, yob, gcode, team_name = extract_swimmer_parts(s)
              next if l.blank? || f.blank? || yob.to_i.zero?

              key = [l, f, yob].join('|')
              swimmers << build_swimmer_entry(key, l, f, yob.to_i, gcode)
              next if team_name.blank?

              badges << { 'swimmer_key' => key, 'team_key' => team_name, 'season_id' => @season.id }
            end
          else # Hash dictionary: key => swimmerKey, value => details
            data_hash['swimmers'].each do |_sw_key, v|
              l = v['last_name'] || v['lastName']
              f = v['first_name'] || v['firstName']
              yob = v['year_of_birth'] || v['year']
              gcode = normalize_gender_code(v['gender'] || v['gender_type_code'])
              team_name = v['team']
              next if l.blank? || f.blank? || yob.to_i.zero?

              key = [l, f, yob].join('|')
              swimmers << build_swimmer_entry(key, l, f, yob.to_i, gcode)
              next if team_name.to_s.strip.empty?

              badges << { 'swimmer_key' => key, 'team_key' => team_name, 'season_id' => @season.id }
            end
          end
        elsif data_hash['sections'].is_a?(Array)
          # LT2 fallback: scan sections/rows for swimmers and teams (infer badges)
          data_hash['sections'].each do |sec|
            rows = sec['rows'] || []
            gender_code = normalize_gender_code(sec['fin_sesso'])
            rows.each do |row|
              next if row['relay'] # skip relays here

              l, f, yob = extract_name_yob_from_row(row)
              next if l.blank? || f.blank? || yob.to_i.zero?

              key = [l, f, yob].join('|')
              gcode = gender_code || normalize_gender_code(row['gender'] || row['gender_type'] || row['gender_type_code'])
              swimmers << build_swimmer_entry(key, l, f, yob.to_i, gcode)
              team_name = row['team']
              next if team_name.to_s.strip.empty?

              badges << {
                'swimmer_key' => key,
                'team_key' => team_name,
                'season_id' => @season.id
              }
            end
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
      def build_swimmer_entry(key, last_name, first_name, year_of_birth, gender_type_code)
        complete_name = "#{last_name} #{first_name}".strip
        entry = {
          'key' => key,
          'last_name' => last_name,
          'first_name' => first_name,
          'year_of_birth' => year_of_birth,
          'gender_type_code' => gender_type_code,
          'complete_name' => complete_name,
          'swimmer_id' => nil
        }

        # Find fuzzy matches using CmdFindDbEntity with FuzzySwimmer
        matches = find_swimmer_matches(complete_name, year_of_birth)
        entry['fuzzy_matches'] = matches

        # Auto-assign top match if confidence >= 90%
        if matches.present? && auto_assignable?(matches.first, complete_name)
          top_match = matches.first
          entry['swimmer_id'] = top_match['id']
          entry['complete_name'] = top_match['complete_name']
          @logger&.info("[SwimmerSolver] Auto-assigned swimmer '#{key}' -> ID #{top_match['id']}")
        end

        entry
      end

      # Find potential swimmer matches using GogglesDb fuzzy finder with Jaro-Winkler distance
      # Returns array of hashes with swimmer data sorted by match weight
      def find_swimmer_matches(complete_name, year_of_birth)
        return [] if complete_name.blank?

        # Use CmdFindDbEntity with FuzzySwimmer strategy
        cmd = GogglesDb::CmdFindDbEntity.call(
          GogglesDb::Swimmer,
          { complete_name: complete_name.to_s.strip, year_of_birth: year_of_birth.to_i }
        )

        # Extract matches (sorted by weight descending) and convert to our format
        matches = cmd.matches.respond_to?(:map) ? cmd.matches : []
        matches.map do |match_struct|
          swimmer = match_struct.candidate
          {
            'id' => swimmer.id,
            'complete_name' => swimmer.complete_name,
            'last_name' => swimmer.last_name,
            'first_name' => swimmer.first_name,
            'year_of_birth' => swimmer.year_of_birth,
            'gender_type_code' => swimmer.gender_type&.code,
            'weight' => match_struct.weight.round(3),
            'display_label' => "#{swimmer.complete_name} (#{swimmer.year_of_birth}, ID: #{swimmer.id}, match: #{(match_struct.weight * 100).round(1)}%)"
          }
        end
      rescue StandardError => e
        @logger&.warn("[SwimmerSolver] Error finding swimmer matches for '#{complete_name}': #{e.message}")
        []
      end

      # Determine if top match is good enough for auto-assignment
      # Auto-assigns if weight >= 0.90 (90% confidence threshold)
      def auto_assignable?(match, _search_name)
        return false unless match.present?

        weight = match['weight'].to_f
        weight >= 0.90
      end
    end
  end
end
