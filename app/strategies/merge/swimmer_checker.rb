# frozen_string_literal: true

module Merge
  # = Merge::SwimmerChecker
  #
  #   - version:  7-0.7.07
  #   - author:   Steve A.
  #   - build:    20240405
  #
  # Service class delegated to check the feasibility of merge operation between two
  # Swimmer instances: a source/slave row into a destination/master one.
  #
  # As a bonus, this class collects the processable entities involved in the merge.
  #
  # If the analysis reports that the merge is indeed feasible, the merge itself can
  # be carried out by an instance of Merge::Swimmer.
  #
  # === FAILURE = DON'T MERGE, whenever:
  # SAME SEASON, DIFFERENT AFFILIATION, DIFFERENT TEAM/BADGE:
  # - two swimmers belong to different teams in the same season;
  #   => merge the two teams first, only if possible and the teams actually need to be merged.
  #
  # SAME SEASON, DIFFERENT AFFILIATION, DIFFERENT CONFLICTING RESULTS:
  # - two swimmers belong to different teams in the same season with MIRs found inside same Meeting;
  #   => merge only if MIR are complementary and Teams can be merged, but merge the two teams first (as above).
  #      (may happen when running data-import from a parsed PDF result file over an existing Meeting)
  #
  # SAME AFFILIATION, DIFFERENT OVERLAPPING DETAILS:
  # - two swimmers belong to the same team but have different detail results linked
  #   to the same day/event/meeting (the detail data can overlap) and be considered
  #   a "deletable duplicate" only if equal in almost every column, except for the
  #   swimmer_id.
  #
  # === SUCCESS = CAN MERGE, whenever:
  # DIFFERENT SEASON (= DIFFERENT AFFILIATION):
  # - the two swimmers do not have overlapping details
  #
  # SAME TEAM, COMPATIBLE DETAILS:
  # - the two swimmers belong ultimately to the same team or group of affiliations but do not have
  #   overlapping detail data linked to them conflicting with each other (e.g. every result found belongs
  #   to a different meeting program when compared to the destination details, or when there
  #   are overlapping rows, these are indeed equalities, thus deletable duplicates).
  #
  class SwimmerChecker
    attr_reader :log, :errors, :source, :dest

    # Source Badges to be updated into destination Badges
    attr_reader :badges

    # Checks Swimmer merge feasibility.
    #
    # == Attributes:
    # - <tt>#log</tt> => analysis log (array of string lines)
    # - <tt>#errors</tt> => error messages (array of string messages)
    # - <tt>#warnings</tt> => warning messages (array of string messages)
    #
    # == Params:
    # - <tt>:source</tt> => source Swimmer row, *required*
    # - <tt>:dest</tt> => destination Swimmer row, *required*
    #
    def initialize(source:, dest:)
      raise(ArgumentError, 'Both source and destination must be Swimmers!') unless source.is_a?(GogglesDb::Swimmer) && dest.is_a?(GogglesDb::Swimmer)

      @source = source.decorate
      @dest = dest.decorate
      @log = []
      @errors = []
      @warnings = []
    end
    #-- ------------------------------------------------------------------------
    #++

    # Launches the analysis process for merge feasibility.
    # *This process does not alter the database.*
    #
    # Returns +true+ if the merge seems feasible, +false+ otherwise.
    # Check the #log & #errors members for details and error messages.
    def run
      @log << "[src: '#{@source.complete_name}', id #{@source.id}] |=> [dest: '#{@dest.complete_name}', id #{@dest.id}]"
      @source_badges = GogglesDb::BadgeDecorator.decorate_collection(@source.badges)
      @dest_badges = GogglesDb::BadgeDecorator.decorate_collection(@dest.badges)

      @warnings << 'Overlapping badges: different Badges in same Season' if shared_badge_seasons.present?
      # This is always relevant even if the returned MIRS are not involved in the merge:
      @warnings << "#{all_mirs_with_nil_badge.count} (possibly unrelated) MIRs with nil badge_id" if all_mirs_with_nil_badge.present?

      @errors << 'Identical source and destination!' if @source.id == @dest.id
      @errors << 'Conflicting categories: different CategoryTypes in same Season' unless category_compatible?
      @errors << "Gender mismatch: [#{@source.id}] #{@source.gender_type_id} |=> [#{@dest.id}] #{@dest.gender_type_id}" unless @dest.gender_type_id == @source.gender_type_id
      @errors << 'Conflicting MIR(s) found in same meeting' unless mir_compatible?
      @errors << "User mismatch (set/unset): [#{@source.id}] #{@source.associated_user_id} |=> [#{@dest.id}] #{@dest.associated_user_id}" unless @dest.associated_user_id == @source.associated_user_id

      # TODO: add seasons & badges report matrix to log
      @log += badge_analisys
      @log += mir_analisys
      @log += mrs_analisys
      # TODO: check category_type compatibility in shared season-badges

      @errors.blank?

      # TODO
      # For each involved entity:
      # 1. collect source rows
      # 2. collect destination rows
      # 3. collect "duplicate diff" from source for future duplicated rows after update
      # 4. collect "movable diff" from source rows (remainder of un-conflicting rows)
      #
      # Duplicates may have sub-entity rows which should either be reassigned
      # to existing destination master rows or be deleted when "leaf duplicates" are
      # found at the bottom of the hierarchy tree.
      #
      # For each duplicate:
      # 1. go-deep: depth search for associated entities in search of duplicates
      #    (use same bindings as [Main]strategies/solver/<entity_name> and go depth-first)

      # *** Badges ***
      # - Badge:
      #   required_keys = %i[category_type_id team_affiliation_id team_id swimmer_id season_id]

      # *** "Parent" Results ***
      # - MeetingIndividualResult:
      #   required_keys = %i[meeting_program_id swimmer_id team_id]
      #
      # - UserResult:
      #   required_keys = %i[user_workshop_id user_id swimmer_id category_type_id pool_type_id event_type_id swimming_pool_id]
      #
      # - MeetingRelaySwimmer:
      #   required_keys = %i[meeting_relay_result_id stroke_type_id swimmer_id badge_id]

      # *** "Children" Results ***
      # - Lap:
      #   required_keys = %i[meeting_individual_result_id meeting_program_id swimmer_id team_id length_in_meters]
      #
      # - UserLap:
      #   required_keys = %i[user_result_id swimmer_id length_in_meters]
      #
      # - RelayLap:
      #   required_keys = %i[meeting_relay_result_id meeting_relay_swimmer_id swimmer_id team_id length_in_meters]

      # *** "Parent" Reservations ***
      # - MeetingReservation
      # - MeetingEntry

      # *** "Children" Reservations ***
      # - MeetingEventReservation
      # - MeetingRelayReservation

      # FUTUREDEV: *** Cups & Records ***
      # - SeasonPersonalStandard: currently used only in old CSI meetings and not used nor updated anymore
      # - GoggleCupStandard: TODO
      # - IndividualRecord: TODO, missing model (but table is there, links both team & swimmer)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Creates a detailed report of the entities involved in merging the source into the destination as
    # an ASCII table for quick reference.
    def display_report
      puts badge_analisys.join("\r\n")
      # TODO: check category_type compatibility in shared season-badges
      puts mir_analisys.join("\r\n")
      puts mrs_analisys.join("\r\n")
      # TODO: UR analisys

      # TODO: Lap analisys
      # TODO: RL analisys
      # TODO: UL analisys

      # TODO Reservations, all ********************
      nil
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                                    Badge
    #-- ------------------------------------------------------------------------
    #++

    # Returns the subset of seasons in which the *source* badges are found but no destination badges are.
    # Note: the following methods are used to highlight the 3 different phases of the possible merge during the analisys report.
    def src_diff_badge_seasons
      @src_diff_badge_seasons ||= @source.seasons.to_a.delete_if { |season| @dest.seasons.include?(season) }
    end

    # Returns the subset of seasons in which the *destination* badges are found but no source badges are.
    def dest_diff_badge_seasons
      @dest_diff_badge_seasons ||= @dest.seasons.to_a.delete_if { |season| @source.seasons.include?(season) }
    end

    # Returns the subset of seasons in which both the *source* and *destination* badges are found.
    #
    # Source & destination can still be "merge-compatible" assuming the different badges in same season
    # are NOT conflicting and can be merged.
    # ("Badge compatible" => same category & team or no conflicting category even if teams are different,
    #  and definitely no conflicting results.)
    #
    # == More on shared/overlapping badges:
    #
    # Badges are considered "compatible for merge" when:
    # - NO difference in team-badges are found in each season shared between the two.
    #   (No conflicting team registrations among the same season.)
    #
    # A slight difference in swimmers naming may yield to two different badges for the two
    # merging swimmers inside the same season.
    #
    # This gives:
    # - 2 badges, same Team in same season
    #   => OK if same category, no conflicting results
    #
    # - 2 badges, different Teams in same season
    #   => Possibly *NOT* OK, merge compatible only when no conflicting results are found
    #      (same meeting, different results for the 2 different badges, regardless from the fact that the Team
    #       may or may not be a possible duplicate to be merged)
    #
    # Usually the second case is positively a red flag for non-mergeable swimmers given that by the book
    # it shouldn't be allowed to be registered with two different teams on the same championships
    # and it should NEVER occur that the same swimmer has 2 different teams in the same meeting.
    #
    def shared_badge_seasons
      @shared_badge_seasons ||= @dest.seasons.to_a.keep_if { |season| @source.seasons.include?(season) }
    end

    # Assuming <tt>season</tt> is a valid Season instance, returns a single string line
    # with a fixed size, 3 column format that can be used to display a side-by-side list Badges
    # per season comparing source & destination.
    def decorate_3column_season_src_and_dest_badges_x_season(season)
      src_team_x_season = decorate_list_of_badges(@source.badges.for_season(season))
      dest_team_x_season = decorate_list_of_badges(@dest.badges.for_season(season))
      "|#{season.id.to_s.rjust(5)} | #{src_team_x_season.join(', ').ljust(72)}| #{dest_team_x_season.join(', ').ljust(72)}|"
    end

    # Assuming <tt>list_of_badges</tt> is an array of Badges, returns the array of descriptions for all enlisted Badges.
    def decorate_list_of_badges(list_of_badges)
      list_of_badges.to_a.map { |badge| "[B #{badge.id}] T #{badge.team_id}: #{badge.team.editable_name}" }
    end
    #-- ------------------------------------------------------------------------
    #++

    # Analizes source and destination badges for conflicting *teams* (source and destination teams in same Season),
    # returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case swimmers).
    def badge_analisys
      return @badge_analisys if @badge_analisys.present?

      @badge_analisys = [
        "\r\n*** Badge analisys ***\r\n+#{''.center(154, '=')}+",
        '|Season|' + "[ #{@source.id}: #{@source.display_label} ]".center(73, ' ') + '|' + "[ #{@dest.id}: #{@dest.display_label} ]".center(73, ' ') + '|',
        "|------+#{'+'.center(147, '-')}|"
      ]

      src_diff_badge_seasons.each { |season| @badge_analisys << decorate_3column_season_src_and_dest_badges_x_season(season) }
      @badge_analisys << ("|------+#{'+'.center(147, '-')}|")

      shared_badge_seasons.each { |season| @badge_analisys << decorate_3column_season_src_and_dest_badges_x_season(season) }
      @badge_analisys << ("|------+#{'+'.center(147, '-')}|")

      dest_diff_badge_seasons.each { |season| @badge_analisys << decorate_3column_season_src_and_dest_badges_x_season(season) }
      @badge_analisys << ("+#{''.center(154, '=')}+")
      @badge_analisys
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                            MeetingIndividualResult
    #-- ------------------------------------------------------------------------
    #++

    # Returns the list of all MIR rows that have a nil Badge ID.
    def all_mirs_with_nil_badge
      return @all_mirs_with_nil_badge if @all_mirs_with_nil_badge

      @all_mirs_with_nil_badge = GogglesDb::MeetingIndividualResult.where(badge_id: nil)
    end

    # Assuming <tt>mir</tt> is a GogglesDb::MeetingIndividualResult, returns a displayble label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mir(mir)
      mir_season_id = mir.season.id
      badge = mir.badge_id ? mir.badge : GogglesDb::Badge.where(swimmer_id: mir.swimmer_id, team_id: mir.team_id, season_id: mir_season_id).first
      "[MIR #{mir.id}, Meeting #{mir.meeting.id}] swimmer_id: #{mir.swimmer_id} (#{mir.swimmer.complete_name}), team_id: #{mir.team_id}, season: #{mir_season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mir_count }</tt>.
    # Each Meeting ID is unique and grouped with its MIR count as associated value.
    # This is extracted from existing MIR rows involving the *source* swimmer and may return Meeting IDs which are shared
    # by the destination swimmer too.
    #
    # (Note: for the MIR analisys, given that legacy MIRs may have nil badges, we'll use the direct link to swimmer, team & season
    # to reconstruct what needs to be done.)
    def src_meeting_ids_from_mirs
      return @src_meeting_ids_from_mirs if @src_meeting_ids_from_mirs.present?

      @src_meeting_ids_from_mirs = GogglesDb::MeetingIndividualResult.joins(:meeting).includes(:meeting)
                                                                     .where(swimmer_id: @source.id)
                                                                     .group('meetings.id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mir_count }</tt>.
    # Each Meeting ID is unique and grouped with its MIR count as associated value.
    # This is extracted from existing MIR rows involving the *destination* swimmer and may return Meeting IDs which are shared
    # by the source swimmer too.
    def dest_meeting_ids_from_mirs
      return @dest_meeting_ids_from_mirs if @dest_meeting_ids_from_mirs.present?

      @dest_meeting_ids_from_mirs = GogglesDb::MeetingIndividualResult.joins(:meeting).includes(:meeting)
                                                                      .where(swimmer_id: @dest.id)
                                                                      .group('meetings.id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MIR rows
    # involving *both* the *source* & the *destination* swimmer.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mirs
      return @shared_meeting_ids_from_mirs if @shared_meeting_ids_from_mirs.present?

      @shared_meeting_ids_from_mirs = dest_meeting_ids_from_mirs.keep_if { |meeting_id, _mir_count| src_meeting_ids_from_mirs.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MIR counts involving *just* the *source* swimmer.
    def src_diff_meeting_ids_from_mirs
      return @src_diff_meeting_ids_from_mirs if @src_diff_meeting_ids_from_mirs.present?

      @src_diff_meeting_ids_from_mirs = src_meeting_ids_from_mirs.delete_if { |meeting_id, _mir_count| dest_meeting_ids_from_mirs.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MIR counts involving *just* the *destination* swimmer.
    def dest_diff_meeting_ids_from_mirs
      return @dest_diff_meeting_ids_from_mirs if @dest_diff_meeting_ids_from_mirs.present?

      @dest_diff_meeting_ids_from_mirs = dest_meeting_ids_from_mirs.delete_if { |meeting_id, _mir_count| src_meeting_ids_from_mirs.key?(meeting_id) }
    end
    #-- ------------------------------------------------------------------------
    #++

    # MIR are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mir_compatible?
      shared_meeting_ids_from_mirs.blank?
    end

    # Similar to Badges, Categories are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found in between shared seasons.
    #   (No conflicting categories.)
    #
    def category_compatible?
      compatible = true
      shared_badge_seasons.each do |season|
        source = @source.badges.for_season(season).map(&:category_type_id)
        dest = @dest.badges.for_season(season).map(&:category_type_id)
        compatible = (dest - source).blank?
        break if !compatible
      end
      compatible
    end
    #-- ------------------------------------------------------------------------
    #++

    # Analizes source and destination associations for conflicting MIRs (different source & destination MIRs inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case swimmers).
    def mir_analisys
      return @mir_analisys if @mir_analisys.present?

      @mir_analisys = ["\r\n*** MIR analisys ***"]

      # Check for nil Badges inside *any* MIRs, just for further clearance:
      if all_mirs_with_nil_badge.present?
        @mir_analisys << "\r\n>> WARNING: #{all_mirs_with_nil_badge.count} MIRs with nil badge_id are present:"
        all_mirs_with_nil_badge.each { |mir| @mir_analisys << "- #{decorate_mir(mir)}" }
      end

      if src_diff_meeting_ids_from_mirs.present?
        @mir_analisys << "\r\n+#{''.center(154, '=')}+"
        @mir_analisys << '|' + " SOURCE (Meeting ID, MIR count) x [#{@source.id}: #{@source.display_label}] ".center(154, ' ') + '|'
        @mir_analisys << "+#{''.center(154, '-')}+"
        @mir_analisys += src_diff_meeting_ids_from_mirs.each_slice(8).map { |line_array| line_array.map { |meeting_id, mir_count| "#{meeting_id}: #{mir_count}" }.join(', ') }
        @mir_analisys << "+#{''.center(154, '=')}+"
      else
        @mir_analisys << "\r\n>> NO source-only MIRs found."
      end

      if dest_diff_meeting_ids_from_mirs.present?
        @mir_analisys << "\r\n+#{''.center(154, '=')}+"
        @mir_analisys << '|' + " DEST (Meeting ID, MIR count) x [#{@dest.id}: #{@dest.display_label}] ".center(154, ' ') + '|'
        @mir_analisys << "+#{''.center(154, '-')}+"
        @mir_analisys += dest_diff_meeting_ids_from_mirs.each_slice(8).map { |line_array| line_array.map { |meeting_id, mir_count| "#{meeting_id}: #{mir_count}" }.join(', ') }
        @mir_analisys << "+#{''.center(154, '=')}+"
      else
        @mir_analisys << "\r\n>> NO destination-only MIRs found."
      end

      if shared_meeting_ids_from_mirs.present?
        @mir_analisys << "\r\n+#{''.center(154, '=')}+"
        @mir_analisys << '|' + " *** CONFLICTING Meeting IDs & MIR *** ".center(154, ' ') + '|'
        @mir_analisys << "+#{''.center(154, '-')}+"
        @mir_analisys += shared_meeting_ids_from_mirs.each_slice(8).map { |line_array| line_array.map{ |meeting_id, _mir_count| "#{meeting_id}"}.join(', ') }
        @mir_analisys << "+#{''.center(154, '-')}+"
        @mir_analisys << "+#{'- Conflicting MIR details: -'.center(154, ' ')}+"
        shared_meeting_ids_from_mirs.each do |meeting_id, _mir_count|
          mirs = GogglesDb::MeetingIndividualResult.joins(:meeting).includes(:meeting)
                                                   .where('(swimmer_id = ? OR swimmer_id = ?) AND (meetings.id = ?)',
                                                          @source.id, @dest.id, meeting_id)
          mirs.each { |mir| @mir_analisys << "- #{decorate_mir(mir)}" }
        end
        @mir_analisys << "+#{''.center(154, '=')}+"
      else
        @mir_analisys << "\r\n>> NO conflicting MIRs found."
      end

      @mir_analisys
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                              MeetingRelaySwimmer
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mrs_count }</tt>.
    # Each Meeting ID is unique and grouped with its MRS count as associated value.
    # This is extracted from existing MRS rows involving the *source* swimmer and may return Meeting IDs which are shared
    # by the destination swimmer too.
    #
    # (Note: for the MRS analisys, given that legacy MRSs may have nil badges, we'll use the direct link to swimmer, team & season
    # to reconstruct what needs to be done.)
    def src_meeting_ids_from_mrss
      return @src_meeting_ids_from_mrss if @src_meeting_ids_from_mrss.present?

      @src_meeting_ids_from_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting).includes(:meeting)
                                                                 .where(swimmer_id: @source.id)
                                                                 .group('meetings.id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mrs_count }</tt>.
    # Each Meeting ID is unique and grouped with its MRS count as associated value.
    # This is extracted from existing MRS rows involving the *destination* swimmer and may return Meeting IDs which are shared
    # by the source swimmer too.
    def dest_meeting_ids_from_mrss
      return @dest_meeting_ids_from_mrss if @dest_meeting_ids_from_mrss.present?

      @dest_meeting_ids_from_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting).includes(:meeting)
                                                                  .where(swimmer_id: @dest.id)
                                                                  .group('meetings.id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRS rows
    # involving *both* the *source* & the *destination* swimmer.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mrss
      return @shared_meeting_ids_from_mrss if @shared_meeting_ids_from_mrss.present?

      @shared_meeting_ids_from_mrss = dest_meeting_ids_from_mrss.keep_if { |meeting_id, _mrs_count| src_meeting_ids_from_mrss.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRS counts involving *just* the *source* swimmer.
    def src_diff_meeting_ids_from_mrss
      return @src_diff_meeting_ids_from_mrss if @src_diff_meeting_ids_from_mrss.present?

      @src_diff_meeting_ids_from_mrss = src_meeting_ids_from_mrss.delete_if { |meeting_id, _mrs_count| dest_meeting_ids_from_mrss.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRS counts involving *just* the *destination* swimmer.
    def dest_diff_meeting_ids_from_mrss
      return @dest_diff_meeting_ids_from_mrss if @dest_diff_meeting_ids_from_mrss.present?

      @dest_diff_meeting_ids_from_mrss = dest_meeting_ids_from_mrss.delete_if { |meeting_id, _mrs_count| src_meeting_ids_from_mrss.key?(meeting_id) }
    end
    #-- ------------------------------------------------------------------------
    #++

    # MRSs are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mrs_compatible?
      shared_meeting_ids_from_mrss.blank?
    end

    # Assuming <tt>mrs</tt> is a GogglesDb::MeetingRelaySwimmer, returns a displayble label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mrs(mrs)
      mrs_season_id = mrs.season.id
      badge = mrs.badge_id ? mrs.badge : GogglesDb::Badge.where(swimmer_id: mrs.swimmer_id, team_id: mrs.team_id, season_id: mrs_season_id).first
      "[MRS #{mrs.id}, Meeting #{mrs.meeting.id}] swimmer_id: #{mrs.swimmer_id} (#{mrs.swimmer.complete_name}), team_id: #{mrs.team_id}, season: #{mrs_season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end
    #-- ------------------------------------------------------------------------
    #++

    # Analizes source and destination associations for conflicting MRSs (different source & destination MRSs inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case swimmers).
    def mrs_analisys
      return @mrs_analisys if @mrs_analisys.present?

      @mrs_analisys = ["\r\n*** MRS analisys ***"]

      if src_diff_meeting_ids_from_mrss.present?
        @mrs_analisys << "\r\n+#{''.center(154, '=')}+"
        @mrs_analisys << '|' + " SOURCE (Meeting ID, MRS count) x [#{@source.id}: #{@source.display_label}] ".center(154, ' ') + '|'
        @mrs_analisys << "+#{''.center(154, '-')}+"
        @mrs_analisys += src_diff_meeting_ids_from_mrss.each_slice(8).map { |line_array| line_array.map { |meeting_id, mrs_count| "#{meeting_id}: #{mrs_count}" }.join(', ') }
        @mrs_analisys << "+#{''.center(154, '=')}+"
      else
        @mrs_analisys << "\r\n>> NO source-only MRSs found."
      end

      if dest_diff_meeting_ids_from_mrss.present?
        @mrs_analisys << "\r\n+#{''.center(154, '=')}+"
        @mrs_analisys << '|' + " DEST (Meeting ID, MRS count) x [#{@dest.id}: #{@dest.display_label}] ".center(154, ' ') + '|'
        @mrs_analisys << "+#{''.center(154, '-')}+"
        @mrs_analisys += dest_diff_meeting_ids_from_mrss.each_slice(8).map { |line_array| line_array.map { |meeting_id, mrs_count| "#{meeting_id}: #{mrs_count}" }.join(', ') }
        @mrs_analisys << "+#{''.center(154, '=')}+"
      else
        @mrs_analisys << "\r\n>> NO destination-only MRSs found."
      end

      if shared_meeting_ids_from_mrss.present?
        @mrs_analisys << "\r\n+#{''.center(154, '=')}+"
        @mrs_analisys << '|' + " *** CONFLICTING Meeting IDs & MRS *** ".center(154, ' ') + '|'
        @mrs_analisys << "+#{''.center(154, '-')}+"
        @mrs_analisys += shared_meeting_ids_from_mrss.each_slice(8).map { |line_array| line_array.map{ |meeting_id, _mrs_count| "#{meeting_id}"}.join(', ') }
        @mrs_analisys << "+#{''.center(154, '-')}+"
        @mrs_analisys << "+#{'- Conflicting MRS details: -'.center(154, ' ')}+"
        shared_meeting_ids_from_mrss.each_key do |meeting_id|
          mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting).includes(:meeting)
                                               .where('(swimmer_id = ? OR swimmer_id = ?) AND (meetings.id = ?)',
                                                      @source.id, @dest.id, meeting_id)
          mrss.each { |mrs| @mrs_analisys << "- #{decorate_mrs(mrs)}" }
        end
        @mrs_analisys << "+#{''.center(154, '=')}+"
      else
        @mrs_analisys << "\r\n>> NO conflicting MRSs found."
      end

      @mrs_analisys
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
