# frozen_string_literal: true

module Merger
  #
  # = Merger::Swimmer
  #
  #   - version:  7-0.6.20
  #   - author:   Steve A.
  #   - build:    20240112
  #
  class Swimmer
    attr_reader :sql_log, :log

    # Allows a source Swimmer to be merged into a destination one. All related entities
    # will be handled (badges, results, laps, ...).
    #
    # == Params
    # - <tt>:source_row</tt> => source Swimmer row, *required*
    # - <tt>:dest_row</tt> => destination Swimmer row, *required*
    # - <tt>:toggle_debug</tt> => when true, additional debug output will be generated (default: +false+)
    #
    def initialize(source_row:, dest_row:, toggle_debug: false)
      raise(ArgumentError, 'Both source and destination must be swimmers!') unless source_row.is_a?(GogglesDb::Swimmer) && dest_row.is_a?(GogglesDb::Swimmer)

      @source_row = source_row
      @dest_row = dest_row
      @sql_log = []
      @log = []
      @toggle_debug = toggle_debug
    end
    #-- ------------------------------------------------------------------------
    #++

    # Executes the merge in a single transaction, logging both the process and
    # the SQL needed for replication.
    def perform!
      # TODO
    end
  end
end
