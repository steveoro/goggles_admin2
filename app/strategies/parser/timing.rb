# frozen_string_literal: true

require 'singleton'

module Parser
  #
  # = Timing
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20241010
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
    # 1) {{d}d'}{d}d[."]dd
    # 2) {{d}d[:.]}{d}d.{d}d
    # 2) {d}d[:\s]{d}d[:\s]{d}d
    #
    # == Returns
    # A valid Timing instance; +nil+ in case of unrecognized formats.
    #
    # *WARNING*: any partially matching pattern will result in a wrong timing.
    # Examples:
    # - "12'34.56" => correctly parsed
    # - "12:34.56" => correctly parsed
    # - "12:34:56" => correctly parsed
    # - "12.34.56" => correctly parsed
    # - "12 34 56" => correctly parsed
    # - "12\"34.56" => correctly parsed but 56 hds ignored
    #
    # rubocop:disable Lint/MixedRegexpCaptureTypes
    def self.from_l2_result(timing_text)
      # NOTE: removing the named captures will break this parser functionality
      reg_format1 = /((?<min>\d+)[\':\.])?(?<sec>\d{1,2})[\."](?<hun>\d{1,2})/u
      reg_format2 = /(?<min>\d{1,2})[:\s](?<sec>\d{1,2})[:\s](?<hun>\d{1,2})/u

      case timing_text
      when reg_format1
        minutes, seconds, hundredths = timing_text.match(reg_format1).captures

      when reg_format2
        minutes, seconds, hundredths = timing_text.match(reg_format2).captures

      else
        return nil
      end
      # NOTE: for some formats, the trailing hundreths may be have the implicit trailing zero,
      # so we left-justify the hundreths with a zero.
      # i.e.: "12:34.0" => "12:34.00", or "12:34.5" => "12:34.50"
      # (Not fixing this would make the parsing below misinterpret a ".1" as ".01" instead of a ".10")
      # (NOTE also that the above is *never* valid for minutes and seconds.)
      hundredths = hundredths.ljust(2, '0')

      ::Timing.new(minutes:, seconds:, hundredths:)
    end
    # rubocop:enable Lint/MixedRegexpCaptureTypes
  end
end
