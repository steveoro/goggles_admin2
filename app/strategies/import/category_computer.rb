# frozen_string_literal: true

module Import
  #
  # = CategoryComputer
  #
  # Shared module for computing individual category_type for swimmers
  # using CategoriesCache or fallback to latest category from Swimmer model.
  #
  # Used by SwimmerSolver and RelayEnrichmentDetector to ensure consistent
  # category resolution across Phase 3 processing.
  #
  module CategoryComputer
    # Compute individual CategoryType for a swimmer given yob, gender, and meeting date.
    # Returns [category_type_id, category_type_code] or [nil, nil] if unresolvable.
    #
    # @param year_of_birth [Integer] swimmer's year of birth
    # @param gender_code [String] 'M' or 'F'
    # @param meeting_date [String,Date] meeting date to calculate age
    # @param season [GogglesDb::Season] current season for CategoriesCache
    # @param categories_cache [PdfResults::CategoriesCache,nil] optional pre-built cache
    # @return [Array<Integer,String>] [category_type_id, category_type_code] or [nil, nil]
    def self.compute_category(year_of_birth:, gender_code:, meeting_date:, season:, categories_cache: nil)
      return [nil, nil] unless year_of_birth && gender_code && meeting_date && season

      # Build cache if not provided
      cache = categories_cache || PdfResults::CategoriesCache.cached_for(season)

      # Parse meeting date to get year
      meeting_year = begin
        Date.parse(meeting_date.to_s).year
      rescue StandardError
        nil
      end
      return [nil, nil] unless meeting_year

      # Calculate swimmer's age at meeting
      age = meeting_year - year_of_birth.to_i

      # Use CategoriesCache to find the correct category for this season
      result = cache.find_category_for_age(age, relay: false)
      return [nil, nil] unless result

      _category_code, category_type = result

      # NOTE: Individual categories are gender-independent (M25, M30, etc. for both genders)
      # Gender is only used for relay categories
      [category_type.id, category_type.code]
    end

    # Compute relay CategoryType from the sum of swimmer ages in a relay team.
    #
    # Extracts YOB from each swimmer key in +swimmer_keys+, calculates individual
    # ages at +meeting_date+, sums them, and finds the matching relay CategoryType
    # via +CategoriesCache#find_category_for_age+ with +relay: true+.
    #
    # @param swimmer_keys [Array<String>] swimmer keys from relay laps (e.g. "M|ROSSI|MARIO|1990|TEAM")
    # @param meeting_date [String,Date] meeting date to calculate ages
    # @param season [GogglesDb::Season] current season for CategoriesCache
    # @param categories_cache [PdfResults::CategoriesCache,nil] optional pre-built cache
    # @return [Array<Integer,String>] [category_type_id, category_type_code] or [nil, nil]
    def self.compute_relay_category(swimmer_keys:, meeting_date:, season:, categories_cache: nil)
      return [nil, nil] unless swimmer_keys.is_a?(Array) && swimmer_keys.any? && meeting_date && season

      cache = categories_cache || PdfResults::CategoriesCache.cached_for(season)

      meeting_year = begin
        Date.parse(meeting_date.to_s).year
      rescue StandardError
        nil
      end
      return [nil, nil] unless meeting_year

      ages = swimmer_keys.filter_map do |key|
        yob = extract_yob_from_key(key)
        next unless yob&.positive?

        meeting_year - yob
      end
      return [nil, nil] if ages.empty? || ages.size != swimmer_keys.size

      age_sum = ages.sum
      result = cache.find_category_for_age(age_sum, relay: true)
      return [nil, nil] unless result

      _category_code, category_type = result
      [category_type.id, category_type.code]
    end

    # Extract year of birth from a swimmer key string.
    #
    # Handles keys with or without a leading gender token:
    #   "M|ROSSI|MARIO|1990|TEAM" → 1990
    #   "ROSSI|MARIO|1990|TEAM"   → 1990
    #
    # @param key [String] swimmer key
    # @return [Integer,nil] year of birth or nil if unresolvable
    def self.extract_yob_from_key(key)
      return nil if key.blank?

      tokens = key.to_s.split('|')
      offset = tokens.first.to_s.match?(/\A[MF]\z/i) || tokens.first.to_s.empty? ? 1 : 0
      yob = tokens[offset + 2].to_i
      yob.zero? ? nil : yob
    end

    # Compute category using Swimmer model's latest_category_type method as fallback.
    # Useful when meeting_date is not available.
    #
    # @param swimmer [GogglesDb::Swimmer] swimmer instance
    # @param season_type [GogglesDb::SeasonType] season type (default: mas_fin)
    # @return [Array<Integer,String>] [category_type_id, category_type_code] or [nil, nil]
    def self.compute_category_from_swimmer(swimmer:, season_type: nil)
      return [nil, nil] unless swimmer

      season_type ||= GogglesDb::SeasonType.mas_fin
      category_type = swimmer.latest_category_type(season_type)
      return [nil, nil] unless category_type

      [category_type.id, category_type.code]
    end
  end
end
