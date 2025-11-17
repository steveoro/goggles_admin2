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
  class DataIntegrator
    attr_reader :source_data, :phase3_data, :season, :categories_cache

    # Initialize with source data and phase 3 data for swimmer lookup
    #
    # == Params:
    # - source_data: Hash from source JSON (LT4 format, normalized if LT2)
    # - phase3_data: Hash from phase 3 JSON (swimmer matching results)
    # - season: GogglesDb::Season instance for category computation
    #
    def initialize(source_data:, phase3_data: nil, season: nil)
      @source_data = source_data
      @phase3_data = phase3_data
      @season = season
      # Initialize categories cache if season available
      @categories_cache = season ? PdfResults::CategoriesCache.new(season) : nil
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
    #   category: 'M45',
    #   missing_data: []
    # }
    #
    def integrate_individual_result(result:, event:)
      integrated = {
        category: nil,
        missing_data: []
      }

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
    # 2. event['gender'] or event['eventGender']
    # 3. Infer from swimmer composition (all F → F, all M → M, mixed → X)
    #
    def extract_relay_gender(result, event)
      # Check result first (may have fin_sesso from LT2 section)
      gender = result['gender'] || result['fin_sesso']
      return normalize_gender(gender) if gender.present?

      # Check event
      gender = event['gender'] || event['eventGender']
      return normalize_gender(gender) if gender.present?

      # Fallback: infer from swimmers
      infer_gender_from_swimmers(result)
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
      return 'X' if swimmer_genders.empty?

      unique_genders = swimmer_genders.compact.uniq
      return 'F' if unique_genders == ['F']
      return 'M' if unique_genders == ['M']

      'X' # Mixed or indeterminate
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
        if tokens.size >= 5
          gender_code = tokens[0].to_s.strip.upcase
          genders << gender_code if %w[M F].include?(gender_code)
        else
          # 4-token format has no gender: "LAST|FIRST|YEAR|TEAM"
          # Try to lookup from phase3 data
          phase3_key = tokens.size >= 3 ? "#{tokens[0]}|#{tokens[1]}|#{tokens[2]}" : nil
          gender = lookup_swimmer_gender_from_phase3(phase3_key) if phase3_key
          genders << gender if gender.present?
        end
      end

      genders
    end

    # Lookup swimmer gender from phase 3 data
    def lookup_swimmer_gender_from_phase3(swimmer_key)
      return nil unless phase3_data

      swimmers = phase3_data.dig('data', 'swimmers') || []
      swimmer = swimmers.find { |s| s['key'] == swimmer_key }
      normalize_gender(swimmer&.dig('gender_type_code'))
    end

    # Extract or compute relay category
    #
    # Priority:
    # 1. result['category']
    # 2. result['categoryTypeCode']
    # 3. Compute from swimmer ages if all YOBs present
    #
    def extract_relay_category(result, _event, relay_gender)
      # Check explicit category
      category = result['category'] || result['categoryTypeCode'] || result['category_code']
      return category if category.present?

      # Compute from swimmer ages
      compute_relay_category_from_ages(result, relay_gender)
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
        yob_idx = tokens.size >= 5 ? 3 : 2 # Account for optional gender prefix
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
    # Format: "LAST|FIRST|YEAR"
    def extract_phase3_key_from_lap(lap)
      swimmer_key = lap['swimmer']
      return nil if swimmer_key.blank?

      tokens = swimmer_key.split('|')
      if tokens.size >= 5
        # 5-token: "GENDER|LAST|FIRST|YEAR|TEAM"
        "#{tokens[1]}|#{tokens[2]}|#{tokens[3]}"
      elsif tokens.size >= 4
        # 4-token: "LAST|FIRST|YEAR|TEAM"
        "#{tokens[0]}|#{tokens[1]}|#{tokens[2]}"
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
    # 1. result['category']
    # 2. Compute from YOB using CategoriesCache
    #
    def extract_individual_category(result, _event)
      # Check explicit category
      category = result['category'] || result['categoryTypeCode'] || result['category_code']
      return category if category.present?

      # Compute from YOB
      compute_individual_category_from_yob(result)
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
