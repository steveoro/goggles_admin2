# frozen_string_literal: true

require 'singleton'

module Parser
  #
  # = EventType
  #
  #   - version:  7-0.3.53
  #   - author:   Steve A.
  #   - build:    20220607
  #
  # Wrapper for parsing helper methods for EventType & CategoryType instances.
  #
  class EventType
    include Singleton

    # Parses and extracts the event type & category from the section
    # title taken from a "layout type 2" result file.
    #
    # == Params
    # - <tt>section_title</tt> => the text title of the section.
    #                             Example: "50 Stile Libero - M25", "100 Farfalla - M25"
    #
    # - <tt>season</tt> => the Season instance in which this event takes place.
    #
    # == Returns
    # An array of 2 elements:
    # 1. the corresponding GogglesDb::EventType (independent from Season); +nil+ when not found;
    # 2. the GogglesDb::CategoryType for the specified Season; +nil+ when not found.
    #
    # rubocop:disable Metrics/CyclomaticComplexity
    def self.from_l2_result(section_title, season)
      raise(ArgumentError, 'Invalid season specified') unless season.is_a?(GogglesDb::Season) && season.valid?
      raise(ArgumentError, "Invalid or empty title specified ('#{section_title}')") if section_title.to_s.blank?

      event_title, category_code = section_title.split(/\W+[-;]\W+/iu)
      # DEBUG
      # puts "event_title: '#{event_title}', category_code: '#{category_code}'"

      reg = Regexp.new(/(\d{2,4})\W+(\w+\s*\w*)/iu)
      match = reg.match(event_title)
      length_in_meters, stroke_type = match.captures if match
      stroke_type_id = case stroke_type
                       when /stile/ui
                         GogglesDb::StrokeType::FREESTYLE_ID
                       when /dorso/ui
                         GogglesDb::StrokeType::BACKSTROKE_ID
                       when /rana/ui
                         GogglesDb::StrokeType::BREASTSTROKE_ID
                       when /farfalla|delfino/ui
                         GogglesDb::StrokeType::BUTTERFLY_ID
                       when /misti/ui
                         GogglesDb::StrokeType::INTERMIXED_ID
                       end
      [
        GogglesDb::EventType.joins(:stroke_type).includes(:stroke_type)
                            .find_by(length_in_meters: length_in_meters, stroke_type_id: stroke_type_id),
        GogglesDb::CategoryType.for_season(season)
                               .find_by(code: category_code)
      ]
    end
    # rubocop:enable Metrics/CyclomaticComplexity
  end
end
