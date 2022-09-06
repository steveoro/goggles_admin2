# frozen_string_literal: true

require 'singleton'

module Parser
  #
  # = SessionDate
  #
  #   - version:  7-0.3.53
  #   - author:   Steve A.
  #   - build:    20220609
  #
  # Wrapper for parsing helper methods regarding result session dates.
  #
  class SessionDate
    include Singleton

    # Shortened string names used to detect months
    MONTH_NAMES = %w[gen feb mar apr mag giu lug ago set ott nov dic].freeze
    #-- -------------------------------------------------------------------------
    #++

    # Builds up the ISO-formatted string date from the specified parameters.
    # (Example: "2022-06-07")
    #
    # == Params
    # - <tt>date_day</tt> => day of the date
    # - <tt>date_month</tt> => (verbose) month name of the date
    # - <tt>date_year</tt> => year of the date
    #
    # == Returns
    # The ISO-formatted string date
    #
    def self.from_l2_result(date_day, date_month, date_year)
      month_index = MONTH_NAMES.index(date_month.to_s[0..2].downcase) + 1
      "#{date_year}-#{month_index.to_s.rjust(2, '0')}-#{date_day.to_s.rjust(2, '0')}"
    end
  end
end
