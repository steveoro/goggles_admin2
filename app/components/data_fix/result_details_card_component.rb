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
      @prg_key = prg_key
      @model_row = prg_row&.fetch('row', nil)
      @laps_rowset = laps_rowset
      @rank = @model_row['rank']
      @timing = Timing.new(minutes: @model_row['minutes'], seconds: @model_row['seconds'], hundredths: @model_row['hundredths'])
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
      label_text = @model_row&.fetch('relay_code', '')
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

    # Returns
    def lap_swimmers
      @lap_swimmers ||= @laps_rowset&.map { |row| row['swimmer_id'].present? ? GogglesDb::Swimmer.find(row['swimmer_id']).last_name : '🆕' }.uniq
    end

    # Returns
    def lap_timings
      @lap_timings ||= @laps_rowset&.map { |row| Timing.new(minutes: row['minutes_from_start'], seconds: row['seconds_from_start'], hundredths: row['hundredths_from_start']).to_s }
                                   &.join(' / ')
    end

    # Returns
    def delta_timings
      @delta_timings ||= @laps_rowset&.map { |row| Timing.new(minutes: row['minutes'], seconds: row['seconds'], hundredths: row['hundredths']).to_s }
                                     &.join(' / ')
    end
  end
end
