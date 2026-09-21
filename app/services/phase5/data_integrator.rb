# frozen_string_literal: true

module Phase5
  #
  # = Phase5::DataIntegrator
  #
  # Service class for integrating and inferring missing data in Phase 5 results:
  # - Relay gender inference from fin_sesso header or swimmer composition
  # - Swimmer gender propagation based on relay type
  # - Category code computation from swimmer ages
  #
  # Follows legacy l2_converter.rb patterns for category inference.
  #
  class DataIntegrator # rubocop:disable Metrics/ClassLength
    attr_reader :source_data, :phase3_data, :season, :categories_cache

    # Shortest partial phase-3 key tried during lookup: "|LAST|FIRST|YEAR"
    MIN_PARTIAL_KEY_TOKENS = 3

    # Initialize with source data and phase 3 data for swimmer lookup
    #
    # == Params:
    # - source_data: Hash from source JSON (LT4 format, normalized if LT2)
    # - phase3_data: Hash from phase 3 JSON (swimmer matching results)
    # - season: GogglesDb::Season instance for category computation
    #
    def initialize(source_data:, phase3_data: nil, season: nil, categories_cache: nil)
      @source_data = source_data
      @phase3_data = phase3_data
      @season = season
      # Initialize categories cache if season available
      @categories_cache = season ? (categories_cache || PdfResults::CategoriesCache.cached_for(season)) : nil
    end

    # Integrate relay result data: infer missing gender and category
    #
    # == Params:
    # - result: Hash from source relay result
    # - event: Hash from source event containing relay
    #
    # == Returns:
    # Hash with integrated data:
    # {
    #   gender: 'M' | 'F' | 'X',
    #   category: 'M280',
    #   inferred_swimmer_genders: { 'swimmer_key' => 'M' | 'F' },
    #   missing_data: []  # Array of missing data issues
    # }
    #
    def integrate_relay_result(result:, event:)
      integrated = {
        gender: nil,
        category: nil,
        inferred_swimmer_genders: {},
        missing_data: []
      }

      # Step 1: Extract or infer relay gender
      integrated[:gender] = extract_relay_gender(result, event)
      Rails.logger.debug { "[DataIntegrator] Relay gender: #{integrated[:gender]}" }

      # Step 2: Extract or compute category
      integrated[:category] = extract_relay_category(result, event, integrated[:gender])
      Rails.logger.debug { "[DataIntegrator] Relay category: #{integrated[:category]}" }

      # Step 3: Infer missing swimmer genders based on relay gender
      integrated[:inferred_swimmer_genders] = infer_relay_swimmer_genders(result, integrated[:gender])
      unless integrated[:inferred_swimmer_genders].empty?
        Rails.logger.debug { "[DataIntegrator] Inferred swimmer genders: #{integrated[:inferred_swimmer_genders]}" }
      end

      # Step 4: Track missing data
      integrated[:missing_data] << 'relay_gender' if integrated[:gender].blank?
      integrated[:missing_data] << 'relay_category' if integrated[:category].blank?

      integrated
    end

    # Integrate individual result data: infer missing category
    #
    # == Params:
    # - result: Hash from source individual result
    # - event: Hash from source event containing result
    #
    # == Returns:
    # Hash with integrated data:
    # {
    #   gender: 'M' | 'F' | 'X' | nil,
    #   category: 'M45',
    #   missing_data: []
    # }
    #
    def integrate_individual_result(result:, event:)
      integrated = {
        gender: nil,
        category: nil,
        missing_data: []
      }

      # Extract or infer individual gender
      integrated[:gender] = extract_individual_gender(result, event)
      integrated[:missing_data] << 'individual_gender' if integrated[:gender].blank?

      # Extract or compute category from YOB
      integrated[:category] = extract_individual_category(result, event)
      integrated[:missing_data] << 'individual_category' if integrated[:category].blank?

      integrated
    end

    private

    # Extract relay gender from result/event, with fallback to swimmer inference
    #
    # Priority:
    # 1. result['gender'] (may contain fin_sesso from source)
    # 2. Infer from swimmer composition (all F → F, all M → M, mixed → X)
    # 3. event['gender'] or event['eventGender']
    #
    def extract_relay_gender(result, event)
      # Check result first (may have fin_sesso from LT2 section)
      gender = result['gender'] || result['fin_sesso']
      return normalize_gender(gender) if gender.present?

      # Fallback: infer from swimmers
      inferred = infer_gender_from_swimmers(result)
      return inferred if inferred.present?

      # Last fallback: event-level gender
      gender = event['gender'] || event['eventGender']
      normalize_gender(gender)
    end

    # Infer relay gender from swimmer composition
    #
    # Logic:
    # - All female → 'F'
    # - All male → 'M'
    # - Mixed or unknown → 'X'
    #
    def infer_gender_from_swimmers(result)
      swimmer_genders = extract_swimmer_genders_from_result(result)
      return nil if swimmer_genders.empty?

      unique_genders = swimmer_genders.compact.uniq
      return 'F' if unique_genders == ['F']
      return 'M' if unique_genders == ['M']

      'X' # Mixed or indeterminate
    end

    # Extract individual gender from result/event with swimmer-based fallback.
    #
    # Priority:
    # 1. result['gender']
    # 2. Swimmer key / phase3 swimmer lookup
    # 3. event['gender'] or event['eventGender']
    def extract_individual_gender(result, event)
      gender = result['gender'] || result['gender_type'] || result['gender_type_code'] || result['fin_sesso']
      normalized = normalize_gender(gender)
      return normalized if normalized.present?

      inferred = infer_gender_from_individual_swimmer(result)
      return inferred if inferred.present?

      normalize_gender(event['gender'] || event['eventGender'])
    end

    # Infer individual gender from swimmer identity string and phase3 lookup.
    def infer_gender_from_individual_swimmer(result)
      swimmer_str = result['swimmer'] || result['swimmer_name'] || ''
      return nil if swimmer_str.blank?

      tokens = swimmer_str.split('|')

      # 5-token format with explicit gender: "GENDER|LAST|FIRST|YEAR|TEAM"
      # 4-token format with team: "GENDER|LAST|FIRST|YEAR|TEAM" (team optional)
      if tokens.size >= 4 && tokens[0].to_s.match?(/\A[MF]\z/i)
        normalized = normalize_gender(tokens[0])
        return normalized if normalized.present?
      end

      phase3_partial_key = partial_phase3_swimmer_key(tokens)
      return nil if phase3_partial_key.blank?

      lookup_swimmer_gender_from_phase3(phase3_partial_key)
    end

    # Build the gender-stripped phase3 key from swimmer tokens.
    # Output format: "|LAST|FIRST|YEAR" or "|LAST|FIRST|YEAR|TEAM" when a team token is present.
    def partial_phase3_swimmer_key(tokens)
      return nil if tokens.size < 3

      offset = tokens[0].to_s.match?(/\A[MF]\z/i) ? 1 : 0

      last_name = tokens[offset]
      first_name = tokens[offset + 1]
      yob = tokens[offset + 2]
      team = tokens[offset + 3]

      return nil if last_name.blank? || first_name.blank? || yob.to_s.strip.empty?

      key = "|#{last_name}|#{first_name}|#{yob}"
      team.present? ? "#{key}|#{team}" : key
    end

    # Extract known swimmer genders from result laps
    #
    # Returns array of gender codes: ['F', 'M', nil, ...]
    #
    def extract_swimmer_genders_from_result(result)
      laps = result['laps'] || []
      genders = []

      laps.each do |lap|
        swimmer_key = lap['swimmer']
        next if swimmer_key.blank?

        # Parse gender from 5-token format: "GENDER|LAST|FIRST|YEAR|TEAM"
        tokens = swimmer_key.split('|')
        if tokens.size >= 4 && tokens[0].to_s.match?(/\A[MF]\z/i)
          gender_code = tokens[0].to_s.strip.upcase
          genders << gender_code if %w[M F].include?(gender_code) # rubocop:disable Performance/CollectionLiteralInLoop
        else
          # 4-token format has no gender: "LAST|FIRST|YEAR|TEAM"
          # Try to lookup from phase3 data
          phase3_key = partial_phase3_swimmer_key(tokens)
          gender = lookup_swimmer_gender_from_phase3(phase3_key) if phase3_key
          genders << gender if gender.present?
        end
      end

      genders
    end

    # Lookup swimmer gender from phase 3 data
    # Handles partial matching for backward compatibility with old/new key formats
    def lookup_swimmer_gender_from_phase3(swimmer_key)
      normalize_gender(find_swimmer_in_phase3(swimmer_key)&.dig('gender_type_code'))
    end

    # Lookup the Phase-3 resolved category_type_code for the result's swimmer.
    # Phase 3 category codes are computed from YOB + gender using the actual meeting
    # date and are authoritative over raw source category codes.
    def lookup_swimmer_category_from_phase3(result)
      swimmer_str = result['swimmer'] || result['swimmer_name'] || ''
      tokens = swimmer_str.split('|')
      phase3_key = partial_phase3_swimmer_key(tokens)
      return nil if phase3_key.blank?

      find_swimmer_in_phase3(phase3_key)&.dig('category_type_code').presence
    end

    # Finds the phase-3 swimmer matching the given (possibly partial) key.
    # Tries the exact key first, then the gender-stripped key, then progressively
    # shorter keys (dropping trailing tokens such as the team) down to
    # "|LAST|FIRST|YEAR", so that the most complete match always wins.
    def find_swimmer_in_phase3(swimmer_key)
      return nil if swimmer_key.blank? || phase3_data.nil?

      exact = phase3_swimmers_by_key[swimmer_key]
      return exact if exact

      tokens = swimmer_key.sub(/\A(?:[MF]?\|)?/i, '').split('|')
      tokens.size.downto(MIN_PARTIAL_KEY_TOKENS) do |size|
        found = phase3_swimmers_by_partial_key["|#{tokens.first(size).join('|')}"]
        return found if found
      end
      nil
    end

    # Exact key => phase-3 swimmer hash (first occurrence wins).
    def phase3_swimmers_by_key
      @phase3_swimmers_by_key ||= phase3_swimmers.each_with_object({}) do |swimmer, index|
        key = swimmer['key']
        index[key] = swimmer if key && !index.key?(key)
      end
    end

    # Every pipe-delimited token-sequence of each phase-3 key that starts with a
    # '|' (e.g. "|LAST|FIRST|YOB", "|LAST|FIRST|YOB|TEAM", "|FIRST|YOB") => swimmer.
    # Lets gender-stripped partial keys resolve without scanning (first occurrence wins).
    def phase3_swimmers_by_partial_key
      @phase3_swimmers_by_partial_key ||= phase3_swimmers.each_with_object({}) do |swimmer, index|
        partial_keys_for(swimmer['key'].to_s).each do |partial|
          index[partial] = swimmer unless index.key?(partial)
        end
      end
    end

    def partial_keys_for(key)
      tokens = key.split('|', -1)
      (1...tokens.size).flat_map do |from|
        (from...tokens.size).map { |to| "|#{tokens[from..to].join('|')}" }
      end
    end

    def phase3_swimmers
      phase3_data&.dig('data', 'swimmers') || []
    end

    # TRUE when the category code resolves to a CategoryType defined for the
    # current season (or when it cannot be verified due to a missing season).
    # Source files may carry codes that are valid in other seasons or not valid
    # at all (e.g., 'A20', 'UNF', '*' summary tokens); those must be re-resolved.
    def valid_category_code?(category_code)
      return true unless categories_cache

      categories_cache.key?(category_code.to_s.strip.upcase)
    end

    # Undivided "catch-all" relay category code for the season (e.g., '000-999'),
    # used when a relay result carries an unresolvable category code.
    def undivided_relay_category_code
      categories_cache&.find_undivided_category(relay: true)
    end

    # Extract or compute relay category
    #
    # Priority:
    # 1. result['category'] when it resolves to a CategoryType for the season
    # 2. Compute from swimmer ages if all YOBs present
    # 3. Undivided "catch-all" relay category for the season (e.g., '000-999')
    # 4. Raw source value (lets the commit surface a lookup error)
    #
    def extract_relay_category(result, _event, relay_gender)
      # Check explicit category
      category = result['category'] || result['categoryTypeCode'] || result['category_code']
      return category if category.present? && valid_category_code?(category)

      # Compute from swimmer ages
      compute_relay_category_from_ages(result, relay_gender) ||
        undivided_relay_category_code ||
        category
    end

    # Compute relay category code from sum of swimmer ages
    #
    # Example: 4 swimmers with ages ~70 each → M280
    #
    def compute_relay_category_from_ages(result, relay_gender)
      meeting_date = extract_meeting_date
      return nil unless meeting_date && relay_gender.present?

      swimmer_ages = extract_swimmer_ages_from_result(result, meeting_date)
      return nil if swimmer_ages.empty? || swimmer_ages.include?(nil)

      age_sum = swimmer_ages.sum
      gender_prefix = relay_gender == 'X' ? 'X' : relay_gender

      "#{gender_prefix}#{age_sum}"
    end

    # Extract swimmer ages from result
    #
    # Returns array of ages or nil if YOB missing
    #
    def extract_swimmer_ages_from_result(result, meeting_date)
      laps = result['laps'] || []
      ages = []

      laps.each do |lap|
        swimmer_key = lap['swimmer']
        next if swimmer_key.blank?

        # Extract YOB from swimmer key
        tokens = swimmer_key.split('|')
        offset = tokens[0].to_s.match?(/\A[MF]\z/i) ? 1 : 0
        yob_idx = offset + 2
        yob = tokens[yob_idx].to_i
        next if yob.zero?

        age = meeting_date.year - yob
        ages << age
      end

      ages
    end

    # Infer missing swimmer genders based on relay gender
    #
    # Rules:
    # - F relay → all swimmers F
    # - M relay → all swimmers M
    # - X relay (mixed) → infer from known swimmers using 50% rule
    #   (if 2 known F → remaining 2 must be M)
    #
    def infer_relay_swimmer_genders(result, relay_gender)
      return {} if relay_gender.blank?

      laps = result['laps'] || []
      inferred = {}

      # Simple case: non-mixed relay
      if relay_gender != 'X'
        laps.each do |lap|
          swimmer_key = extract_phase3_key_from_lap(lap)
          inferred[swimmer_key] = relay_gender if swimmer_key.present?
        end
        return inferred
      end

      # Mixed relay: use 50% rule
      known_genders = {}
      laps.each do |lap|
        swimmer_key = extract_phase3_key_from_lap(lap)
        next if swimmer_key.blank?

        gender = extract_gender_from_lap(lap)
        known_genders[swimmer_key] = gender if gender.present?
      end

      # Count known genders
      female_count = known_genders.values.count('F')
      male_count = known_genders.values.count('M')
      total_swimmers = laps.size

      # Infer missing based on 50% rule (assumes equal split)
      expected_per_gender = total_swimmers / 2
      remaining_female = expected_per_gender - female_count
      remaining_male = expected_per_gender - male_count

      laps.each do |lap|
        swimmer_key = extract_phase3_key_from_lap(lap)
        next if swimmer_key.blank? || known_genders.key?(swimmer_key)

        # Assign gender to fill quota
        if remaining_female.positive?
          inferred[swimmer_key] = 'F'
          remaining_female -= 1
        elsif remaining_male.positive?
          inferred[swimmer_key] = 'M'
          remaining_male -= 1
        end
      end

      inferred
    end

    # Extract phase3 swimmer key from lap
    # New format: "|LAST|FIRST|YEAR" or "GENDER|LAST|FIRST|YEAR"
    def extract_phase3_key_from_lap(lap)
      swimmer_key = lap['swimmer']
      return nil if swimmer_key.blank?

      tokens = swimmer_key.split('|')
      if tokens.size >= 5
        # 5-token: "GENDER|LAST|FIRST|YEAR|TEAM" -> "GENDER|LAST|FIRST|YEAR"
        "#{tokens[0]}|#{tokens[1]}|#{tokens[2]}|#{tokens[3]}"
      elsif tokens.size >= 4
        # 4-token: "LAST|FIRST|YEAR|TEAM" -> "|LAST|FIRST|YEAR"
        "|#{tokens[0]}|#{tokens[1]}|#{tokens[2]}"
      end
    end

    # Extract gender from lap swimmer key (if present)
    def extract_gender_from_lap(lap)
      swimmer_key = lap['swimmer']
      return nil if swimmer_key.blank?

      tokens = swimmer_key.split('|')
      return nil unless tokens.size >= 5

      gender_code = tokens[0].to_s.strip.upcase
      %w[M F].include?(gender_code) ? gender_code : nil
    end

    # Extract or compute individual category
    #
    # Priority:
    # 1. result['category'] when it resolves to a CategoryType for the season
    # 2. Phase-3 resolved category_type_code for the swimmer
    # 3. Compute from YOB using CategoriesCache
    # 4. Raw source value (lets the commit surface a lookup error)
    #
    def extract_individual_category(result, _event)
      # Check explicit category
      category = result['category'] || result['categoryTypeCode'] || result['category_code']
      return category if category.present? && valid_category_code?(category)

      # Prefer the Phase-3 resolved category (computed with the actual meeting date),
      # then fall back to YOB-based computation
      lookup_swimmer_category_from_phase3(result) ||
        compute_individual_category_from_yob(result) ||
        category
    end

    # Compute individual category code from year of birth
    #
    # Uses CategoriesCache mixin for category lookup
    #
    def compute_individual_category_from_yob(result)
      meeting_date = extract_meeting_date
      return nil unless meeting_date

      # Extract YOB from swimmer
      swimmer_str = result['swimmer'] || result['swimmer_name'] || ''
      tokens = swimmer_str.split('|')
      return nil if tokens.size < 4

      yob = tokens[3].to_i
      return nil if yob.zero?

      gender = normalize_gender(tokens[0])
      return nil if gender.blank?

      # Use CategoriesCache to find category
      return nil unless categories_cache

      age = meeting_date.year - yob
      _code, category_type = categories_cache.find_category_for_age(age, relay: false)
      category_type&.code
    end

    # Extract meeting date from source data for age calculations
    def extract_meeting_date
      # Check source header
      header_date_str = source_data.dig('header', 'date') || source_data['meeting_date']
      return Date.parse(header_date_str) if header_date_str.present?

      # LT4 sources may expose a free-text 'dates' field (e.g., "2023-01-29" or "2023-01-29 - 2023-01-30")
      iso_match = source_data['dates'].to_s.match(/\d{4}-\d{2}-\d{2}/)
      return Date.parse(iso_match[0]) if iso_match

      # Fallback to season if available
      season&.begin_date
    rescue ArgumentError
      nil
    end

    # Normalize gender code to M/F/X
    def normalize_gender(gender_code)
      return nil if gender_code.blank?

      code = gender_code.to_s.strip.upcase
      return 'M' if /^M/i.match?(code)
      return 'F' if /^F/i.match?(code)
      return 'X' if /^X/i.match?(code)

      nil
    end
  end
end
