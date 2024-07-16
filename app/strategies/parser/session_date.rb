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

    # RegExp for text date matching:
    REGEXP_DATE = %r{(?>\w{3,},?\s?)?(?<day>\d{1,2})[\-\/\s\b](?<month>\d{1,2}|[a-z]{3,})[\-\/\s\b](?<year>\d{2,4})}ui
    #-- -------------------------------------------------------------------------
    #++

    # Builds up the ISO-formatted string date from the specified parameters.
    # (Example: "2022-06-07")
    #
    # == Params
    # - <tt>date_day</tt> => day of the date (e.g.: 7)
    # - <tt>date_month</tt> => (verbose) month name of the date (e.g. 'June')
    # - <tt>date_year</tt> => year of the date (e.g.: 2022)
    #
    # == Returns
    # The ISO-formatted string date according to the given parameters.
    #
    def self.from_l2_result(date_day, date_month, date_year)
      return if date_month.blank? || date_day.blank?

      month_index = MONTH_NAMES.index(date_month.to_s[0..2].downcase) + 1
      "#{date_year}-#{month_index.to_s.rjust(2, '0')}-#{date_day.to_s.rjust(2, '0')}"
    end

    # Tries to match the given text with the most common European date formats to
    # extract the possible date values for day, month and year.
    # Returns an array with the extracted parameters when parsed successfully.
    # (Example: "07-June-2022" => [7, 'June', 2022])
    #
    # == Params
    # - <tt>text_date_label</tt> => any common text representation of a date or (even a range of days)
    #
    # === Tested with:
    # (matches last-date only in a given group of days)
    # - mer, 15/4/2001, 25/03/1998, 25-12-1965, 5 7 2023
    # - 18 Ago 2025
    # - 15-16 Sett 2023, 17/18 Dic 2024, lun 15, mar 16 Sett 2023
    # - 4-5/Mar/2008, 7,8,10 Mar 2014, 8..11 Feb 2010, lun 15..mar 16 Sett 2023
    # -  7,8,10,11 Marzo 2014, 8...11 Feb 2010
    #
    # == Returns
    # An array with the last extracted day, month and year values
    # (e.g.: "4-5/Mar/2008" => ["5", "Mar", "2008"]);
    # returns +nil+ in case of no match.
    #
    def self.from_eu_text(text_date_label)
      return unless text_date_label.to_s.match?(REGEXP_DATE)

      text_date_label.to_s.match(REGEXP_DATE).captures
    end
  end
end
