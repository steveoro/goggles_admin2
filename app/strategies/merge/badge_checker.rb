# frozen_string_literal: true

require 'fuzzystringmatch'

# TODO: BadgeChecker
#
#  DATA FIX: meeting 19412 (RegVeneto 192),  most U25 results are existing M25 and so all computed categories are wrongly computed and results duplicated
#  => check for swimmers having 2 badges in different categories for the same season
#        (same IDs for swimmer, team, but different category)
#  => "keep just the older badge": check for sibling entites and move them to older badge
#
# team merge candidates (~500):
#   select swimmer_id, team_id, count(swimmer_id) cs
#   from badges b where (b.season_id = 192)
#   group by swimmer_id having cs > 1;
#
# Every swimmer w/ dual badges or more for the same season, where team name is similar
# (first example: `select swimmer_id, team_id from badges b where (b.season_id = 192) and (swimmer_id = 49)`
#   => yields teams 68 & 1339, both CSS, full name is on 1339)

# Returns the array of same swimmers w/ >1 badge per season:
# a = GogglesDb::Badge.unscoped
#                     .select('season_id, swimmer_id, count(swimmer_id) as same_swimmer')
#                     .group('season_id', 'swimmer_id').having('count(swimmer_id) > 1 AND season_id = 202')

# Each one can be a potential team-,merger candidate, if team name is similar
#   => also, category_type can be slightly different if deduced just from YOB => keep the oldest
#   => resolve conflicting badges first before doing the team merge

module Merge
  # = Merge::BadgeChecker
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20240920
  #
  # This class allows to check a specific Season for duplicate swimmer badges as well
  # as any other conflicting badges due to errors during the data-import procedure.
  #
  # "Duplicate badges" are Badges belonging to the same swimmer but linked to different CategoryTypes
  # for the same season.
  #
  # Same-category badges that have also different associated Teams will be checked for possible
  # team-merge candidates.
  #
  # Moreover, Badges linked to relay-only categories will be collected for possible purge or fix.
  # (Because the current implementation uses Badge entites only for invidividual swimmer registration,
  #  whereas all relay categories are supposedly linked only to meeting programs and relay results.)
  #
  #
  # === Duplicate badges criteria:
  # SAME SEASON, SWIMMER & TEAM, DIFFERENT CATEGORY:
  # - possible parsing mistake during data-import;
  #   => one of the two badges needs removal and all linked sub-entities
  #      need to be moved to the other badge(s).
  #
  # SAME SEASON, SWIMMER & CATEGORY, DIFFERENT TEAM:
  # - possible non-issue as it's not forbidden to have more than one team registration per year;
  #   => team names need to be checked for possible team merge, if they are close enough.
  #      (e.g. "A.R.C.A." vs. "Arca sports club")
  #
  #
  # === "Relay" Badges (wrong category type):
  # BADGE with RELAY CATEGORY, with another having INDIV. CATEGORY:
  # - badge can be purged, sub-entities can be moved to any other valid badge
  #
  # BADGE with RELAY CATEGORY, NO OTHER EXISTING INDIV. CATEGORY found:
  # - badge can be fixed by re-assigning category using an esteemed category code based on YOB
  #
  #
  # === Example usage:
  # > season = GogglesDb::Season.find(192)
  # > bc = Merge::BadgeChecker.new(season: season) ; bc.run ; bc.display_report
  #
  class BadgeChecker
    attr_reader :log, :errors, :warnings, :season,
                :diff_category_badges, :diff_team_badges, :diff_both_badges,
                :multi_badges, :diff_category_swimmer_ids, :possible_team_merges,
                :relay_badges

    # Any text distance >= DEFAULT_MATCH_BIAS will be considered viable as a match
    # (unless this default value is ovverriden in the constructor of the sibling class).
    DEFAULT_MATCH_BIAS = 0.89 unless defined?(DEFAULT_MATCH_BIAS)

    # Internal instance of the metric used to compute text distance
    METRIC = FuzzyStringMatch::JaroWinkler.create(:native)
    #-- -----------------------------------------------------------------------
    #++

    # Initializes the BadgeChecker.
    #
    # == Attributes:
    # - <tt>#log</tt> => analysis log (array of string lines)
    # - <tt>#errors</tt> => error messages (array of string messages)
    # - <tt>#warnings</tt> => warning messages (array of string messages)
    #
    # == Params:
    # - <tt>:season</tt> => source Season row, *required*
    #
    def initialize(season:)
      raise(ArgumentError, 'Invalid Season!') unless season.is_a?(GogglesDb::Season)

      @season = season.decorate
      @log = []
      @errors = []
      @warnings = []

      # Format for all below: { swimmer_id => [badge1, badge2, ...] }
      # Hash enlisting all swimmers per season having more than 1 badge:
      @multi_badges = {}
      @diff_category_badges = {} # Badges having different Category x swimmer
      @diff_team_badges = {}     # Badges having just a different Team x swimmer
      @diff_both_badges = {}     # Badges having both different Team and Category x swimmer
      @possible_team_merges = [] # Array of array of possible team merge candidates
      @relay_badges = []         # All badges assigned to a relay category (which is wrong)

      # Collection of all swimmers with more than 1 Category x year (these all need manul fixing)
      @diff_category_swimmer_ids = []
    end
    #-- ------------------------------------------------------------------------
    #++

    # Launches the analysis process for merge feasibility.
    # *This process does not alter the database.*
    #
    # Returns +true+ if the merge seems feasible, +false+ otherwise.
    # Check the #log & #errors members for details and error messages.
    def run # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
      @log << "\r\n[Season ID #{@season.id}] -- Badges analysis --\r\n"

      @relay_badges = GogglesDb::Badge.joins(:category_type)
                                      .includes(:category_type)
                                      .where('badges.season_id = ? AND category_types.relay = true', @season.id)

      # Returns the list of same swimmers with >1 badge per season:
      multi_badge_swimmer_ids = GogglesDb::Badge.unscoped
                                                .select('season_id, swimmer_id, count(swimmer_id) as badge_count')
                                                .group('season_id', 'swimmer_id')
                                                .having('count(swimmer_id) > 1 AND season_id = ?', @season.id)
                                                .to_a

      @log << "Found #{multi_badge_swimmer_ids.size} swimmers with more than 1 badge x season."
      multi_badge_swimmer_ids.map do |row|
        @multi_badges[row.swimmer_id] = GogglesDb::Badge.joins(:team, :category_type)
                                                        .includes(:team, :category_type)
                                                        .where('badges.season_id = ? AND swimmer_id = ?', @season.id, row.swimmer_id)
      end

      @multi_badges.each do |swimmer_id, badges|
        different_category = badges.pluck(:category_type_id).uniq.size > 1
        different_team = badges.pluck(:team_id).uniq.size > 1

        if different_category && different_team
          @diff_both_badges[swimmer_id] = badges

        elsif different_category
          @diff_category_badges[swimmer_id] = badges

        elsif different_team
          @diff_team_badges[swimmer_id] = badges
        end

        # Collect all swimmers having more than 1 category per year, which are in need of fixing:
        @diff_category_swimmer_ids << swimmer_id if different_category

        # Check for possible team-merge candidates the whole list of badges
        partition_teams_into_merge_candidates(badges) if different_team
      end

      log_stats
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

    # Returns +true+ whenever the two provided team names are close enough to be considered
    # the same team. Both +name+ and +editable_name+ will be considered for a match using
    # the internal Jaro-Winkler metric. (+false+ otherwise.)
    def possible_matching_team_names?(team1, team2)
      METRIC.getDistance(team1.name, team2.name) >= DEFAULT_MATCH_BIAS ||
        METRIC.getDistance(team1.editable_name, team2.editable_name) >= DEFAULT_MATCH_BIAS ||
        METRIC.getDistance(team1.name, team2.editable_name) >= DEFAULT_MATCH_BIAS ||
        METRIC.getDistance(team1.editable_name, team2.name) >= DEFAULT_MATCH_BIAS
    end
    #-- ------------------------------------------------------------------------
    #++

    # Partitions the provided array of badges into possible team merge candidates.
    #
    # It iterates all possible combinations of 2 badges in the array and checks whether
    # the teams associated with each badge are close enough (using
    # {#possible_matching_team_names?} to be considered the same team.
    #
    # When a new possible merge candidate couple is found, it is added as a new list to
    # the internal {#possible_team_merges} array.
    #
    # If the couple is already enlisted, the missing teams are added to their respective
    # existing team merge candidate sub-array only when they are a new member of the
    # candidate list.
    #
    # == Parameters:
    # - <tt>badges_list</tt> => an array of GogglesDb::Badge rows to be partitioned
    #
    # == Returns:
    # +nil+
    def partition_teams_into_merge_candidates(badges_list) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize
      # Partition the badges into possible team merge candidates:
      badges_list.to_a.combination(2).each do |badge_couple|
        # Compare teams in pairs:
        team1 = badge_couple.first.team
        team2 = badge_couple.last.team

        # New possible merge candidate couple (not yet enlisted)?
        # Add the possible team merge candidate couple as a new team list:
        if possible_matching_team_names?(team1, team2) &&
           @possible_team_merges.none? { |similar_teams| similar_teams.include?(team1) || similar_teams.include?(team2) }
          @possible_team_merges << badge_couple.map(&:team)

        # Add the missing teams to their respective existing team merge candidate sub-array
        # only when they are a new member of the candidate list:
        elsif possible_matching_team_names?(team1, team2)
          @possible_team_merges.find { |similar_teams| similar_teams.exclude?(team1) && similar_teams.include?(team2) }&.push(team1)
          @possible_team_merges.find { |similar_teams| similar_teams.include?(team1) && similar_teams.exclude?(team2) }&.push(team2)
        end
      end
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    # Updates the internal log buffer with the statistics about the merge process.
    def log_stats # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      @log << "- #{@diff_both_badges.keys.size} swimmers with DIFFERENT category & team \033[1;33;31m⚠\033[0m"
      @log << "- #{@diff_category_badges.keys.size} swimmers with DIFFERENT category (but SAME team) \033[1;33;31m⚠\033[0m"
      @log << "- #{@diff_team_badges.keys.size} swimmers with DIFFERENT team (but SAME category) \033[1;33;33m⚠\033[0m"
      @log << "- #{@relay_badges.count} Badges wrongly assigned to a *RELAY* category (\033[1;33;31m⚠\033[0m THESE NEED TO BE FIXED)."

      if @diff_category_swimmer_ids.present?
        @log << "\r\nSwimmer IDs having MORE than 1 category per same season/year (THESE ALL NEED FIXING):"
        @diff_category_swimmer_ids.each_slice(5) do |swimmer_ids|
          decorated_list = swimmer_ids.map { |id| "#{id} (#{collect_all_category_codes_for(id).join('/')})" }
          @log << "- #{decorated_list.join(', ')}"
        end
      end

      return if @possible_team_merges.blank?

      @log << "\r\nPossible Team-merge candidate IDs found among all swimmers:"
      @possible_team_merges.each do |merge_candidates|
        team_ids = merge_candidates.map(&:id).sort
        involved_badges = GogglesDb::Badge.where(season_id: @season.id, team_id: team_ids)
        @log << "- #{team_ids.join(', ')} \t('#{merge_candidates.first.name}'), involving Badges:"
        involved_badges.each_slice(15) { |badges_slice| @log << "\t\t#{badges_slice.map(&:id).join(', ')}" }
        inv_relay_badges = involved_badges.pluck(:id).keep_if { |id| @relay_badges.pluck(:id).include?(id) }
        @log << "\t\t(Tot. #{involved_badges.count} Badges, of which #{inv_relay_badges.size} with relay-only categories)\r\n"
      end
    end

    # Using the cached @multi_badges Hash, collects as an array all CategoryType codes for the
    # given swimmer ID. Return nil if the swimmer ID is not found in the cache.
    def collect_all_category_codes_for(swimmer_id)
      @multi_badges.fetch(swimmer_id, []).map { |badge| badge.category_type.code }
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
