# frozen_string_literal: true

#
# = DataFix components module
#
#   - version:  7.0.6.00
#   - author:   Steve A.
#
module DataFix
  #
  # = DataFix::ResultDetailsCardComponent
  #
  # Renders a card containing all result for a certaing MeetingProgram,
  # including laps or relay swimmers if it's a relay and data is available.
  #
  # The chosen program row is assumed to be in the Hash format created
  # by the MacroParser (which includes a model 'row' element and also
  # its related 'bindings' array).
  #
  class ResultDetailsCardComponent < ViewComponent::Base
    def initialize(prg_key:, prg_row:, laps_rowset:)
      super
      @prg_key = prg_key
      @model_row = prg_row&.fetch('row', nil)
      # The following hack will be ok even for relays as we just need to
      # compare the result with >= 100:
      @length_in_meters = prg_key.to_s.split('-').second.to_i
      @laps_rowset = laps_rowset
      @rank = @model_row['rank']
      @timing = Timing.new(minutes: @model_row['minutes'], seconds: @model_row['seconds'], hundredths: @model_row['hundredths'])
      @std_points = @model_row['standard_points']
    end

    # Skips rendering unless the required parameters are set
    def render?
      @model_row.present? && @prg_key.present?
    end

    protected

    # Returns +true+ if the result ranking is positive; +false+ otherwise.
    def ranked?
      @rank.to_i.positive?
    end

    # Returns +true+ if the associated result is disqualified.
    def disqualified?
      @rank.to_i.zero? || @model_row&.fetch('disqualified', '').to_s == 'true' ||
        @model_row&.fetch('disqualification_code_type_id', 0).to_i.positive?
    end

    # Returns the disqualify label, if any.
    def dsq_label
      label_text = @model_row&.fetch('disqualification_notes', '')
      return 'DSQ' if label_text.blank?

      "DSQ: '#{label_text}'"
    end

    # Returns +true+ if the extracted timing is zero while the ranking is positive.
    #
    # This is considered as a red flag for a possible parsing error, given usually the timing
    # should never be +nil+ or zero unless the associated team or swimmer has been disqualified (rank: zero).
    # Returns +false+ otherwise.
    def zero_timing_with_rank?
      @timing.zero? && ranked?
    end

    # Returns +true+ if the result ranking is positive; +false+ otherwise.
    def css_class_for_card
      return 'border border-danger' if zero_timing_with_rank?

      ''
    end

    # Returns the array of uniq swimmer string names for any result (memoized)
    def lap_swimmers
      @lap_swimmers ||= @laps_rowset&.map { |row| row['swimmer_id'].present? ? GogglesDb::Swimmer.find(row['swimmer_id']).last_name : '🆕' }
                                    &.uniq
    end

    # Returns a memoized array storing a custom Hash of displayable text fields for each lap
    # or sub-lap row present in @laps_rowset, having structure:
    #
    #   {
    #     swimmer: <string name of the swimmer>,
    #     timing_from_start: <string timing from start>,
    #     timing: <string delta timing>,
    #     length_in_meters: <string length of this fraction>
    #   }
    def lap_list
      @lap_list ||= @laps_rowset&.map do |row|
        {
          swimmer: row['swimmer_id'].present? ? GogglesDb::Swimmer.find(row['swimmer_id']).last_name : '🆕',
          timing_from_start: Timing.new(minutes: row['minutes_from_start'], seconds: row['seconds_from_start'], hundredths: row['hundredths_from_start']),
          timing: Timing.new(minutes: row['minutes'], seconds: row['seconds'], hundredths: row['hundredths']),
          length_in_meters: row['length_in_meters']
        }
      end
    end
  end
end
