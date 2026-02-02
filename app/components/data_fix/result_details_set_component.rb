# frozen_string_literal: true

#
# = DataFix components module
#
#   - version:  7.0.7.25
#   - author:   Steve A.
#
module DataFix
  #
  # = DataFix::ResultDetailsSetComponent
  #
  # Renders a list of ResultDetailsCardComponents given an hash of row results
  # and their corresponding laps (in data hash format), each filtered by their
  # common parent MeetingProgram.
  #
  # The component loops through the meeting program data, extracting
  # for each single result row (either individual or relay) any associated
  # lap data (either actual lap data or relay swimmer data), passing it
  # to the rendering of ResultDetailsCardComponents.
  #
  # Each program row is assumed to be in the Hash format created
  # by the MacroParser (which includes a model 'row' element and also
  # its related 'bindings' array).
  #
  class ResultDetailsSetComponent < ViewComponent::Base
    def initialize(res_rows:, res_laps:)
      super
      @res_rows = res_rows
      @res_laps = res_laps
    end

    # Skips rendering unless the required parameters are set
    def render?
      @res_rows.present?
    end

    protected

    # Sorted results rows by timing, regardless of rank
    def sorted_result_set
      @res_rows&.sort do |arr1, arr2|
        # Each item, when sorting an hash, is an array having [key, value]:
        a = arr1.second&.fetch('row', {})
        b = arr2.second&.fetch('row', {})
        Kernel.format('%<min>02d%<sec>02d%<hun>02d', min: a['minutes'].to_i, sec: a['seconds'].to_i,
                                                     hun: a['hundredths'].to_i).to_i <=> Kernel.format('%<min>02d%<sec>02d%<hun>02d', min: b['minutes'].to_i,
                                                                                                                                      sec: b['seconds'].to_i, hun: b['hundredths'].to_i).to_i
      end
    end

    # Row-set of laps/relay_swimmers, filtered by the current #row_checker
    def laps_rowset(res_key)
      @res_laps&.filter_map { |lap_key, lap_row| lap_row&.fetch('row') if row_checker(res_key).match?(lap_key) }
               &.sort { |a, b| a['length_in_meters'] <=> b['length_in_meters'] }
    end

    private

    # Row filter using a string +res_key+ from the +@res_rows+ hash to filter out any available
    # lap data.
    def row_checker(res_key)
      Regexp.new(res_key, Regexp::IGNORECASE)
    end
  end
end
