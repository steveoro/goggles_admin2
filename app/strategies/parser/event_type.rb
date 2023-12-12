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
    # === Note:
    # For some format/context definitions, the category type may not be present at all in the section title,
    # thus it will have to be computed/parsed or extracted from other subsequent sections.
    # In the case of relays, the category can be deduced if all the swimmers of a team have been already
    # identified and their class/year_of_birth is available (the age sum must fall inside the category range).
    #
    # == Params
    # - <tt>section_title</tt> => the text title of the section.
    #                             Examples:
    #                               "50 Stile Libero - M25", "100 Farfalla - M25"m
    #                               "4X50m Stile Libero Master Maschi" (no category)
    #
    # - <tt>season</tt> => the Season instance in which this event takes place.
    #
    # == Returns
    # An array of 2 elements:
    # 1. the corresponding GogglesDb::EventType (independent from Season); +nil+ when not found;
    # 2. the GogglesDb::CategoryType for the specified Season; +nil+ when not found or not present.
    #
    # rubocop:disable Metrics/CyclomaticComplexity
    def self.from_l2_result(section_title, season)
      raise(ArgumentError, 'Invalid season specified') unless season.is_a?(GogglesDb::Season) && season.valid?
      raise(ArgumentError, "Invalid or empty title specified ('#{section_title}')") if section_title.to_s.blank?

      event_title, category_code = section_title.split(/\W+[-;]\W+/iu)
      # DEBUG
      puts "event_title: '#{event_title}', category_code: '#{category_code}'"

      stroke_type_id = nil
      relay = false

      reg = /((?<phases>\d)x)?(?<lap_len>\d{2,4})m?\W+(?<style>(\w+\s*)+)/iu
      match = reg.match(event_title)
      if match
        phases = (match[:phases] || 1).to_i
        relay = phases > 1
        phase_length_in_meters = match[:lap_len].to_i
        length_in_meters = phase_length_in_meters * phases.to_i
        stroke_type = match[:style]
        mixed_gender = (stroke_type =~ /(stile(\slibero)?(\smaster)?\smisti^)|((\smaster)?\smisti$)/iu).present?

        stroke_type_id = case stroke_type
                         when /stile/ui
                           GogglesDb::StrokeType::FREESTYLE_ID
                         when /dorso/ui
                           GogglesDb::StrokeType::BACKSTROKE_ID
                         when /rana/ui
                           GogglesDb::StrokeType::BREASTSTROKE_ID
                         when /farfalla|delfino/ui
                           GogglesDb::StrokeType::BUTTERFLY_ID
                         # Discriminate between relays & individual results:
                         when /misti/ui
                           relay ? GogglesDb::StrokeType::REL_INTERMIXED_ID : GogglesDb::StrokeType::INTERMIXED_ID
                         end
      end
      # DEBUG ----------------------------------------------------------------
      binding.pry unless GogglesDb::EventType.joins(:stroke_type).includes(:stroke_type)
                                             .find_by(phases:, length_in_meters:, phase_length_in_meters:,
                                                      stroke_type_id:, mixed_gender:)
                                             .present?
      # ----------------------------------------------------------------------
      [
        GogglesDb::EventType.joins(:stroke_type).includes(:stroke_type)
                            .find_by(phases:, length_in_meters:, phase_length_in_meters:,
                                     stroke_type_id:, mixed_gender:),
        GogglesDb::CategoryType.for_season(season)
                               .find_by(code: category_code)
      ]
    end
    # rubocop:enable Metrics/CyclomaticComplexity
  end
end
