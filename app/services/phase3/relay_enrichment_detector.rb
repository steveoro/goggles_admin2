# frozen_string_literal: true

require 'json'

module Phase3
  # RelayEnrichmentDetector scans the raw layout-4 (Microplus) JSON payload and
  # combines it with the Phase 3 swimmers snapshot to identify relay legs that
  # still miss core attributes (year of birth, gender) or remain unmatched to a
  # swimmer_id. The resulting summary drives the inline enrichment panel.
  class RelayEnrichmentDetector
    MAX_LEGS = 8

    def initialize(source_path:, phase3_swimmers: [], season: nil, meeting_date: nil)
      @source_path = source_path
      @phase3_swimmers = Array(phase3_swimmers)
      @season = season
      @meeting_date = meeting_date
      @categories_cache = season ? PdfResults::CategoriesCache.new(season) : nil
      index_phase3_swimmers
    end

    def detect
      return [] unless File.exist?(@source_path)

      raw = JSON.parse(File.read(@source_path))
      sections = Array(raw['sections'])
      summary = []

      sections.each do |section|
        rows = Array(section['rows'])
        rows.each do |row|
          next unless relay_row?(row)

          swimmers_info = gather_swimmers(section, row)
          next if swimmers_info.empty?

          summary << build_relay_summary(section, row, swimmers_info)
        end
      end

      summary
    rescue JSON::ParserError => e
      Rails.logger.warn("[Phase3::RelayEnrichmentDetector] JSON parse error: #{e.message}")
      []
    end

    private

    def index_phase3_swimmers
      @phase3_by_key = {}
      @phase3_by_key_normalized = {}
      @phase3_by_name = Hash.new { |h, k| h[k] = [] }

      @phase3_swimmers.each do |swimmer|
        key = swimmer['key']
        if key
          @phase3_by_key[key] = swimmer
          # Also index by normalized (lowercase) key for case-insensitive matching
          normalized_key = key.downcase
          @phase3_by_key_normalized[normalized_key] = swimmer
        end

        name_key = name_key_for(swimmer['last_name'], swimmer['first_name'])
        @phase3_by_name[name_key] << swimmer if name_key
      end
    end

    def relay_row?(row)
      value = row['relay']
      value.is_a?(TrueClass) || value.to_s.casecmp('true').zero?
    end

    def gather_swimmers(section, row)
      swimmers = []

      1.upto(MAX_LEGS) do |idx|
        leg = build_leg(section, row, idx)
        next unless leg

        phase3_swimmer = leg['phase3_swimmer']
        phase3_key = leg['phase3_key']

        # If Phase 3 already has a swimmer_id for this leg, it is considered matched
        # and no longer needs enrichment. Check both the swimmer object and key lookup.
        if phase3_swimmer
          swimmer_id = phase3_swimmer['swimmer_id'].to_i
          next if swimmer_id.positive?
        end

        # Double-check by looking up the key in the indexed Phase 3 data (case-insensitive)
        if phase3_key
          indexed_swimmer = @phase3_by_key[phase3_key] || @phase3_by_key_normalized[phase3_key.downcase]
          if indexed_swimmer
            indexed_id = indexed_swimmer['swimmer_id'].to_i
            next if indexed_id.positive?
          end
        end

        issues = detect_issues_for(leg)
        next if issues.values.none?

        swimmers << leg.merge('issues' => issues)
      end

      swimmers
    end

    def build_leg(section, row, idx)
      name = row["swimmer#{idx}"]
      return nil if name.to_s.strip.empty?

      lap_reference = lap_reference_for(row, idx)
      parsed = parse_swimmer_reference(name, lap_reference)
      return nil if parsed.nil?

      phase3_match = phase3_match_for(parsed)
      matched_key = phase3_match&.fetch('key', nil)

      raw_year = row["year_of_birth#{idx}"]
      raw_gender = row["gender_type#{idx}"]

      effective_year = raw_year.presence || phase3_match&.fetch('year_of_birth', nil)
      effective_gender = normalize_gender(raw_gender.presence || phase3_match&.fetch('gender_type_code', nil))

      # Compute individual category if we have all required data
      category_type_id = nil
      category_type_code = nil
      if effective_year.present? && effective_gender.present? && @meeting_date.present? && @season && @categories_cache
        category_type_id, category_type_code = Import::CategoryComputer.compute_category(
          year_of_birth: effective_year,
          gender_code: effective_gender,
          meeting_date: @meeting_date,
          season: @season,
          categories_cache: @categories_cache
        )
      end

      {
        'leg_order' => idx,
        'relay_title' => section['title'],
        'team' => row['team'],
        'name' => parsed[:display_name],
        'phase3_key' => matched_key,
        'raw_year_of_birth' => raw_year,
        'raw_gender' => raw_gender,
        'effective_year_of_birth' => effective_year,
        'effective_gender' => effective_gender,
        'category_type_id' => category_type_id,
        'category_type_code' => category_type_code,
        'phase3_swimmer' => phase3_match,
        'lap_reference' => lap_reference
      }
    end

    def detect_issues_for(leg)
      phase3_swimmer = leg['phase3_swimmer']
      missing_year = leg['effective_year_of_birth'].to_i.zero?
      missing_gender = leg['effective_gender'].blank?
      missing_swimmer_id = phase3_swimmer.present? && phase3_swimmer['swimmer_id'].to_i.zero?

      # Category is missing if we have year+gender but no category_type_id
      missing_category = !missing_year && !missing_gender && leg['category_type_id'].blank?

      {
        'missing_year_of_birth' => missing_year,
        'missing_gender' => missing_gender,
        'missing_swimmer_id' => missing_swimmer_id,
        'missing_category' => missing_category
      }
    end

    def build_relay_summary(section, row, swimmers)
      {
        'relay_label' => relay_label_for(section, row),
        'team' => row['team'],
        'category' => section['fin_sigla_categoria'],
        'event_title' => section['title'],
        'swimmers' => swimmers,
        'missing_counts' => count_issues(swimmers)
      }
    end

    def relay_label_for(section, row)
      [row['team'], section['title']].compact.join(' • ')
    end

    def count_issues(swimmers)
      swimmers.each_with_object(Hash.new(0)) do |leg, acc|
        leg['issues'].each do |issue_key, flag|
          acc[issue_key] += 1 if flag
        end
      end
    end

    def lap_reference_for(row, idx)
      laps = Array(row['laps'])
      return nil if laps.empty?

      laps[idx - 1]
    end

    def parse_swimmer_reference(name, lap_reference)
      if lap_reference && lap_reference['swimmer'].to_s.include?('|')
        tokens = lap_reference['swimmer'].split('|')

        # Detect format: check if first token is a gender code
        gcode = normalize_gender(tokens[0])

        if gcode && tokens.size >= 5
          # Format: "M|LAST|FIRST|YEAR|TEAM" (5 tokens with gender)
          last = tokens[1]&.strip
          first = tokens[2]&.strip
          yob = tokens[3]&.strip
          team = tokens[4]&.strip
        elsif tokens.size >= 4
          # Format: "LAST|FIRST|YEAR|TEAM" (4 tokens without gender)
          last = tokens[0]&.strip
          first = tokens[1]&.strip
          yob = tokens[2]&.strip
          team = tokens[3]&.strip
          gcode = nil
        else
          # Malformed lap data, fall back to name parsing
          Rails.logger.warn("[RelayEnrichment] Malformed lap swimmer key: #{lap_reference['swimmer']}")
          return nil
        end

        return build_parsed_swimmer(last, first, yob, gcode, team, name)
      end

      tokens = name.to_s.strip.split
      return nil if tokens.size < 2

      first = tokens.pop
      last = tokens.join(' ')
      build_parsed_swimmer(last, first, nil, nil, nil, name)
    end

    def build_parsed_swimmer(last, first, yob, gender, team, display_name)
      {
        last_name: last,
        first_name: first,
        year_of_birth: yob,
        gender: normalize_gender(gender),
        team: team,
        display_name: display_name
      }
    end

    def phase3_match_for(parsed)
      key = swimmer_key_for(parsed[:last_name], parsed[:first_name], parsed[:year_of_birth])

      # Try exact match first
      return @phase3_by_key[key] if key && @phase3_by_key[key]

      # Try case-insensitive match
      if key
        normalized_key = key.downcase
        return @phase3_by_key_normalized[normalized_key] if @phase3_by_key_normalized[normalized_key]
      end

      # Fallback to name-only matching
      name_key = name_key_for(parsed[:last_name], parsed[:first_name])
      candidates = @phase3_by_name[name_key]
      return nil if candidates.blank?

      return candidates.first if parsed[:year_of_birth].blank?

      candidates.find { |cand| cand['year_of_birth'].to_s == parsed[:year_of_birth].to_s } || candidates.first
    end

    def swimmer_key_for(last, first, yob)
      return nil if last.blank? || first.blank? || yob.to_s.strip.empty?

      [last, first, yob].join('|')
    end

    def name_key_for(last, first)
      return nil if last.blank? || first.blank?

      [last.to_s.strip.downcase, first.to_s.strip.downcase].join('|')
    end

    def normalize_gender(code)
      return nil if code.blank?

      up = code.to_s.strip.upcase
      return 'M' if up.start_with?('M')
      return 'F' if up.start_with?('F')

      nil
    end
  end
end
