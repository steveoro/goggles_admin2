# frozen_string_literal: true

require 'fuzzystringmatch'

module Merge
  # = Merge::BadgeSeasonChecker
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20241007
  #
  # Contrary to Merge::TeamChecker or Merge::SwimmerChecker (which handle mostly a single Team o Swimmer "target"),
  # this class allows to check a *whole* Season for duplicate swimmer badges, as well as any other conflicts
  # that may arise due to errors during the data-import procedure.
  #
  # "Duplicate badges" are Badges belonging to the same swimmer (inside the same Season) but linked to
  # different CategoryTypes. (Each Season should have a Badge with a single-individual CategoryType.)
  #
  # Same-category badges that have also different associated Teams will be checked for possible
  # team-merge candidates. (So, "duplicate badges" but with same CategoryType for the same Swimmer but with
  # different Teams.)
  #
  # Moreover, Badges linked to relay-only categories will be collected for possible purge or fix.
  # (Because current implementation uses Badge entites only for invidividual swimmer registration,
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
  # === "Relay" Badges (wrong category type):
  # BADGE with RELAY CATEGORY, with another having INDIV. CATEGORY:
  # - badge can be purged, sub-entities can be moved to any other valid badge
  #
  # BADGE with RELAY CATEGORY, NO OTHER EXISTING INDIV. CATEGORY found:
  # - badge can be fixed by re-assigning category using an esteemed category code based on YOB
  #
  #
  # == Attributes:
  # - <tt>#log</tt> => analysis log (array of string lines)
  # - <tt>#errors</tt> => error messages (array of string messages)
  # - <tt>#warnings</tt> => warning messages (array of string messages)
  # - <tt>#season</tt> => Season instance used for the analysis
  #
  # - <tt>#diff_category_badges</tt> => Hash of arrays of duplicate badges, keyed by Swimmer#id,
  #                                     with each array containing badges linked to the same Swimmer but
  #                                     different *CategoryType* (array of Badge instances)
  #
  # - <tt>#diff_team_badges</tt> => Hash of arrays of duplicate badges, keyed by Swimmer#id,
  #                                 with each array containing badges linked to the same Swimmer but
  #                                 different *Team* (array of Badge instances)
  #
  # - <tt>#diff_both_badges</tt> => Hash of arrays of duplicate badges, keyed by Swimmer#id,
  #                                 with each array containing badges linked to the same Swimmer but
  #                                 having both a different *Team* AND *CategoryType* (array of Badge instances)
  #
  # - <tt>#multi_badges</tt> => Hash of arrays of duplicate badges, keyed by Swimmer#id,
  #                             with each array containing all duplicate badges for the same swimmer
  #                             (union of all the above arrays of Badges)
  #
  # - <tt>#diff_category_swimmer_ids</tt> => Array of Swimmer#ids with duplicate badges (Badges with differernt Category)
  #
  # - <tt>#possible_team_merges</tt> => Array of arrays of possible Team merge candidates;
  #                                     each array contains a list of Team instances that can be merged together.
  #
  # - <tt>#relay_badges</tt> => Array of Badge instances linked to a relay-only category, including both
  #                             the ones with a possible valid duplicate and those without it.
  #                             (The ones with a valid duplicate can be fixed by merging them.)
  #
  # - <tt>#relay_only_badges</tt> => Array of Badge instances linked to a relay-only category but without
  #                                  any known valid category (so the category needs to be computed somehow).
  #
  # - <tt>#sure_badge_merges</tt> => Hash of arrays of badges in need to be either merged or fixed, keyed by Swimmer#id.
  #                                  These "sure" merges are:
  #                                  1. duplicate badges having the same Team but a different category
  #                                  2. wrongly-assigned badges linked to relay-only categories with no-known valid category
  #   (Note that duplicate badges with different Teams are not considered here on purpose as Team names of merge candidates
  #    need to be evaluated on a case-by-case basis before doing a manual merge.)
  #
  #
  # === Example usage:
  # > season = GogglesDb::Season.find(192)
  # > bsc = Merge::BadgeSeasonChecker.new(season: season) ; bsc.run ; bsc.display_report
  #
  class BadgeSeasonChecker # rubocop:disable Metrics/ClassLength
    attr_reader :log, :errors, :warnings, :season,
                :multi_badges, :diff_category_badges, :diff_team_badges, :diff_both_badges,
                :diff_category_swimmer_ids, :possible_team_merges,
                :relay_badges, :relay_only_badges, :sure_badge_merges, :possible_badge_merges

    # Any text distance >= DEFAULT_MATCH_BIAS will be considered viable as a match
    # (unless this default value is ovverriden in the constructor of the sibling class).
    DEFAULT_MATCH_BIAS = 0.89 unless defined?(DEFAULT_MATCH_BIAS)

    # Internal instance of the metric used to compute text distance
    METRIC = FuzzyStringMatch::JaroWinkler.create(:native)
    #-- -----------------------------------------------------------------------
    #++

    # Initializes the BadgeSeasonChecker. All internal data members will remain uninitialized until
    # #run is called.
    #
    # == Params:
    # - <tt>:season</tt> => source Season row, *required*
    #
    def initialize(season:)
      raise(ArgumentError, 'Invalid Season!') unless season.is_a?(GogglesDb::Season)

      @season = season.decorate
      initialize_data
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

      # Format for all below: { swimmer_id => [badge1, badge2, ...] }
      @multi_badges = {}          # Hash enlisting all swimmers x current season having more than 1 badge
      @diff_category_badges = {}  # Hash map of Badges having different Category x swimmer
      @diff_team_badges = {}      # Hash map of Badges having just a different Team x swimmer
      @diff_both_badges = {}      # Hash map of Badges having both different Team and Category x swimmer
      @sure_badge_merges = {}     # Hash of "certified" Badge merge candidates (different badges, same swimmer, same meeting or same team)
      @possible_badge_merges = {} # Hash of "possible" Badge merge candidates (different badges, same swimmer but with "similar" team names)

      # Collection of all swimmers with more than 1 Category x year (these all need manul fixing)
      @diff_category_swimmer_ids = []

      # All badges assigned to a relay category (which is wrong),
      # including also relay badges with duplicate, alternative categories:
      @relay_badges = []
      @relay_only_badges = []     # Relay badges without any possible alternative category (so it needs to be computed somehow)
      @possible_team_merges = []  # Array of Arrays of possible team merge candidates (each sub-array is an array of mergeable Teams)
    end

    # Launches the analysis process for merge feasibility while collecting data for the internal members.
    # *This process does not alter the database.*
    #
    # == "Mergeability":
    # - src vs. dest. Badge's MIRs/MRSs can have:
    #   1. same timing result, same event, different or same category
    #      => MERGEABLE/FIXABLE: 1 is correct, the other needs to be purged, sub-entities moved
    #   2a. different timing result, same event, different category
    #       => CONFLICT: NO MERGE
    #   2b. different timing result, same event, same category
    #       => CONFLICT: NO MERGE / ERROR: duplicated MIR (unfixable?)
    #
    # - src vs. dest. Badge's Laps are more loosely checked since can be user-edited:
    #   conflicts can be sorted out by either clearing the lap row or moving it to the new MIR,
    #   when not in conflict.
    #
    # == Returns:
    # +true+ if the merge seems feasible, +false+ otherwise.
    # Check the #log & #errors members for details and error messages.
    def run # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity,Metrics/MethodLength
      initialize_data if @log.present?

      @log << "\r\n[Season ID #{@season.id}] -- Badges analysis --\r\n"
      @relay_badges = GogglesDb::Badge.joins(:category_type)
                                      .includes(:category_type)
                                      .where('badges.season_id = ? AND category_types.relay = true', @season.id)
      relay_badges_ids = @relay_badges.pluck(:id)
      @relay_only_badges = @relay_badges.dup # (To be filtered of multi-badges more below)

      # Returns the list of same swimmers with >1 badge per season:
      multi_badge_swimmer_ids = GogglesDb::Badge.unscoped
                                                .select('season_id, swimmer_id, count(swimmer_id) as badge_count')
                                                .group('season_id', 'swimmer_id')
                                                .having('count(swimmer_id) > 1 AND season_id = ?', @season.id)
                                                .to_a
      multi_badge_swimmer_ids.map do |row|
        # (Sort by id as older badges are usually better candidates with more correct values - but not always)
        @multi_badges[row.swimmer_id] = GogglesDb::Badge.joins(:team, :category_type)
                                                        .includes(:team, :category_type)
                                                        .where('badges.season_id = ? AND swimmer_id = ?', @season.id, row.swimmer_id)
                                                        .order(:id)
      end

      @multi_badges.each do |swimmer_id, badges|
        different_category = badges.pluck(:category_type_id).uniq.size > 1
        different_team = badges.pluck(:team_id).uniq.size > 1

        if different_category && different_team
          @diff_both_badges[swimmer_id] = badges
          @diff_category_swimmer_ids << swimmer_id # Enlist all swimmers having > 1 category x year

        elsif different_category
          @diff_category_badges[swimmer_id] = badges
          @diff_category_swimmer_ids << swimmer_id # Enlist all swimmers having > 1 category x year

        elsif different_team
          @diff_team_badges[swimmer_id] = badges
        end

        # Check for possible team-merge candidates among the whole (sub-)list of badges
        any_mergeable_names = partition_teams_into_merge_candidates(badges)

        # Whenever the team_id is different, "badge mergeability" is still on if either:
        # - both badges share a meeting in common
        #     => sure merge (otherwise same swimmer may have 2 similar results x event)
        # - at least one of the badges has been found with a "similar" team name
        #     => possible merge (requires manual inspection of team names)
        if different_team
          already_considered = false

          badges.to_a.combination(2).each do |badge_couple|
            next unless Merge::BadgeSeasonChecker.badges_share_a_meeting?(badge_couple.first.id, badge_couple.last.id)

            # Add to "sure merges" only couples of different team ids which share a meeting in common:
            @sure_badge_merges[swimmer_id] = badge_couple
            already_considered = true
          end
          @possible_badge_merges[swimmer_id] = badges if any_mergeable_names && !already_considered

        # (== team_id, != category id => badges may be wrongly assigned)
        elsif different_category
          @sure_badge_merges[swimmer_id] = badge_couple

        # (== team_id, same category id => badges are all duplicates)
        elsif !different_team && !different_category
          @sure_badge_merges[swimmer_id] = badges
        end

        # Collect all relay badges without any possible alternative category for fixing:
        # (Find out if there's any badge in the current "duplicate list x swimmer" so that we
        #  can remove it from the relay badges that do not have duplicates.)
        badges.each do |badge|
          next if badges.size == 1 # Don't filter out single-item lists as they don't provide any alternatives for fixing
          next unless relay_badges_ids.include?(badge.id)

          @relay_only_badges -= [badge] if relay_badges_ids.include?(badge.id)
        end
      end

      # TODO
      # BadgeSeasonChecker should also "align" source and dest. Badge-merge candidates
      # according to which one is more data-complete of the two.
      # (Longer swimmer names should become source data fields that overwrite the dest. badge)

      log_stats
      log_team_merge_candidates
      log_badge_merge_candidates(@sure_badge_merges, 'SURE (same swimmer, same meeting)')
      log_badge_merge_candidates(@possible_badge_merges, 'POSSIBLE (similar team names)')

      compute_and_log_corrected_relay_only_categories if @relay_only_badges.present?
      if @relay_badges.present? || @sure_badge_merges.present?
        @log << "\r\nBefore doing any *TEAM* merge, fix possibly:"
        @log << "1. the #{@sure_badge_merges.keys.size} 'sure_badge_merges' (may include some relay-only badges)" if @sure_badge_merges.present?
        @log << "2. the #{@relay_badges.size} 'relay_badges'" if @relay_badges.present?
      end
      if @possible_badge_merges.present?
        @log << "There are #{@possible_badge_merges.size} 'possible_badge_merges' that require manual inspection before merging, due to similar team names."
      end
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
    def self.possible_matching_team_names?(team1, team2)
      METRIC.getDistance(team1.name, team2.name) >= DEFAULT_MATCH_BIAS ||
        METRIC.getDistance(team1.editable_name, team2.editable_name) >= DEFAULT_MATCH_BIAS ||
        METRIC.getDistance(team1.name, team2.editable_name) >= DEFAULT_MATCH_BIAS ||
        METRIC.getDistance(team1.editable_name, team2.name) >= DEFAULT_MATCH_BIAS
    end

    # Returns +true+ whenever the two provided badges share (at least) a meeting in common. (+false+ otherwise.)
    def self.badges_share_a_meeting?(badge_id1, badge_id2)
      meeting_ids1 = GogglesDb::MeetingIndividualResult.joins(:meeting).where(badge_id: badge_id1).pluck('meetings.id').uniq
      meeting_ids2 = GogglesDb::MeetingIndividualResult.joins(:meeting).where(badge_id: badge_id2).pluck('meetings.id').uniq
      meeting_ids1.intersect?(meeting_ids2)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Partitions the provided array of badges into possible team merge candidates.
    #
    # It iterates all possible combinations of the badges in the array and
    # checks whether the teams names associated with each badge are close enough
    # (using {#self.possible_matching_team_names?}) to be considered the same team.
    #
    # When a new possible merge candidate couple is found, it is added as a new list to
    # the internal {#possible_team_merges} array.
    #
    # If the couple is already enlisted, the missing teams are added to their respective
    # existing team merge candidate sub-array only when they are a new member of the
    # candidate list.
    #
    # == Parameters:
    # - <tt>badges_list</tt> => an array of GogglesDb::Badge rows to be partitioned.
    #
    # == Returns:
    # +true+ if the match & partitioning was successful;
    # +false+ otherwise (no matching teams found).
    def partition_teams_into_merge_candidates(badges_list) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize
      # Partition the badges into possible team merge candidates:
      badges_list.to_a.combination(2).each do |badge_couple|
        # Compare teams in pairs:
        team1 = badge_couple.first.team
        team2 = badge_couple.last.team
        new_possible_merge_candidates = @possible_team_merges.none? { |similar_teams| similar_teams.include?(team1) || similar_teams.include?(team2) }
        matching_team_names = Merge::BadgeSeasonChecker.possible_matching_team_names?(team1, team2)

        # New possible merge candidate couple (not yet enlisted)?
        # Add the possible team merge candidate couple as a new team list:
        if matching_team_names && new_possible_merge_candidates
          @possible_team_merges << badge_couple.map(&:team)
          true

        # Add the missing teams to their respective existing team merge candidate sub-array
        # only when they are a new member of the candidate list:
        elsif matching_team_names
          # Add only the missing teams:
          @possible_team_merges.find { |similar_teams| similar_teams.exclude?(team1) && similar_teams.include?(team2) }
                               &.push(team1)
          @possible_team_merges.find { |similar_teams| similar_teams.include?(team1) && similar_teams.exclude?(team2) }
                               &.push(team2)
          true
        else
          false
        end
      end
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    # Updates the internal log buffer with the statistics about the merge process.
    def log_stats # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      if @diff_both_badges.keys.present?
        @log << "- #{@diff_both_badges.keys.size} swimmers with DIFFERENT category & team \033[1;33;31m⚠\033[0m " \
                '(#diff_both_badges hash: <swimmer_id> => [badges_array])'
      end
      if @diff_category_badges.keys.present?
        @log << "- #{@diff_category_badges.keys.size} swimmers with DIFFERENT category (but SAME team) \033[1;33;31m⚠\033[0m " \
                '(#diff_category_badges hash: <swimmer_id> => [badges_array])'
      end
      if @diff_team_badges.keys.present?
        @log << "- #{@diff_team_badges.keys.size} swimmers with DIFFERENT team, including possible Team-merge candidates (all with SAME category) \033[1;33;33m⚠\033[0m " \
                '(#diff_team_badges hash: <swimmer_id> => [badges_array])'
      end
      if @multi_badges.keys.present?
        @log << '  ====='
        @log << "  \033[1;33;37m#{@multi_badges.keys.size}\033[0m swimmers with more than 1 badge x season. " \
                "(#multi_badges hash: <swimmer_id> => [badges_array])\r\n"
      end

      if @relay_badges.present?
        @log << "- #{@relay_badges.count} Badges wrongly assigned to a *RELAY* category in total, including duplication \033[1;33;31m⚠\033[0m " \
                '(#relay_badges array)'
      end
      if @relay_only_badges.present?
        @log << "- #{@relay_only_badges.count} Badges having only a wrong *RELAY* category without any alternative duplicate category \033[1;33;31m⚠\033[0m" \
                '(#relay_only_badges array)'
      end
      return if @diff_category_swimmer_ids.blank?

      @log << "\r\n\033[1;33;37mSwimmer IDs\033[0m & \033[1;33;33mBadge IDs\033[0m, which have > 1 category per same swimmer & season (THESE ALL NEED FIXING):"
      @diff_category_swimmer_ids.each_slice(3) do |swimmer_ids|
        # Justification size needs to compensate for all the ANSI escape sequences inside of it:
        decorated_list = swimmer_ids.map { |id| "- \033[1;33;37m#{id.to_s.rjust(6)}\033[0m B: #{collect_all_category_codes_for(id).join(' / ')}".to_s.ljust(120) }
        @log << decorated_list.join(' | ')
      end

      @log << "Total: #{@diff_category_swimmer_ids.size}, of which #{@relay_badges.count { |badge| @diff_category_swimmer_ids.include?(badge.swimmer_id) }} " \
              'with a wrongly assigned relay type of category.'
      @log << '(see #diff_category_swimmer_ids array, badge data filtered from #multi_badges hash: <swimmer_id> => [badges_array])'
    end

    # Using the cached @multi_badges Hash, collects as an array all CategoryType codes for the
    # given swimmer ID. Return nil if the swimmer ID is not found in the cache.
    def collect_all_category_codes_for(swimmer_id)
      @multi_badges.fetch(swimmer_id, []).map do |badge|
        color = badge.category_type.relay? ? '31' : '39' # red (relay) or grey (individual)
        "\033[1;33;33m#{badge.id}\033[0m \033[1;33;#{color}m#{badge.category_type.code}\033[0m"
      end
    end
    #-- ------------------------------------------------------------------------
    #++

    # Updates the internal log buffer with the list of Team merge candidates.
    def log_team_merge_candidates # rubocop:disable Metrics/AbcSize
      return if @possible_team_merges.blank?

      @log << "\r\n\033[1;33;37mAll possible TEAM-MERGE candidate IDs found among all badges:\033[0m (with or without difference in Category)"
      @possible_team_merges.each do |merge_candidates|
        team_ids = merge_candidates.map(&:id).sort
        involved_badges = GogglesDb::Badge.where(season_id: @season.id, team_id: team_ids)
        @log << "- #{team_ids.join(' ⬅ ')} \t('#{merge_candidates.first.name}' vs. '#{merge_candidates.last.name}'), for Badges:"
        involved_badges.each_slice(15) { |badges_slice| @log << "\t\t#{badges_slice.map(&:id).join(', ')}" }
        inv_relay_badges = involved_badges.pluck(:id).keep_if { |id| @relay_badges.pluck(:id).include?(id) }
        @log << "\t\t(Tot. #{involved_badges.count} Badges, of which #{inv_relay_badges.size} with relay-only categories)"
      end
      @log << "\r\n(#{possible_team_merges.size} rows in #possible_team_merges, " \
              "[Array of ['mergeable' badges_array]], each badge_array mergeable together due to a similar team name)\r\n"
    end
    #-- ------------------------------------------------------------------------
    #++

    # Updates the internal log buffer with the list of Badge merge candidates.
    def log_badge_merge_candidates(badges_x_swimmer_hash, title_label) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      return if badges_x_swimmer_hash.blank?

      @log << "\r\n\033[1;33;37m#{title_label} BADGE-MERGE fixes:\033[0m (tot. #{badges_x_swimmer_hash.keys.size})"
      @log << "[\033[1;33;32m⬅\033[0m : same team_id & category (true duplicates); \033[1;33;38m⬅\033[0m : != category; " \
              "\033[1;33;34m⬅\033[0m : != team_id; \033[1;33;35m⬅\033[0m : both !=]"
      # Divide the output into multiple columns:
      badges_x_swimmer_hash.keys.each_slice(3) do |swimmer_ids|
        column_array = []    # Stores the composed formatted row output
        decorated_list = []  # Stores the decorated list of Badges for a single swimmer
        swimmer_ids.each do |swimmer_id|
          all_same_team = badges_x_swimmer_hash[swimmer_id].map(&:team_id).uniq.size == 1
          all_same_category = badges_x_swimmer_hash[swimmer_id].map(&:category_type_id).uniq.size == 1
          joiner = if all_same_team && all_same_category
                     " \033[1;33;32m⬅\033[0m "
                   elsif all_same_team
                     " \033[1;33;38m⬅\033[0m "
                   elsif all_same_category
                     " \033[1;33;34m⬅\033[0m "
                   else
                     " \033[1;33;35m⬅\033[0m "
                   end
          decorated_list = badges_x_swimmer_hash[swimmer_id].map { |badge| "\033[1;33;33m#{badge.id.to_s.rjust(7)}\033[0m (#{badge.category_type.code})" }
          decorated_list << "\033[1;33;31m⚠\033[0m FIXME (relay category only)" if decorated_list.size == 1
          # Justification size needs to compensate for all the ANSI escape sequences inside of it:
          formatted_col = "- Swimmer #{swimmer_id.to_s.rjust(6)}, badges #{decorated_list.join(joiner)}".ljust(105)
          column_array << formatted_col
        end
        @log << column_array.join(' | ')
      end
      @log << "Total: #{badges_x_swimmer_hash.keys.size} (##{title_label.downcase}_badge_merges hash: <swimmer_id> => [badges_array])"
    end

    # Updates the internal log buffer with the list of RELAY-ONLY Badges that may need
    # correction to their CategoryType, because they are assigned to a relay-only category.
    def compute_and_log_corrected_relay_only_categories # rubocop:disable Metrics/AbcSize
      return if @relay_only_badges.blank?

      @log << "\r\n\033[1;33;37mPossible corrections for RELAY-ONLY Badges:\033[0m"
      @relay_only_badges.each_slice(2) do |badges|
        column_array = [] # Stores the composed formatted row output
        badges.each do |badge|
          age = @season.begin_date.year - badge.swimmer.year_of_birth
          category_type = @season.category_types.where('relay = false AND age_begin <= ? AND age_end >= ?', age, age).first
          # Justification size needs to compensate for all the ANSI escape sequences inside of it:
          formatted_col = "- Swimmer #{badge.swimmer_id.to_s.rjust(6)}, Badge \033[1;33;33m#{badge.id.to_s.rjust(7)}\033[0m, " \
                          "cat. #{badge.category_type_id} (#{badge.category_type.code}) " \
                          "=> fixed cat. #{category_type.id} (#{category_type.code}) age #{age}".ljust(105)
          column_array << formatted_col
        end
        @log << column_array.join(' | ')
      end
      @log << "Total: #{@relay_only_badges.size} (#relay_only_badges, [badges_array])"
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
