# frozen_string_literal: true

require 'fuzzystringmatch'

module Merge
  # = Merge::BadgeChecker
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20240923
  #
  # Check the feasibility of merging the Badge entities specified in the constructor while
  # also gathering all sub-entities that need to be moved or purged.
  #
  # See #{Merge::BadgeSeasonChecker} for more details.
  class BadgeChecker
    attr_reader :log, :errors, :warnings, :source, :dest,
                :multi_badges, :diff_category_badges, :diff_team_badges, :diff_both_badges,
                :diff_category_swimmer_ids, :possible_team_merges,
                :relay_badges, :relay_only_badges, :sure_badge_merges

    #-- -----------------------------------------------------------------------
    #++

    # Initializes the BadgeChecker. All internal data members will remain uninitialized until
    # #run is called.
    #
    # == Main attributes:
    # - <tt>#log</tt> => analysis log (array of string lines)
    # - <tt>#errors</tt> => error messages (array of string messages)
    # - <tt>#warnings</tt> => warning messages (array of string messages)
    #
    # == Params:
    # - <tt>:source</tt> => source Badge row, *required*
    # - <tt>:dest</tt> => destination Bade row; whenever this is left +nil+ (default)
    #                     the source Badge will be considered for fixing (in case the category needs
    #                     to be recomputed for any reason).
    def initialize(source:, dest: nil)
      raise(ArgumentError, 'Invalid Season!') unless season.is_a?(GogglesDb::Season)

      @source = source.decorate
      @dest = dest.decorate

      # TODO
    end
    #-- ------------------------------------------------------------------------
    #++

    # Initializes/resets all internal state variables for the analysis.
    #
    # == Purpose:
    # Initializes all internal state variables needed to collect data and statistics
    # about badges assigned to swimmers in the given season.
    #
    # == Side effects:
    # All internal state variables are initialized and ready for use after calling this method.
    def initialize_data
      @log = []
      @errors = []
      @warnings = []

      # TODO
    end

    # Launches the analysis process for merge feasibility while collecting data for the internal members.
    # *This process does not alter the database.*
    #
    # Returns +true+ if the merge seems feasible, +false+ otherwise.
    # Check the #log & #errors members for details and error messages.
    def run
      initialize_data
      @log << "\r\n[Season ID #{@season.id}] -- Badges analysis --\r\n"

      # TODO
      #
      @log += mir_analysis
      @log += lap_analysis

      @log += mrs_analysis
      @log += relay_lap_analysis
      @log += mres_analysis
      @log += mev_res_analysis
      @log += mrel_res_analysis
      @log += mes_analysis

      @relay_badges = GogglesDb::Badge.joins(:category_type)
                                      .includes(:category_type)
                                      .where('badges.season_id = ? AND category_types.relay = true', @season.id)

      nil
    end
    #-- ------------------------------------------------------------------------
    #++

    # Creates and outputs to stdout a detailed report of the entities involved in merging
    # the source into the destination as an ASCII table for quick reference.
    # rubocop:disable Rails/Output
    def display_report
      puts(@log.join("\r\n"))
      puts("\r\n")
      nil
    end
    # rubocop:enable Rails/Output
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                            MeetingIndividualResult
    #-- ------------------------------------------------------------------------
    #++

    # Analizes source and destination associations for conflicting MIRs (different source & destination MIRs inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case swimmers).
    def mir_analysis
      # TODO: see app/strategies/merge/swimmer_checker.rb:381
      # target_domain = GogglesDb::MeetingIndividualResult.joins(:meeting)
      #                                                   .includes(:meeting)
      #                                                   .where()

      # BadgeSeasonChecker should also "align" source and dest. Badge-merge candidates
      # according to which one is more data-complete of the two.
      # (Longer swimmer names should become source data fields that overwrite the dest. Badge;
      #  also, MIR & laps should all be moved to the actual destination.)
      #
      # (Badges need to point to the same swimmer in order to be considered for the merge)
      #
      # - src vs. dest. Badge's MIRs are: (this is valid also for MRRs and other "master" entities)
      #   1. same timing result, same event, different or same category => 1 is correct, the other needs to be purged, sub-entities moved
      #   2a. different timing result, same event, different category => CONFLICT: NO MERGE
      #   2b. different timing result, same event, same category => CONFLICT: NO MERGE / ERROR: duplicated MIR (unfixable?)
      #
      # - src vs. dest. Badge's Laps are more loosely checked since can be user-edited:
      #   conflicts are sorted out by either clearing the lap row or moving it to the new MIR, when not in conflict
    end
  end
end
