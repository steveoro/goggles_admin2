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
      cache = categories_cache || PdfResults::CategoriesCache.new(season)

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
