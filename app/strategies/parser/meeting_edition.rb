# frozen_string_literal: true

require 'singleton'

module Parser
  #
  # = MeetingEdition
  #
  #   - version:  7-0.3.53
  #   - author:   Steve A.
  #   - build:    20220609
  #
  # Wrapper for parsing helper methods regarding meeting edition types & numbers.
  #
  class MeetingEdition
    include Singleton

    # Parses and extracts the meeting edition type and its value from a meeting description
    # stored in "layout type 2" result file.
    #
    # == Examples:
    # - "15° Trofeo Regionale CSI" => [GogglesDb::EditionType::ROMAN_ID, 15]
    # - "Trofeo Gianni Pinotto 2021" => [GogglesDb::EditionType::YEARLY_ID, <previous_edition> + 1]
    # - "Campionato Regionale Master" => [GogglesDb::EditionType::SEASONAL_ID, <previous_edition> + 1]
    #
    # == Params
    # - <tt>meeting_description</tt> => the meeting description text
    #
    # == Returns
    # An array containing:
    # 1. the resulting GogglesDb::EditionType#id value;
    # 2. the integer edition number (or year number if it's a YEARLY edition type).
    #
    def self.from_l2_result(meeting_description)
      # Edition (always upfront) and description parsing:
      # TODO: TEST THE FOLLOWING after updating GogglesDb:
      edition, description = GogglesDb::Normalizers::CodedName.edition_split_from(meeting_description)
      # tokens = meeting_description.to_s.split(/(^[IXVLMCD]+\W)|(^\d{1,2}[°^oa]?\W)/u).reject(&:blank?)
      # edition, description = if tokens.instance_of?(Array) && tokens.length == 2
      #                          tokens
      #                        else
      #                          [nil, meeting_description]
      #                        end

                        # 1) Ex: "CAMPIONATO REGIONALE ...", "DISTANZE SPECIALI ..." (YYYY may be missing from name)
      edition_type_id = if description =~ /(((?<!Prova\W|Meeting\W)Camp.+\W(Reg.+\W)?)|(distanze\sspec)|italiani|mondiali|europei|\s\d{4}$)/ui
                          GogglesDb::EditionType::YEARLY_ID

                        # 2) Ex: "2a PROVA REGIONALE ..." or "II PROVA REGIONALE ...", edition value relative to current season
                        elsif description =~ /(prova\W(camp.+\W)?(reg.+\W)?|meeting\W(camp.+\W)?(reg.+\W)|final.\W(camp.+\W)?(reg.+\W)?)/ui
                          GogglesDb::EditionType::SEASONAL_ID

                        # 3) Ex: "16° Trofeo ...", "XXIV Meeting Internazionale ..." => both treated as "roman"
                        elsif edition.positive? # NO NEED, ALREADY PARSED: =~ /(^\d{1,3}|^[IXVLMCD]+)[\^°]?/u
                          GogglesDb::EditionType::ROMAN_ID
                          # [Steve, 20170705] "Ordinal" has never been actually used and has been deprecated:
                          # elsif edition =~ /^\d{1,3}[\^°]?\s/u
                          #   edition_type_id = EditionType::ORDINAL_ID

                        # 4) No visible edition reference
                        else
                          GogglesDb::EditionType::NONE_ID
                        end

      # NO NEED, ALREADY PARSED ***********
      # Parse the edition number:
      # edition = if edition =~ /\d+/
      #             edition.to_i
      #           elsif edition =~ /[IXVLMCD]+/ui
      #             Fixnum.from_roman(edition)
      #           elsif edition_type_id == GogglesDb::EditionType::YEARLY_ID
      #             reg = Regexp.new(/\s(\d{4})$/u)
      #             description.match(reg)&.captures&.first&.to_i || Time.zone.today.year
      #           end

      [edition_type_id, edition]
    end
  end
end
