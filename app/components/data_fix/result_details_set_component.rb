# frozen_string_literal: true

#
# = DataFix components module
#
#   - version:  7.0.6.00
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
    def initialize(prg_rows:, prg_laps:)
      super
      @prg_rows = prg_rows
      @prg_laps = prg_laps
    end

    # Skips rendering unless the required parameters are set
    def render?
      @prg_rows.present?
    end

    protected

    # Memoized row-set of laps/relay_swimmers, filtered by the current #row_checker
    def laps_rowset(prg_key)
      @prg_laps&.filter_map { |lap_key, lap_row| lap_row&.fetch('row') if row_checker(prg_key).match?(lap_key) }
               &.sort { |a, b| a['length_in_meters'] <=> b['length_in_meters'] }
    end

    private

    # Row filter using a string +prg_key+ from the +@prg_rows+ hash to filter out any available
    # lap data.
    def row_checker(prg_key)
      Regexp.new(prg_key, Regexp::IGNORECASE)
    end
  end
end
