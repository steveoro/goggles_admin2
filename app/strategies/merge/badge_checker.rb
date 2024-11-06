# frozen_string_literal: true

require 'fuzzystringmatch'

module Merge
  # = Merge::BadgeChecker
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20241015
  #
  # Check the feasibility of merging the Badge entities specified in the constructor while
  # also gathering all sub-entities that need to be moved or purged.
  #
  # See #{Merge::BadgeSeasonChecker} for more details.
  class BadgeChecker # rubocop:disable Metrics/ClassLength
    attr_reader :log, :errors, :warnings, :unrecoverable_conflict,
                :source, :dest, :categories_x_seasons

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
    # - <tt>:dest</tt> => destination Badge row; whenever this is left +nil+ (default)
    #                     the source Badge will be considered for fixing (in case the category needs
    #                     to be recomputed for any reason).
    def initialize(source:, dest: nil)
      raise(ArgumentError, 'Invalid source Badge!') unless source.is_a?(GogglesDb::Badge)
      raise(ArgumentError, 'Invalid destination!') unless dest.blank? || dest.is_a?(GogglesDb::Badge)
      raise(ArgumentError, 'Identical source and destination! (Use a nil destination to fix source.)') if dest && source.id == dest.id

      @source = source.decorate
      @dest = dest.decorate if dest
      initialize_data
    end
    #-- ------------------------------------------------------------------------
    #++

    # Maps all categories found or computed for the latest available Seasons of a specific SeasonType#id
    # and Swimmer#id.
    #
    # == Rationale behind usage:
    # The goal is to have a range of already defined categories to help identify the best possible or correct category
    # type for a given swimmer in any season.
    #
    # When > 1 badge is found in a Season having different category types (even a single different category/badge
    # is one too many), you need to go back (or forth) enough to cover the 5-years range that includes the correct
    # category type to discriminate between them.
    #
    # === For example:
    # - 2 badges found for the same swimmer in the same season, linked to 2 close-edge categories (e.g.: 'M25' vs 'M30');
    # - 1 clearly must be wrongly assigned or computed (as swimmers can belong to only 1 category type in each Season);
    # - to discriminate them apart (which is right? / which is wrong?), you need to see inside which 5-years range both fall;
    # - if, for example, there are already 4 same 'M25' category types badges in the preceding 5-years range,
    #   the current badge category shall be the last 'M25' category inside the 5-years range.
    #
    # == Params:
    # * <tt>season_type_id</tt>: SeasonType#id
    # * <tt>swimmer_id</tt>: Swimmer#id
    # * <tt>max_latest</tt>: limit the number of seasons to consider (default: 12, usually enough to discriminate)
    #
    # == Returns:
    # Returns an array of Hash items structured this way:
    #   {
    #     season_id: <Season#id>,
    #     swimmer_age: <computed swimmer age>,
    #     computed_category_type_id: <CategoryType#id> esteemed from Swimmer age & Season year,
    #     computed_category_type_code: <CategoryType#code> (as above),
    #     category_type_ids: array of unique <CategoryType#id> found in badges for this season,
    #     category_type_codes: array of unique <CategoryType#code> (as above),
    #     badges: array of Badge instances found in this season,
    #     teams: array of Hash items structured as { <Team#id> => <Team#name> } and mapped from this season
    #   }
    def self.map_categories_x_seasons(season_type_id, swimmer_id, max_latest = 12) # rubocop:disable Metrics/AbcSize
      raise(ArgumentError, "Can't find SeasonType with the specified id!") unless GogglesDb::SeasonType.exists?(season_type_id)
      raise(ArgumentError, "Can't find Swimmer with the specified id!") unless GogglesDb::Swimmer.exists?(swimmer_id)

      swimmer = GogglesDb::Swimmer.find(swimmer_id)
      latest_seasons = GogglesDb::Season.where(season_type_id:).order(:id).last(max_latest)

      latest_seasons.map do |season|
        swimmer_age = season.begin_date.year - swimmer.year_of_birth
        computed_category_type = season.category_types.where('relay = false AND age_begin <= ? AND age_end >= ?', swimmer_age, swimmer_age)
                                       .first
        badges = GogglesDb::Badge.includes(:category_type, :team)
                                 .joins(:category_type, :team)
                                 .where('badges.swimmer_id = ? AND badges.season_id = ?', swimmer_id, season.id)
        {
          season_id: season.id,
          swimmer_age:,
          computed_category_type_id: computed_category_type&.id,
          computed_category_type_code: computed_category_type&.code,
          category_type_ids: badges.map(&:category_type_id).uniq,
          category_type_codes: badges.map { |badge| badge.category_type.code }.uniq,
          badges:,
          teams: badges.map do |badge|
            { badge.team.id => "'#{badge.team.name}' (B: #{badge.id})" }
          end
        }
      end
    end

    # Returns a multi-line header detailing source & destination (if available) badges.
    #
    # == Params:
    # - <tt>src_badge</tt>: already decorated main/source GogglesDb::Badge instance
    # - <tt>dest_badge</tt>: already decorated destination GogglesDb::Badge instance; default: +nil+.
    # - <tt>computed_category_type_id</tt>: computed category type id
    # - <tt>computed_category_type_code</tt>: computed category type code
    #
    def self.badge_report_header(src_badge:, computed_category_type_id:, computed_category_type_code:, dest_badge: nil)
      return [] unless src_badge.is_a?(GogglesDb::Badge)

      header = [
        "\r\n🔹[Src  BADGE: #{src_badge.id.to_s.rjust(7)}] #{src_badge.short_label}, " \
        "Cat. #{src_badge.category_type_id} #{src_badge.category_type.code} " \
        "(computed cat. #{computed_category_type_id} #{computed_category_type_code})"
      ]
      if dest_badge.is_a?(GogglesDb::Badge)
        header << "🔹[Dest BADGE: #{dest_badge.id.to_s.rjust(7)}] #{dest_badge.short_label}, " \
                  "Cat. #{dest_badge.category_type_id} #{dest_badge.category_type.code}\r\n"
      end

      header
    end

    # Returns a single displayable string with the details of each category type & team found
    # for a badge in a given season.
    #
    # == Params:
    # - <tt>categories_map</tt>: a single Hash item of the list returned by BadgeChecker#map_categories_x_seasons.
    #
    def self.decorate_categories_map(categories_map)
      existing_teams = categories_map[:teams].map { |team_id, team_name| "#{team_id}: #{team_name}" }.join(', ')
      existing_categories = categories_map[:category_type_codes].map { |cat_code| cat_code }.join(', ')
      "  - Season #{categories_map[:season_id]}, age: #{categories_map[:swimmer_age]}, " \
        "cat: ~ #{categories_map[:computed_category_type_code]} " \
        "(#{categories_map[:computed_category_type_id].to_s.rjust(4)}) computed / " \
        "found #{existing_categories} -> #{existing_teams}"
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
      @unrecoverable_conflict = false

      # FUTUREDEV: (currently not used)
      # - badge_payments (badge_id)
      # - swimmer_season_scores (badge_id)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Launches the analysis process for merge feasibility while collecting
    # all data for the internal members. *This process DOES NOT alter the database.*
    #
    # Returns +true+ if the merge seems feasible, +false+ otherwise.
    # Check the #log & #errors members for details and error messages.
    #
    # == About "merging":
    # "Merging" implies moving all source data into the destination, so also the actual
    # swimmer columns will become the new destination values (names, year of birth, gender, ...).
    #
    # - SOURCE will become DESTINATION ("overwriting" everything about it, unless requested differently by parameters).
    # - New / missing sub-entity SOURCE rows will be moved to DESTINATION.
    # - Already existing sub-entity SOURCE rows will be purged.
    #
    # === About MIRs with possible nil badges:
    # Legacy MIRs may still turn out to have nil badges here and there.
    # In that eventuality, restore the missing seasonal Badges using the swimmer-team link.
    #
    # == Example usage:
    # From BadgeSeasonChecker output: "Swimmer 2208, badges 183101 (M25) ⬅ 132792 (M30)"
    #
    #   > dest = GogglesDb::Badge.find(132792) ; source = GogglesDb::Badge.find(183101) ; bc = Merge::BadgeChecker.new(source:, dest:) ; bc.run ; bc.display_report
    #
    # Keep in mind that usually older (smaller ID) badges tend to have the correct category assigned
    # either because imported from a web page stating the correct category or because already fixed
    # in the past.
    def run # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
      initialize_data if @log.present?

      @log += badge_analysis
      @log += mir_analysis
      @log += mrs_analysis
      @log += mres_analysis
      @log += mev_res_analysis
      @log += mrel_res_analysis
      @log += ments_analysis

      if @dest && (@source.category_type.relay? || @dest.category_type.relay?)
        @warnings << 'Wrong relay-only category found assigned to a badge (FIXABLE)'
      elsif @dest && @source.category_type_id != @dest.category_type_id
        @errors << 'Conflicting categories: incompatible CategoryTypes in same Season (MANUAL DECISION REQUIRED)'
      end

      if @dest && (@source.season_id != @dest.season_id)
        @unrecoverable_conflict = true
        @errors << 'Conflicting seasons! (Cannot merge badges from different Seasons)'
      end
      @errors << 'Conflicting teams! (MANUAL DECISION or OVERRIDE REQUIRED)' if @dest && (@source.team_id != @dest.team_id)

      @warnings << 'Conflicting MIR(s) found in same MeetingEvent (possible duplicates)' if mir_conflicting?
      @warnings << 'Conflicting MRS(s) found in same MeetingEvent (possible duplicates)' if mrss_conflicting?

      @warnings << 'Conflicting MReservation(s) found in same Meeting (DELETABLE)' unless mres_compatible?
      @warnings << 'Conflicting MEventReservation(s) found in same Meeting (DELETABLE)' unless mev_res_compatible?
      @warnings << 'Conflicting MRelayReservation(s) found in same Meeting (DELETABLE)' unless mrel_res_compatible?
      @warnings << 'Conflicting Mentry(ies) found in same MeetingEvent (DELETABLE)' unless ments_compatible?

      @errors.blank?
      # FUTUREDEV: (see #initialize_data above)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Creates and outputs to stdout a detailed report of the entities involved in merging
    # the source into the destination as an ASCII table for quick reference.
    # rubocop:disable Rails/Output
    def display_report
      puts(@log.join("\r\n"))
      display_short_summary
    end

    # Outputs the short summary of the checking to stdout.
    def display_short_summary
      puts("\r\n\r\n*** WARNINGS: ***\r\n#{@warnings.join("\r\n")}") if @warnings.present?
      puts("\r\n\r\n*** ERRORS: ***\r\n#{@errors.join("\r\n")}") if @errors.present?
      puts("\r\n")
      puts(@errors.blank? ? 'RESULT: ✅' : 'RESULT: ❌')
      nil
    end
    # rubocop:enable Rails/Output

    # Returns true if the badge merge operation can attempt to fix the source category
    # by computing it using the esteemed swimmer age & season year.
    def category_auto_fixing?
      (@dest.nil? && @source.category_type.relay?) ||
        (@dest.present? && @source.category_type.relay? && @dest.category_type.relay?)
    end

    #-- ------------------------------------------------------------------------
    #                    Source vs. Destination Badge
    #-- ------------------------------------------------------------------------
    #++

    # Analyzes the badges of both source & destination swimmers.
    # Sets @categories_x_seasons with the Array of Hash items returned by Merge::BadgeChecker#map_categories_x_seasons().
    # Returns a multi-line report as an array of printable strings, describing both the source & destination entities
    # in detail.
    def badge_analysis
      return @badge_analysis if @badge_analysis.present?

      season_type_id = @source.season.season_type_id
      # Collect all category types found to help analyze which one to use:
      @categories_x_seasons = Merge::BadgeChecker.map_categories_x_seasons(season_type_id, @source.swimmer_id)
      # Returns an Array of:
      #   {
      #     season_id: <Season#id>,
      #     swimmer_age: <computed swimmer age>,
      #     computed_category_type_id: <CategoryType#id> esteemed from Swimmer age & Season year,
      #     computed_category_type_code: <CategoryType#code> (as above),
      #     category_type_ids: array of unique <CategoryType#id> found in badges for this season,
      #     category_type_codes: array of unique <CategoryType#code> (as above),
      #     badges: array of Badge instances found in this season,
      #     teams: array of Hash items structured as { <Team#id> => <Team#name> } and mapped from this season
      #   }
      curr_hash = @categories_x_seasons.find { |h| h[:season_id] == @source.season_id }

      @badge_analysis = ["\r\n\t*** Badge Checker ***"]
      @badge_analysis += Merge::BadgeChecker.badge_report_header(
        src_badge: @source,
        computed_category_type_id: curr_hash[:computed_category_type_id],
        computed_category_type_code: curr_hash[:computed_category_type_code],
        dest_badge: @dest
      )
      @badge_analysis << "\r\n--> CATEGORY AUTO-FIXING REQUIRED <--\r\n" if category_auto_fixing?
      @badge_analysis << "Latest 12 categories found for this same swimmer (#{@source.swimmer_id}):"

      @categories_x_seasons.map do |categories_map|
        @badge_analysis << Merge::BadgeChecker.decorate_categories_map(categories_map)
      end

      @badge_analysis
    end

    #-- ------------------------------------------------------------------------
    #                    MeetingIndividualResult (from MeetingEvent)
    #-- ------------------------------------------------------------------------
    #++

    # Returns the list of all MIR rows that have a nil Badge ID.
    def all_mirs_with_nil_badge
      return @all_mirs_with_nil_badge if @all_mirs_with_nil_badge

      @all_mirs_with_nil_badge = GogglesDb::MeetingIndividualResult.where(badge_id: nil)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_event_id => mir_count }</tt>.
    # Each MeetingEvent ID is unique and grouped with its MIR count as associated value.
    # This is extracted from existing MIR rows involving the *source* badge and may return MeetingEvent IDs
    # which are shared by the destination badge too.
    def src_mevent_ids_from_mirs
      return @src_mevent_ids_from_mirs if @src_mevent_ids_from_mirs.present?

      @src_mevent_ids_from_mirs = GogglesDb::MeetingIndividualResult.joins(:meeting_event).includes(:meeting_event)
                                                                    .where(badge_id: @source.id)
                                                                    .group('meeting_events.id').count
    end

    # Similar to #src_mevent_ids_from_mirs but for @dest Badge.
    def dest_mevent_ids_from_mirs
      return @dest_mevent_ids_from_mirs if @dest_mevent_ids_from_mirs.present?
      return @dest_mevent_ids_from_mirs = {} if @dest.nil?

      @dest_mevent_ids_from_mirs = GogglesDb::MeetingIndividualResult.joins(:meeting_event).includes(:meeting_event)
                                                                     .where(badge_id: @dest.id)
                                                                     .group('meeting_events.id').count
    end

    # Returns an array similar to the ones above but containing only the "shared" MeetingEvent IDs
    # extracted from both source & destination MIR rows.
    #
    # These "shared rows" may link to different or overlapping MeetingPrograms, in turn linked
    # to different source & destination MIRs.
    # In other words, these "shared rows", will yield:
    #
    # 1. src. vs. "equal" dest. MIRs, having the same timing even though belonging to different M.Prgs.
    # 2. src. vs. "different" dest. MIRs, having a different timing result.
    #
    # Case 1. => source MIR (w/ laps) can "overwrite" destination (updating any other value);
    #      1.1 => any existing source sub-entity needs to be moved to the destination, if not already existing
    #      1.2 => purge any source sub-entity if already existing
    #
    # Case 2. => conflict! => cannot merge different MIRs unless a purge is forced manually.
    #                         (source over destination)
    def shared_mevent_ids_from_mirs
      return @shared_mevent_ids_from_mirs if @shared_mevent_ids_from_mirs.present?

      @shared_mevent_ids_from_mirs = dest_mevent_ids_from_mirs.dup.keep_if { |mevent_id, _mir_count| src_mevent_ids_from_mirs.key?(mevent_id) }
    end

    # Returns the difference array of unique MeetingEvent IDs & MIR counts involving *just* the *source* badge.
    def src_only_mevent_ids_from_mirs
      return @src_only_mevent_ids_from_mirs if @src_only_mevent_ids_from_mirs.present?

      @src_only_mevent_ids_from_mirs = src_mevent_ids_from_mirs.dup.delete_if { |mevent_id, _mir_count| dest_mevent_ids_from_mirs.key?(mevent_id) }
    end

    # Returns the difference array of unique MeetingEvent IDs & MIR counts involving *just* the *destination* badge.
    def dest_only_mevent_ids_from_mirs
      return @dest_only_mevent_ids_from_mirs if @dest_only_mevent_ids_from_mirs.present?

      @dest_only_mevent_ids_from_mirs = dest_mevent_ids_from_mirs.dup.delete_if { |mevent_id, _mir_count| src_mevent_ids_from_mirs.key?(mevent_id) }
    end
    #-- ------------------------------------------------------------------------
    #++

    # Source and destination MIRs are considered "conflicting" when any different timing is found
    # for any "shared" MIR inside a "shared" MeetingEvent.
    #
    # Even when this is +true+, purge of the conflicting MIR can always be forced when running
    # the actual merge (with "force_purge: true").
    def mir_conflicting?
      return false if shared_mevent_ids_from_mirs.blank?

      shared_mevent_ids_from_mirs.any? do |mevent_id, _mir_count|
        # (Compare just the oldest rows: 1 MIR x Badge x Event only)
        src_row = GogglesDb::MeetingIndividualResult.joins(:meeting_event).includes(:meeting_event)
                                                    .where(badge_id: @source.id, 'meeting_events.id': mevent_id)
                                                    .order(:id)
                                                    .first
        if @dest.present?
          dest_row = GogglesDb::MeetingIndividualResult.joins(:meeting_event).includes(:meeting_event)
                                                       .where(badge_id: @dest.id, 'meeting_events.id': mevent_id)
                                                       .order(:id)
                                                       .first
        end
        # Detect any conflicting timing (same timing or auto-fixing => no conflict):
        dest_row && (src_row.to_timing != dest_row.to_timing)
      end
    end

    # Prepares and returns a multi-row displayable mini-report regarding the provided couple of rows (src & dest.),
    # comparing them for "conflicts" (different value/timing).
    #
    # == Params:
    # - <tt>:mevent_id</tt> => MeetingEvent ID
    # - <tt>:src_row</tt> => source GogglesDb::MeetingIndividualResult
    # - <tt>:dest_row</tt> => destination GogglesDb::MeetingIndividualResult or +nil+ (auto-fixing mode)
    def decorate_mir(mevent_id, src_row, dest_row) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      raise ArgumentError, 'src_row must be a MeetingIndividualResult instance' unless src_row.is_a?(GogglesDb::MeetingIndividualResult)
      raise ArgumentError, 'dest_row must be a MeetingIndividualResult instance or nil' unless dest_row.nil? || dest_row.is_a?(GogglesDb::MeetingIndividualResult)
      unless (mevent_id == src_row.meeting_event.id) && (dest_row.nil? || mevent_id == dest_row&.meeting_event&.id)
        raise ArgumentError, 'Both src_row & dest_row, when defined, must belong to the same MeetingEvent ID'
      end

      mevent = GogglesDb::MeetingEvent.find(mevent_id).decorate
      conflicting = dest_row.present? && src_row.to_timing != dest_row.to_timing
      conflict_msg = conflicting ? '(Diff. timing! ❌)' : '(MERGEABLE! ✅)'
      result = "- {MEvent #{mevent_id.to_s.rjust(6)}} Season #{src_row.season.id}, MeetingEvent #{src_row.meeting.id} - #{mevent.display_label}\r\n" \
               "#{''.ljust(17)}🔹Src  [MIR #{src_row.id.to_s.ljust(7)}] swimmer_id: #{src_row.swimmer_id} (#{src_row.swimmer.complete_name}), " \
               "team_id: #{src_row.team_id} ➡ #{src_row.category_type.code} #{src_row.to_timing}, laps: #{src_row.laps.count}\r\n"
      return if dest_row.blank?

      result << "#{''.ljust(17)}🔹Dest [MIR #{dest_row.id.to_s.ljust(7)}] swimmer_id: #{dest_row.swimmer_id} (#{dest_row.swimmer.complete_name}), " \
                "team_id: #{dest_row.team_id} ➡ #{dest_row.category_type.code} #{dest_row.to_timing} #{conflict_msg}, " \
                "laps: #{dest_row.laps.count}\r\n"
      result
    end
    #-- ------------------------------------------------------------------------
    #++

    # Analizes source and destination associations for possible conflicting MIRs (different source & destination MIRs
    # belonging to the same MeetingEvent), returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case swimmers).
    #
    # Each analysis works in principle by collecting data in regard of a parent entity, which acts as a discriminant
    # between different rows.
    #
    # In this case, the discriminant is the MeetingEvent ID.
    # MIRs are considered "conflicting" whenever they have the same timing result while belonging to the same MeetingEvent.
    # (MeetingPrograms may or may not differ, as the category may be wrongly computed or esteemed.)
    def mir_analysis
      return @mir_analysis if @mir_analysis.present?

      @mir_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingIndividualResult.joins(:meeting_event, :badge).includes(:meeting_event, :badge),
        target_decorator: :decorate_mir,
        where_condition: 'meeting_individual_results.badge_id = ? AND meeting_events.id = ?',
        src_hash: src_only_mevent_ids_from_mirs,
        shared_hash: shared_mevent_ids_from_mirs,
        dest_hash: dest_only_mevent_ids_from_mirs,
        result_title: 'MIR (from parent MEvent)',
        subj_tuple_title: '(MeetingEvent ID, MIR count)'
      )

      # Check for nil Badges inside *any* MIRs, just for further clearance:
      # (As of 20240925 all MIRs with empty badge_id are already fixed)
      if all_mirs_with_nil_badge.present?
        @warnings << "#{all_mirs_with_nil_badge.count} (possibly unrelated) MIRs with nil badge_id" if all_mirs_with_nil_badge.present?
        @mir_analysis << "\r\n>> WARNING: #{all_mirs_with_nil_badge.count} MIRs with nil badge_id are present:"
        all_mirs_with_nil_badge.each { |mir| @mir_analysis << "- #{decorate_mir(mir)}" }
      end

      @mir_analysis
    end

    #-- ------------------------------------------------------------------------
    #                   MeetingRelaySwimmer (from MeetingEvent)
    #-- ------------------------------------------------------------------------
    #++

    # Returns the list of all MRS rows that have a nil Badge ID.
    def all_mrs_with_nil_badge
      return @all_mrs_with_nil_badge if @all_mrs_with_nil_badge

      @all_mrs_with_nil_badge = GogglesDb::MeetingRelaySwimmer.where(badge_id: nil)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ mevent_id => mrs_count }</tt>.
    # Each MeetingEvent ID is unique and grouped with its MRS count as associated value.
    # This is extracted from existing MRS rows involving the *source* Badge and may return
    # MeetingEvent IDs which are shared by the destination too.
    def src_mevent_ids_from_mrss
      return @src_mevent_ids_from_mrss if @src_mevent_ids_from_mrss.present?

      @src_mevent_ids_from_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event, :meeting_relay_result)
                                                                .includes(:meeting_event, :meeting_relay_result)
                                                                .where(badge_id: @source.id)
                                                                .group('meeting_events.id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ mevent_id => mrs_count }</tt>.
    # Each MeetingEvent ID is unique and grouped with its MRS count as associated value.
    # This is extracted from existing MRS rows involving the *destination* badge and may return MeetingEvent IDs which are shared
    # by the source badge too.
    def dest_mevent_ids_from_mrss
      return @dest_mevent_ids_from_mrss if @dest_mevent_ids_from_mrss.present?
      return @dest_mevent_ids_from_mrss = {} if @dest.nil?

      @dest_mevent_ids_from_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event, :meeting_relay_result)
                                                                 .includes(:meeting_event, :meeting_relay_result)
                                                                 .where(badge_id: @dest.id)
                                                                 .group('meeting_events.id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* MeetingEvent IDs extracted
    # from MRS rows involving *both* the *source* & the *destination* badge.
    #
    # These "shared rows" may link to different or overlapping MeetingPrograms, in turn linked
    # to different source & destination MRR-MRSs.
    def shared_mevent_ids_from_mrss
      return @shared_mevent_ids_from_mrss if @shared_mevent_ids_from_mrss.present?

      @shared_mevent_ids_from_mrss = dest_mevent_ids_from_mrss.dup.keep_if { |mevent_id, _mrs_count| src_mevent_ids_from_mrss.key?(mevent_id) }
    end

    # Returns the difference array of unique MeetingEvent IDs & MRS counts involving *just* the *source* badge.
    def src_only_mevent_ids_from_mrss
      return @src_only_mevent_ids_from_mrss if @src_only_mevent_ids_from_mrss.present?

      @src_only_mevent_ids_from_mrss = src_mevent_ids_from_mrss.dup.delete_if { |mevent_id, _mrs_count| dest_mevent_ids_from_mrss.key?(mevent_id) }
    end

    # Returns the difference array of unique MeetingEvent IDs & MRS counts involving *just* the *destination* badge.
    def dest_only_mevent_ids_from_mrss
      return @dest_only_mevent_ids_from_mrss if @dest_only_mevent_ids_from_mrss.present?

      @dest_only_mevent_ids_from_mrss = dest_mevent_ids_from_mrss.dup.delete_if { |mevent_id, _mrs_count| src_mevent_ids_from_mrss.key?(mevent_id) }
    end

    # MRSs are considered "compatible for merge" when:
    # - NO different timing instances (non-nil) are found inside the same MeetingEvent.
    #   (That is, "No conflicting results"; because no swimmer can have 2 different timing results
    #    inside the same event. Whenever the timing for 2 possibly overlapping results is the same,
    #    the destination result is considered as "already existing" and the source can be ignored & purged.)
    def mrss_conflicting?
      return false if shared_mevent_ids_from_mrss.blank?

      shared_mevent_ids_from_mrss.any? do |mevent_id, _mrs_count|
        # (Compare just the oldest rows: 1 MRS x Badge x Event only)
        src_row = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event, :meeting_relay_result)
                                                .includes(:meeting_event, :meeting_relay_result)
                                                .where(badge_id: @source.id, 'meeting_events.id': mevent_id)
                                                .order(:id)
                                                .first
        if @dest.present?
          dest_row = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event, :meeting_relay_result)
                                                   .includes(:meeting_event, :meeting_relay_result)
                                                   .where(badge_id: @dest.id, 'meeting_events.id': mevent_id)
                                                   .order(:id)
                                                   .first
        end
        # Detect any conflicting timing (same timing or auto-fixing => no conflict):
        dest_row && (src_row.to_timing != dest_row.to_timing)
      end
    end

    # Prepares and returns a multi-row displayable mini-report regarding the provided couple of rows (src & dest.),
    # comparing them for "conflicts" (different value/timing).
    #
    # == Params:
    # - <tt>:mevent_id</tt> => MeetingEvent ID
    # - <tt>:src_row</tt> => source GogglesDb::MeetingRelaySwimmer
    # - <tt>:dest_row</tt> => destination GogglesDb::MeetingRelaySwimmer or +nil+ (auto-fixing mode)
    def decorate_mrss(mevent_id, src_row, dest_row) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      raise ArgumentError, 'src_row must be a MeetingRelaySwimmer instance' unless src_row.is_a?(GogglesDb::MeetingRelaySwimmer)
      raise ArgumentError, 'dest_row must be a MeetingRelaySwimmer instance or nil' unless dest_row.nil? || dest_row.is_a?(GogglesDb::MeetingRelaySwimmer)
      unless (mevent_id == src_row.meeting_event.id) && (dest_row.nil? || mevent_id == dest_row&.meeting_event&.id)
        raise ArgumentError, 'Both src_row & dest_row, when defined, must belong to the same MeetingEvent ID'
      end

      mevent = GogglesDb::MeetingEvent.find(mevent_id).decorate
      conflicting = src_row.to_timing != dest_row.to_timing
      result = "- {MEvent #{mevent_id.to_s.rjust(6)}} Season #{src_row.season.id}, " \
               "MeetingEvent #{src_row.meeting.id} - #{mevent.display_label}\r\n" \
               "#{''.ljust(17)}🔹Src  [MRS #{src_row.id.to_s.ljust(7)}] " \
               "swimmer_id: #{src_row.swimmer_id} (#{src_row.swimmer.complete_name}), " \
               "team_id: #{src_row.team_id} ➡ #{src_row.category_type.code} #{src_row.to_timing}, " \
               "sub-laps: #{src_row.relay_laps.count}\r\n"
      return if dest_row.blank?

      result << "#{''.ljust(17)}🔹Dest [MRS #{dest_row.id.to_s.ljust(7)}] " \
                "swimmer_id: #{dest_row.swimmer_id} (#{dest_row.swimmer.complete_name}), " \
                "team_id: #{dest_row.team_id} ➡ #{dest_row.category_type.code} #{dest_row.to_timing} #{conflicting ? '❌' : '✅'}, " \
                "sub-laps: #{dest_row.relay_laps.count}\r\n"
      result
    end
    #-- ------------------------------------------------------------------------
    #++

    # Analizes source and destination associations for conflicting MRSs (different source & destination MRSs inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case swimmers).
    def mrs_analysis
      return @mrs_analysis if @mrs_analysis.present?

      @mrs_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingRelaySwimmer.joins(:meeting_event, :badge)
                                                     .includes(:meeting_event, :badge),
        target_decorator: :decorate_mrs,
        where_condition: 'meeting_relay_swimmers.badge_id = ? AND meeting_events.id = ?',
        src_hash: src_only_mevent_ids_from_mrss,
        shared_hash: shared_mevent_ids_from_mrss,
        dest_hash: dest_only_mevent_ids_from_mrss,
        result_title: 'MRS (from parent MEvent)',
        subj_tuple_title: '(MeetingEvent ID, MRS count)'
      )

      # Check for nil Badges inside *any* MRSs, just for further clearance:
      # (As of 20240925 all MRSs with empty badge_id are already fixed)
      if all_mrs_with_nil_badge.present?
        @warnings << "#{all_mrs_with_nil_badge.count} (possibly unrelated) MRSs with nil badge_id" if all_mrs_with_nil_badge.present?
        @mrs_analysis << "\r\n>> WARNING: #{all_mrs_with_nil_badge.count} MRSs with nil badge_id are present:"
        all_mrs_with_nil_badge.each { |mrs| @mrs_analysis << "- #{decorate_mrs(mrs)}" }
      end

      @mrs_analysis
    end

    #-- ------------------------------------------------------------------------
    #                               MeetingReservation
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mres_count }</tt>
    # mapped from *source* badge MeetingReservation.
    # Each Meeting ID is unique and grouped with its MRes count as associated value.
    def src_meeting_ids_from_mres
      return @src_meeting_ids_from_mres if @src_meeting_ids_from_mres.present?

      @src_meeting_ids_from_mres = GogglesDb::MeetingReservation.where(badge_id: @source.id)
                                                                .group('meeting_id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mres_count }</tt>
    # mapped from *destination* badge MeetingReservation.
    # Each Meeting ID is unique and grouped with its MRes count as associated value.
    def dest_meeting_ids_from_mres
      return @dest_meeting_ids_from_mres if @dest_meeting_ids_from_mres.present?
      return @dest_meeting_ids_from_mres = {} if @dest.nil?

      @dest_meeting_ids_from_mres = GogglesDb::MeetingReservation.where(badge_id: @dest.id)
                                                                 .group('meeting_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRes rows
    # involving *both* the *source* & the *destination* badge.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mres
      return @shared_meeting_ids_from_mres if @shared_meeting_ids_from_mres.present?

      @shared_meeting_ids_from_mres = dest_meeting_ids_from_mres.dup.keep_if { |meeting_id, _count| src_meeting_ids_from_mres.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRes counts involving *just* the *source* badge.
    def src_only_meeting_ids_from_mres
      return @src_only_meeting_ids_from_mres if @src_only_meeting_ids_from_mres.present?

      @src_only_meeting_ids_from_mres = src_meeting_ids_from_mres.dup.delete_if { |meeting_id, _count| dest_meeting_ids_from_mres.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRes counts involving *just* the *destination* badge.
    def dest_only_meeting_ids_from_mres
      return @dest_only_meeting_ids_from_mres if @dest_only_meeting_ids_from_mres.present?

      @dest_only_meeting_ids_from_mres = dest_meeting_ids_from_mres.dup.delete_if { |meeting_id, _count| src_meeting_ids_from_mres.key?(meeting_id) }
    end

    # MRes are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mres_compatible?
      shared_meeting_ids_from_mres.blank?
    end

    # Assuming <tt>mres</tt> is a GogglesDb::MeetingReservation, returns a displayable label for the row.
    def decorate_mres(mres)
      "[MRES #{mres.id}, Meeting #{mres.meeting_id}] swimmer_id: #{mres.swimmer_id} (#{mres.swimmer.complete_name}) " \
        "badge_id: #{mres.badge_id}, season: #{mres.season.id}"
    end

    # Analizes source and destination associations for conflicting MRESs (different source & destination row inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    def mres_analysis
      return @mres_analysis if @mres_analysis.present?

      @mres_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingReservation.joins(:meeting, :badge).includes(:meeting, :badge),
        target_decorator: :decorate_mres,
        where_condition: 'meeting_reservations.badge_id = ? AND meeting_reservations.meeting_id = ?',
        src_hash: src_only_meeting_ids_from_mres,
        shared_hash: shared_meeting_ids_from_mres,
        dest_hash: dest_only_meeting_ids_from_mres,
        result_title: 'MRES',
        subj_tuple_title: '(Meeting ID, MRES count)'
      )

      @mres_analysis
    end

    #-- ------------------------------------------------------------------------
    #                             MeetingEventReservation
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mev_res_count }</tt>
    # mapped from *source* badge MeetingEventReservation.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def src_meeting_ids_from_mev_res
      return @src_meeting_ids_from_mev_res if @src_meeting_ids_from_mev_res.present?

      @src_meeting_ids_from_mev_res = GogglesDb::MeetingEventReservation.where(badge_id: @source.id)
                                                                        .group('meeting_id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mev_res_count }</tt>
    # mapped from *destination* badge MeetingEventReservation.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def dest_meeting_ids_from_mev_res
      return @dest_meeting_ids_from_mev_res if @dest_meeting_ids_from_mev_res.present?
      return @dest_meeting_ids_from_mev_res = {} if @dest.nil?

      @dest_meeting_ids_from_mev_res = GogglesDb::MeetingEventReservation.where(badge_id: @dest.id)
                                                                         .group('meeting_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRelRes rows
    # involving *both* the *source* & the *destination* badge.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mev_res
      return @shared_meeting_ids_from_mev_res if @shared_meeting_ids_from_mev_res.present?

      @shared_meeting_ids_from_mev_res = dest_meeting_ids_from_mev_res.dup.keep_if { |meeting_id, _count| src_meeting_ids_from_mev_res.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRelRes counts involving *just* the *source* badge.
    def src_only_meeting_ids_from_mev_res
      return @src_only_meeting_ids_from_mev_res if @src_only_meeting_ids_from_mev_res.present?

      @src_only_meeting_ids_from_mev_res = src_meeting_ids_from_mev_res.dup.delete_if { |meeting_id, _count| dest_meeting_ids_from_mev_res.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MEvRes counts involving *just* the *destination* badge.
    def dest_only_meeting_ids_from_mev_res
      return @dest_only_meeting_ids_from_mev_res if @dest_only_meeting_ids_from_mev_res.present?

      @dest_only_meeting_ids_from_mev_res = dest_meeting_ids_from_mev_res.dup.delete_if { |meeting_id, _count| src_meeting_ids_from_mev_res.key?(meeting_id) }
    end

    # MEvRes are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mev_res_compatible?
      shared_meeting_ids_from_mev_res.blank?
    end

    # Assuming <tt>mev_res</tt> is a GogglesDb::MeetingEventReservation, returns a displayable label for the row.
    def decorate_mev_res(mev_res)
      "[MEV_RES #{mev_res.id}, Meeting #{mev_res.meeting_id}] swimmer_id: #{mev_res.swimmer_id} (#{mev_res.swimmer.complete_name}) " \
        "badge_id: #{mev_res.badge_id}, season: #{mev_res.season.id}"
    end

    # Analizes source and destination associations for conflicting MRESs (different source & destination row inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    def mev_res_analysis
      return @mev_res_analysis if @mev_res_analysis.present?

      @mev_res_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingEventReservation.joins(:meeting, :badge).includes(:meeting, :badge),
        target_decorator: :decorate_mev_res,
        where_condition: 'meeting_event_reservations.badge_id = ? AND meeting_event_reservations.meeting_id = ?',
        src_hash: src_only_meeting_ids_from_mev_res,
        shared_hash: shared_meeting_ids_from_mev_res,
        dest_hash: dest_only_meeting_ids_from_mev_res,
        result_title: 'MEV_RES',
        subj_tuple_title: '(Meeting ID, MEV_RES count)'
      )

      @mev_res_analysis
    end

    #-- ------------------------------------------------------------------------
    #                             MeetingRelayReservation
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mrel_res_count }</tt>
    # mapped from *source* badge MeetingRelayReservation.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def src_meeting_ids_from_mrel_res
      return @src_meeting_ids_from_mrel_res if @src_meeting_ids_from_mrel_res.present?

      @src_meeting_ids_from_mrel_res = GogglesDb::MeetingRelayReservation.where(badge_id: @source.id)
                                                                         .group('meeting_id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mrel_res_count }</tt>
    # mapped from *destination* badge MeetingRelayReservation.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def dest_meeting_ids_from_mrel_res
      return @dest_meeting_ids_from_mrel_res if @dest_meeting_ids_from_mrel_res.present?
      return @dest_meeting_ids_from_mrel_res = {} if @dest.nil?

      @dest_meeting_ids_from_mrel_res = GogglesDb::MeetingRelayReservation.where(badge_id: @dest.id)
                                                                          .group('meeting_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRelRes rows
    # involving *both* the *source* & the *destination* badge.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mrel_res
      return @shared_meeting_ids_from_mrel_res if @shared_meeting_ids_from_mrel_res.present?

      @shared_meeting_ids_from_mrel_res = dest_meeting_ids_from_mrel_res.dup.keep_if { |meeting_id, _count| src_meeting_ids_from_mrel_res.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRelRes counts involving *just* the *source* badge.
    def src_only_meeting_ids_from_mrel_res
      return @src_only_meeting_ids_from_mrel_res if @src_only_meeting_ids_from_mrel_res.present?

      @src_only_meeting_ids_from_mrel_res = src_meeting_ids_from_mrel_res.dup.delete_if { |meeting_id, _count| dest_meeting_ids_from_mrel_res.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRelRes counts involving *just* the *destination* badge.
    def dest_only_meeting_ids_from_mrel_res
      return @dest_only_meeting_ids_from_mrel_res if @dest_only_meeting_ids_from_mrel_res.present?

      @dest_only_meeting_ids_from_mrel_res = dest_meeting_ids_from_mrel_res.dup.delete_if { |meeting_id, _count| src_meeting_ids_from_mrel_res.key?(meeting_id) }
    end

    # MRelRes are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mrel_res_compatible?
      shared_meeting_ids_from_mrel_res.blank?
    end

    # Assuming <tt>mrel_res</tt> is a GogglesDb::MeetingRelayReservation, returns a displayable label for the row.
    def decorate_mrel_res(mrel_res)
      "[MREL_RES #{mrel_res.id}, Meeting #{mrel_res.meeting_id}] swimmer_id: #{mrel_res.swimmer_id} (#{mrel_res.swimmer.complete_name}) " \
        "badge_id: #{mrel_res.badge_id}, season: #{mrel_res.season.id}"
    end

    # Analizes source and destination associations for conflicting MREL_RES (different source & destination row inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    def mrel_res_analysis
      return @mrel_res_analysis if @mrel_res_analysis.present?

      @mrel_res_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingRelayReservation.joins(:meeting, :badge).includes(:meeting, :badge),
        target_decorator: :decorate_mrel_res,
        where_condition: 'meeting_relay_reservations.badge_id = ? AND meeting_relay_reservations.meeting_id = ?',
        src_hash: src_only_meeting_ids_from_mrel_res,
        shared_hash: shared_meeting_ids_from_mrel_res,
        dest_hash: dest_only_meeting_ids_from_mrel_res,
        result_title: 'MREL_RES',
        subj_tuple_title: '(Meeting ID, MREL_RES count)'
      )

      @mrel_res_analysis
    end

    #-- ------------------------------------------------------------------------
    #                                MeetingEntry
    #-- ------------------------------------------------------------------------
    #++

    # Returns the list of all MEntry rows that have a nil Badge ID.
    def all_ments_with_nil_badge
      return @all_ments_with_nil_badge if @all_ments_with_nil_badge

      @all_ments_with_nil_badge = GogglesDb::MeetingEntry.where(badge_id: nil)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ mevent_id => ments_count }</tt>
    # mapped from *source* badge MeetingEntry.
    # Each MeetingEvent ID is unique and grouped with its MEntry count as associated value.
    def src_mevent_ids_from_ments
      return @src_mevent_ids_from_ments if @src_mevent_ids_from_ments.present?

      @src_mevent_ids_from_ments = GogglesDb::MeetingEntry.joins(:meeting_event).includes(:meeting_event)
                                                          .where(badge_id: @source.id)
                                                          .group('meeting_events.id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ mevent_id => ments_count }</tt>
    # mapped from *destination* badge MeetingEntry.
    # Each MeetingEvent ID is unique and grouped with its MEntry count as associated value.
    def dest_mevent_ids_from_ments
      return @dest_mevent_ids_from_ments if @dest_mevent_ids_from_ments.present?
      return @dest_mevent_ids_from_ments = {} if @dest.nil?

      @dest_mevent_ids_from_ments = GogglesDb::MeetingEntry.joins(:meeting_event).includes(:meeting_event)
                                                           .where(badge_id: @dest.id)
                                                           .group('meeting_events.id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MEntry rows
    # involving *both* the *source* & the *destination* badge.
    # NOTE: conflicting MEntries can be safely purged as they are temporary in nature (while results aren't).
    def shared_mevent_ids_from_ments
      return @shared_mevent_ids_from_ments if @shared_mevent_ids_from_ments.present?

      @shared_mevent_ids_from_ments = dest_mevent_ids_from_ments.dup.keep_if { |mevent_id, _count| src_mevent_ids_from_ments.key?(mevent_id) }
    end

    # Returns the difference array of unique MeetingEvent IDs & MEntry counts involving *just* the *source* badge.
    def src_only_mevent_ids_from_ments
      return @src_only_mevent_ids_from_ments if @src_only_mevent_ids_from_ments.present?

      @src_only_mevent_ids_from_ments = src_mevent_ids_from_ments.dup.delete_if { |mevent_id, _count| dest_mevent_ids_from_ments.key?(mevent_id) }
    end

    # Returns the difference array of unique Meeting IDs & MEntry counts involving *just* the *destination* badge.
    def dest_only_mevent_ids_from_ments
      return @dest_only_mevent_ids_from_ments if @dest_only_mevent_ids_from_ments.present?

      @dest_only_mevent_ids_from_ments = dest_mevent_ids_from_ments.dup.delete_if { |mevent_id, _count| src_mevent_ids_from_ments.key?(mevent_id) }
    end

    # MEntries are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def ments_compatible?
      shared_mevent_ids_from_ments.blank?
    end

    # Assuming <tt>mentry</tt> is a GogglesDb::MeetingEntry, returns a displayable label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mentries(mentry)
      season_id = mentry.season.id
      badge = mentry.badge_id ? mentry.badge : GogglesDb::Badge.where(swimmer_id: mentry.swimmer_id, team_id: mentry.team_id, season_id:).first
      "[MEntry #{mentry.id}, M.Progr. #{mentry.meeting_program_id}] swimmer_id: #{mentry.swimmer_id} (#{mentry.swimmer.complete_name}) " \
        "badge_id: #{mentry.badge_id}, season: #{season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end

    # Analizes source and destination associations for conflicting MEntries
    # (different source & destination row inside same MeetingEvent),
    # returning an array of printable lines as an ASCII table for quick reference.
    def ments_analysis
      return @ments_analysis if @ments_analysis.present?

      @ments_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingEntry.joins(:meeting_event, :badge).includes(:meeting_event, :badge),
        target_decorator: :decorate_mentries,
        where_condition: 'meeting_entries.badge_id = ? AND meeting_events.id = ?',
        src_hash: src_only_mevent_ids_from_ments,
        shared_hash: shared_mevent_ids_from_ments,
        dest_hash: dest_only_mevent_ids_from_ments,
        result_title: 'M_ENTRY (from parent MEvent)',
        subj_tuple_title: '(MeetingEvent ID, MEntry count)'
      )

      # Check for nil Badges inside *any* MEntries, just for further clearance:
      if all_ments_with_nil_badge.present?
        @warnings << "#{all_ments_with_nil_badge.count} (possibly unrelated) MEntries with nil badge_id" if all_ments_with_nil_badge.present?
        @ments_analysis << "\r\n>> WARNING: #{all_ments_with_nil_badge.count} MEntries with nil badge_id are present:"
        all_ments_with_nil_badge.each { |mentry| @ments_analysis << "- #{decorate_mentries(mentry)}" }
      end

      @ments_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    # Maps source and destination associations for possible conflicting rows.
    # That is, "different" source & destination sibling rows associated to the same parent row.
    # Whenever a timing is involved (most of the times, really: MIR, MRS, MEntries, MEventReservations...)
    # two rows are considered different or conflicting if the timing is different (and the parent is the same).
    #
    # Returns an array of displayable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case swimmers).
    #
    # == Options:
    # - <tt>:result_array</tt> => target array to be filled with decorated rows from the
    #   provided domains;
    #
    # - <tt>:target_domain</tt>: actual ActiveRecord target domain for the analysis;
    #   E.g., for "MRR"s should be something including the parent entity like this:
    #     GogglesDb::MeetingRelaySwimmer.joins(:meeting).includes(:meeting)
    #
    # - <tt>:target_decorator</tt>: symbolic name of the method used to decorate the sibling
    #   rows extracted for reporting purposes (e.g.: ':decorate_mrs' for MRS target rows).
    #
    # - <tt>:where_condition</tt>: string WHERE condition binding target columns with the filtered sibling
    #   rows; the where_condition is assumed having these parameters:
    #   - @source.id / @dest.id (both will be used for checking -- see below for an example)
    #   - the array of filtered parent IDs as last parameter
    #   E.g. of a ':where_condition' parameter for MIRs:
    #     'meeting_individual_results.badge_id = ? AND meeting_events.id = ?'
    #
    # - <tt>:src_hash</tt>, <tt>:shared_hash</tt>, <tt>:dest_hash</tt> =>
    #   filtered Hash (tuples) to be included in the analysis report, having format
    #   [<parent row_id> => <sibling/target count>];
    #
    # - <tt>:result_title</tt>: label title to be used for this table section in the analysis report;
    #
    # - <tt>:subj_tuple_title</tt>: descriptive report label for the tuple stored in the domains,
    #   usually describing the format (<parent row_id>, <sibling/target count>).
    #
    def report_fill_for(opts = {}) # rubocop:disable Metrics/AbcSize,Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity,Metrics/MethodLength
      return opts[:result_array] if opts[:result_array].present?

      opts[:result_array] = [prepare_section_title(opts[:result_title])]

      if opts[:src_hash].present?
        centered_title = " SOURCE #{opts[:subj_tuple_title]} x [#{@source.id}: #{@source.display_label}] ".center(154, ' ')
        opts[:result_array] = fill_array_with_report_lines(tuple_list: opts[:src_hash], result_array: opts[:result_array], centered_title:)
        opts[:result_array] << "+#{'- Source-only parent rows: -'.center(154, ' ')}+"
        opts[:src_hash].each_key do |parent_id|
          row_ids = opts[:target_domain].where(opts[:where_condition], @source.id, parent_id).pluck(:id)
          opts[:result_array] << "- Parent ID #{parent_id} => Domain row IDs: #{row_ids.inspect}" if row_ids.present?
        end
        opts[:result_array] << "+#{''.center(154, '-')}+"
      else
        opts[:result_array] << ">> NO source-only #{opts[:result_title]}s."
      end

      if opts[:dest_hash].present?
        centered_title = " DEST #{opts[:subj_tuple_title]} x [#{@dest.id}: #{@dest.display_label}] ".center(154, ' ')
        opts[:result_array] = fill_array_with_report_lines(tuple_list: opts[:dest_hash], result_array: opts[:result_array], centered_title:)
        opts[:result_array] << "+#{'- Dest.-only parent rows: -'.center(154, ' ')}+"
        opts[:dest_hash].each_key do |parent_id|
          row_ids = opts[:target_domain].where(opts[:where_condition], @dest.id, parent_id).pluck(:id)
          opts[:result_array] << "- Parent ID #{parent_id} => Domain row IDs: #{row_ids.inspect}" if row_ids.present?
        end
        opts[:result_array] << "+#{''.center(154, '-')}+"
      else
        opts[:result_array] << ">> NO destination-only #{opts[:result_title]}s."
      end

      if opts[:shared_hash].present?
        centered_title = "SHARED rows #{opts[:subj_tuple_title]}".center(154, ' ')
        opts[:result_array] = fill_array_with_report_lines(tuple_list: opts[:shared_hash], result_array: opts[:result_array], centered_title:)
        opts[:result_array] << "+#{'- Shared parent rows: -'.center(154, ' ')}+"
        # Foreach row in a shared parent, check for conflicts and report a decorated line:
        opts[:shared_hash].each_key do |parent_id|
          # (ASSUMES/SIMPLIFICATION: mapping 1:1 => only 1 row x Badge x parent entity) Handles just the 1st:
          src_row = opts[:target_domain].where(opts[:where_condition], @source.id, parent_id).first
          dest_row = opts[:target_domain].where(opts[:where_condition], @dest.id, parent_id).first

          # Detect & log any conflicting row by value/timing:
          # (same value or timing => no conflict, src can be merged onto dest.)
          opts[:result_array] << send(opts[:target_decorator], parent_id, src_row, dest_row)
        end
        opts[:result_array] << "+#{''.center(154, '-')}+"
      else
        opts[:result_array] << ">> NO shared #{opts[:result_title]}s."
      end

      opts[:result_array]
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns a single string title for a section of the analysis, centered on 156 columns.
    def prepare_section_title(title_label)
      "\r\n\r\n\r\n#{''.center(156, '*')}\r\n**#{title_label.center(152, ' ')}**\r\n#{''.center(156, '*')}"
    end

    # Returns the <tt>result_array</tt> filled with printable report lines for a sub-section
    # report prepared by a specific section of an analysis (MIRs, MRSs, ...).
    # Assumes <tt>result_array</tt> to be already initialized as an Array.
    #
    # == Params:
    # - tuple_list: filtered list of tuples (or an Hash) to be used for filling the subtable;
    # - result_array: array storing the formatted result line;
    # - an already-centered title string for the subtable.
    #
    # == Returns:
    # The result array filled with printable report lines, showing the subtable of tuples
    # in the domain.
    #
    def fill_array_with_report_lines(tuple_list:, result_array:, centered_title:)
      result_array << "\r\n+#{''.center(154, '-')}+"
      result_array << ("|#{centered_title}|")
      result_array << "+#{''.center(154, '-')}+"
      result_array += tuple_list.each_slice(15).map do |line_array|
        line_array.map { |key_id, count| "#{key_id}: #{count}" }.join(', ')
      end
      result_array << "+#{''.center(154, '-')}+"
      result_array
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
