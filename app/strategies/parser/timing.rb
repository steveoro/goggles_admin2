# frozen_string_literal: true

require 'singleton'

module Parser
  #
  # = Timing
  #
  #   - version:  7-0.3.53
  #   - author:   Steve A.
  #   - build:    20220609
  #
  # Wrapper for parsing helper methods regarding result timings.
  #
  class Timing
    include Singleton

    # Builds up a valid Timing instance parsing the string timing text.
    # Hours & days are ignored from formats.
    #
    # == Params
    # - <tt>timing_text</tt> => a parsable string containing the timing
    #
    # == Recognized formats:
    # - '{...}' => optional
    # - '[...]' => variant
    #
    # 1) {{d}d'}{d}d"dd
    # 2) {{d}d[:.]}{d}d.{d}d
    #
    # == Returns
    # A valid Timing instance; +nil+ in case of unrecognized formats.
    #
    # *WARNING*: any partially matching pattern will result in a wrong timing.
    # Examples:
    # - "12:34:56" => nil
    # - "12\"34.56" => correctly parsed but 56 hds ignored
    # - "12'34.56" => minutes ignored, rest is parsed (as 34 secs & 56 hds)
    #
    def self.from_l2_result(timing_text)
      reg_format1 = Regexp.new(/((?<min>\d+)\')?(?<sec>\d{1,2})\"(?<hun>\d{1,2})/u)
      reg_format2 = Regexp.new(/((?<min>\d+)[:\.])?(?<sec>\d{1,2})\.(?<hun>\d{1,2})/u)

      case timing_text
      when reg_format1
        minutes, seconds, hundredths = timing_text.match(reg_format1).captures

      when reg_format2
        minutes, seconds, hundredths = timing_text.match(reg_format2).captures

      else
        return nil
      end

      ::Timing.new(minutes: minutes, seconds: seconds, hundredths: hundredths)
    end
  end
end
