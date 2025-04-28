# frozen_string_literal: true

module PdfResults
  # = PdfResults::CategoriesCache
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #
  # Cache helper class for CategoryType rows of a specified season.
  #
  class CategoriesCache
    attr_reader :season

    # Creates a new instance.
    #
    # == Params
    # - <tt>season</tt> => GogglesDb::Season instance for which the CategoryType data must be cached.
    #
    def initialize(season)
      raise 'Invalid season specified!' unless season.is_a?(GogglesDb::Season)

      @season = season
      # Collect the list of associated CategoryTypes to avoid hitting the DB for category code checking:
      @categories_cache = {}
      @season.category_types.each { |cat| @categories_cache[cat.code] = cat }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Converts the specified <tt>category_code</tt> into a proper GogglesDb::CategoryType.code value
    # using the internal +@categories_cache+ for codes comparison & match.
    #
    # == Params:
    # - <tt>category_code</tt> => a string category code as a single text number or already in format "M<NN>X?"
    #   for individual categories, or "<NNN>-<NNN>" for relay ones.
    # - <tt>relay</tt>: +true+ for relay codes; default: +false+
    #
    # == Returns:
    # The string #code corresponding to a matching CategoryType code.
    # (Adds an 'M' in front of it for the individual categories, returns
    # a stringified age range for relays.)
    # Returns the specified value as a string if it's not a single 2 or 3 digit category
    # age range.
    def normalize_category_code(category_code, relay: false)
      return category_code.to_s.upcase unless category_code.to_s.match?(/^\d{2,3}X?$/i)
      # Special case: '80X' for relays 0-79:
      return @categories_cache.keys.find { |code| code.ends_with?('-79') } if relay && category_code.to_s.match?(/^80X$/i)
      return @categories_cache.keys.find { |code| code.starts_with?("#{category_code}-") } if relay

      "M#{category_code}"
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns +true+ if the specified <tt>category_code</tt> is found in the internal cache; +false+
    # otherwise.
    #
    # == Params:
    # - <tt>category_code</tt> => the corresponding <tt>GogglesDb::CategoryType#code</tt> value.
    delegate :key?, to: :@categories_cache

    # Returns the <tt>GogglesDb::CategoryType</tt> for the specified <tt>category_code</tt> when found; +nil+
    # otherwise.
    #
    # == Params:
    # - <tt>category_code</tt> => the corresponding <tt>GogglesDb::CategoryType#code</tt> value.
    delegate :[], to: :@categories_cache
    #-- -----------------------------------------------------------------------
    #++

    # Finder for a category code & type inside the internal cache using its ID.
    # Only categories divided by gender are considered (not the "absolute" ones).
    #
    # == Params:
    # - <tt>id</tt> => the row ID belonging to the CategoryType.
    # - <tt>relay</tt>: +true+ for relay codes; default: +false+
    #
    # == Returns:
    # The array [category_code, category_type] corresponding to a matching CategoryType code.
    # +nil+ when not found.
    def find_category_by_id(id, relay: false)
      @categories_cache.find { |_code, cat| (cat.relay? == relay) && (cat.id == id) && !cat.undivided? }
    end

    # Finder for a category code & type inside the internal cache.
    # Only categories divided by gender are considered (not the "absolute" ones).
    #
    # == Params:
    # - <tt>age</tt> => the age belonging to the CategoryType range.
    # - <tt>relay</tt>: +true+ for relay codes; default: +false+
    #
    # == Returns:
    # The array [category_code, category_type] corresponding to a matching CategoryType code.
    # +nil+ when not found.
    def find_category_for_age(age, relay: false)
      # WARNING: sometimes, for older seasons or in exceptional cases, the age of the swimmer may be particularly low even if it's
      # supposed to be at least 16. We'll round it to 16 to make it enter inside the lowest age range.
      # (In such cases, the swimmer may be a guest of the team and flagged as "out of race", but still it can occur.)
      age = 16 if age < 16
      @categories_cache.find { |_code, cat| (cat.relay? == relay) && (cat.age_begin..cat.age_end).cover?(age) && !cat.undivided? }
    end
    #-- -----------------------------------------------------------------------
    #++
  end
end
