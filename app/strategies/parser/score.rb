# frozen_string_literal: true

require 'singleton'

module Parser
  #
  # = Score
  #
  #   - version:  7-0.7.12
  #   - author:   Steve A.
  #   - build:    20240709
  #
  # Wrapper for parsing helper methods regarding result scores.
  #
  class Score
    include Singleton

    # Parses and extracts the score points taken from a "layout type 2" result file.
    # (Examples: "792.89", "792,89", "1.044,06", "1'044.06" or "1'044,06")
    #
    # == Params
    # - <tt>text</tt> => the text that includes the score
    #
    # == Returns
    # The float value of the score; 0.0 for no-score.
    #
    def self.from_l2_result(score_text)
      # Algorithm:
      # 0. Assume 1-3 digits of float precision
      # 1. Remove any 3-digit/thousands embellishments
      # 2. Transform the actual mantissa separator into a dot/decimal separator

      # This will also correctly handle also any possible 'DSQ' or 'DNF' score codes as 0.0
      score_text.to_s
                .gsub(/^(\d{1,2})['_.,]?(\d{1,3})[.,](\d{2})/, '\1\2.\3')
                .to_f
    end
  end
end
