# frozen_string_literal: true

require 'singleton'

module Parser
  #
  # = CityName
  #
  #   - version:  7-0.3.53
  #   - author:   Steve A.
  #   - build:    20220607
  #
  # Wrapper for parsing helper methods for City names.
  #
  class CityName
    include Singleton

    # Extracts the individual parts, including the city name, from a generic
    # text address.
    #
    # The individual text parts may be separated by either a ';' or a '-' character.
    #
    # Tipically the city name is assumed to be located at the end of the address, but
    # may be found also at the beginning (with lower probability).
    # The province or area code is assumed to be in between brackets (either rounded
    # or squared) just aside the city name.
    #
    # == Params
    # - <tt>address</tt> => text address that allegedly contains the city name to be extracted.
    #
    # == Returns
    # An array of resulting String name tokens having the following items:
    # 1. the city name
    # 2. the area or province code (if any)
    # 3. the remainder of the address (if any), joined by '; '.
    #
    def self.tokenize_address(address)
      area_code = nil
      tokens = address.to_s.split(/\W*[-;]\W*/iu)

      if tokens.last =~ /\W*[\(\[]\w+[\)\]]/iu
        city_name, area_code = tokens.pop.split(/\W*[\(\[]/iu)
        area_code.gsub!(/[\)\]]/iu, '')

      elsif tokens.first =~ /\W*[\(\[]\w+[\)\]]/iu
        city_name, area_code = tokens.shift.split(/\W*[\(\[]/iu)
        area_code.gsub!(/[\)\]]/iu, '')

      else
        city_name = tokens.pop
      end

      [city_name, area_code, tokens.join('; ')]
    end
  end
end
