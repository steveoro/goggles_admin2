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
      score_text.to_s
                .gsub(/['_]/, '')
                .sub(/,(\d{1,3})\z/, '.\1')
                .to_f
    end
  end
end
