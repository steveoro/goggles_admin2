# frozen_string_literal: true

module Merge
  # = Merge::TeamChecker
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20241010
  #
  # Service class delegated to check the feasibility of merge operation between two
  # Team instances: a source/slave row into a destination/master one.
  #
  # As a bonus, this class collects the processable entities involved in the merge.
  #
  # If the analysis reports that the merge is indeed feasible, the merge itself can
  # be carried out by an instance of Merge::Team.
  #
  # === FAILURE = DON'T MERGE, whenever:
  # SAME SEASON, DIFFERENT AFFILIATION, DIFFERENT TEAM/BADGE:
  # - two teams belong to different teams in the same season;
  #   => merge the two teams first, only if possible and the teams actually need to be merged.
  #
  # SAME SEASON, DIFFERENT AFFILIATION, DIFFERENT CONFLICTING RESULTS:
  # - two teams belong to different teams in the same season with MIRs found inside same Meeting;
  #   => merge only if MIR are complementary and Teams can be merged, but merge the two teams first (as above).
  #      (may happen when running data-import from a parsed PDF result file over an existing Meeting)
  #
  # SAME AFFILIATION, DIFFERENT OVERLAPPING DETAILS:
  # - two teams belong to the same team but have different detail results linked
  #   to the same day/event/meeting (the detail data can overlap) and be considered
  #   a "deletable duplicate" only if equal in almost every column, except for the
  #   team_id.
  #
  # === SUCCESS = CAN MERGE, whenever:
  # DIFFERENT SEASON (= DIFFERENT AFFILIATION):
  # - the two teams do not have overlapping details
  #
  # SAME TEAM, COMPATIBLE DETAILS:
  # - the two teams belong ultimately to the same team or group of affiliations but do not have
  #   overlapping detail data linked to them conflicting with each other (e.g. every result found belongs
  #   to a different meeting program when compared to the destination details, or when there
  #   are overlapping rows, these are indeed equalities, thus deletable duplicates).
  #
  class TeamChecker # rubocop:disable Metrics/ClassLength
    attr_reader :log, :errors, :warnings, :source, :dest,
                :src_only_badges, :shared_badges, :src_only_mirs,
                :src_only_mes, :src_only_mev_res, :src_only_mrel_res,
                :src_only_mrss, :src_only_relay_laps, :src_only_mres,
                :src_only_laps, :src_only_user_laps, :src_only_urs,
                :src_only_irs

    # Checks Team merge feasibility while collecting all involved entity IDs.
    #
    # == Attributes:
    # - <tt>#log</tt> => analysis log (array of string lines)
    # - <tt>#errors</tt> => error messages (array of string messages)
    # - <tt>#warnings</tt> => warning messages (array of string messages)
    #
    # == Params:
    # - <tt>:source</tt> => source Team row, *required*
    # - <tt>:dest</tt> => destination Team row, *required*
    #
    def initialize(source:, dest:)
      raise(ArgumentError, 'Both source and destination must be Teams!') unless source.is_a?(GogglesDb::Team) && dest.is_a?(GogglesDb::Team)

      @source = source.decorate
      @dest = dest.decorate
      @log = []
      @errors = []
      @warnings = []

      # Src badge_ids to be updated with team_id (leave sub-entities untouched):
      @src_only_badges = []
      # Deletable src badges (keys) after sub-entity reassignment to dest badges (values):
      @shared_badges = {} # format: { src_badge_id => dest_badge_id }
      # (The "shared badges" is the only case that is currently handled automatically; any other shared
      # entity implies the check failure and requires manual SQL creation.)

      # Entities implied in a badge IDs update (+ team_id):
      # meeting_entries, meeting_event_reservations, meeting_individual_results,
      # meeting_relay_reservations, meeting_relay_teams, meeting_reservations

      @src_only_mes = []        # meeting_entries
      @src_only_mev_res = []    # meeting_event_reservations
      @src_only_mirs = []       # meeting_individual_results
      @src_only_mrel_res = []   # meeting_relay_reservations
      @src_only_mrss = []       # meeting_relay_teams
      @src_only_relay_laps = [] # relay_laps
      @src_only_mres = []       # meeting_reservations

      # Updating just the team_id:
      # laps (+MIR), IR (+MIR), relay_laps (+MRS),
      # user_laps, user_results, users (+ any other legacy tables [FUTUREDEV])

      @src_only_laps = []
      @src_only_user_laps = []
      @src_only_urs = []

      # IR are considered "always compatible" so we collect directly the IDs for the merge:
      @src_only_irs = GogglesDb::IndividualRecord.where(team_id: @source.id).map(&:id)
      # (IR will have overlapping MIRs only in case of data-integrity violations -- see analysis)

      # (Users updated w/o array)

      # FUTUREDEV: (currently not used)
      # - badge_payments (badge_id)
      # - team_season_scores (badge_id)
      # *** Cups ***
      # - SeasonPersonalStandard: (season_personal_standards => team_id, season_id)
      #   (currently used only in old CSI meetings and not used nor updated anymore)
      # - GoggleCupStandard: TODO, missing model (but table is there; links: team_id, goggle_cup_id)
    end
    #-- ------------------------------------------------------------------------
    #++

    # Launches the analysis process for merge feasibility.
    # *This process does not alter the database.*
    #
    # Returns +true+ if the merge seems feasible, +false+ otherwise.
    # Check the #log & #errors members for details and error messages.
    def run # rubocop:disable Metrics/AbcSize
      @log << "\r\n[src: '#{@source.complete_name}', id #{@source.id}] |=> [dest: '#{@dest.complete_name}', id #{@dest.id}]"
      @source_badges = GogglesDb::BadgeDecorator.decorate_collection(@source.badges)
      @dest_badges = GogglesDb::BadgeDecorator.decorate_collection(@dest.badges)

      @warnings << 'Overlapping badges: different Badges in same Season' if shared_badge_seasons.present?
      # This is always relevant even if the returned MIRS are not involved in the merge:
      @warnings << "#{all_mirs_with_nil_badge.count} (possibly unrelated) MIRs with nil badge_id" if all_mirs_with_nil_badge.present?

      if all_irs_with_conflicting_data.present?
        @warnings << "#{all_irs_with_conflicting_data.count} (possibly unrelated) IRs with *CONFLICTING* team_id or team_id"
      end

      @errors << 'Identical source and destination!' if @source.id == @dest.id
      @errors << 'Conflicting categories: different CategoryTypes in same Season' unless category_compatible?
      unless @dest.gender_type_id == @source.gender_type_id
        @errors << "Gender mismatch: [#{@source.id}] #{@source.gender_type_id} |=> [#{@dest.id}] #{@dest.gender_type_id}"
      end
      @errors << 'Conflicting MIR(s) found in same meeting' unless mir_compatible?
      unless @dest.associated_user_id == @source.associated_user_id
        @errors << "User mismatch (set/unset): [#{@source.id}] #{@source.associated_user_id} |=> [#{@dest.id}] #{@dest.associated_user_id}"
      end

      @log += badge_analysis
      @log += mir_analysis
      @log += lap_analysis

      @log += mrs_analysis
      @log += relay_lap_analysis

      @log += ur_analysis
      @log += user_lap_analysis

      @log += mres_analysis
      @log += mev_res_analysis
      @log += mrel_res_analysis

      @log += mes_analysis
      @log += ir_analysis

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
      puts("\r\n\r\n*** WARNINGS: ***\r\n#{@warnings.join("\r\n")}") if @warnings.present?
      puts("\r\n\r\n*** ERRORS: ***\r\n#{@errors.join("\r\n")}") if @errors.present?
      puts("\r\n")
      puts(@errors.blank? ? 'RESULT: ✅' : 'RESULT: ❌')
      nil
    end
    # rubocop:enable Rails/Output
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                                    Badge
    #-- ------------------------------------------------------------------------
    #++

    # Returns the subset of seasons in which the *source* badges are found but no destination badges are.
    # Note: the following methods are used to highlight the 3 different phases of the possible merge during the analysis report.
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
    # A slight difference in teams naming may yield to two different badges for the two
    # merging teams inside the same season.
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
    # Usually the second case is positively a red flag for non-mergeable teams given that by the book
    # it shouldn't be allowed to be registered with two different teams on the same championships
    # and it should NEVER occur that the same team has 2 different teams in the same meeting.
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

    # Analizes source and destination badges for conflicting *teams* (source and destination teams in same Season),
    # returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case teams).
    def badge_analysis # rubocop:disable Metrics/AbcSize
      return @badge_analysis if @badge_analysis.present?

      @badge_analysis = [
        prepare_section_title('BADGE'),
        "+------+#{'+'.center(147, '-')}+",
        "|Season|#{"[ #{@source.id}: #{@source.display_label} ]".center(73, ' ')}|#{"[ #{@dest.id}: #{@dest.display_label} ]".center(73, ' ')}|",
        "|------+#{'+'.center(147, '-')}|"
      ]
      @src_only_badges += @source.badges.where(season_id: src_diff_badge_seasons.map(&:id))
                                 .map(&:id)

      src_diff_badge_seasons.each { |season| @badge_analysis << decorate_3column_season_src_and_dest_badges_x_season(season) }
      @badge_analysis << ("|------+#{'+'.center(147, '-')}|")

      shared_badge_seasons.each { |season| @badge_analysis << decorate_3column_season_src_and_dest_badges_x_season(season) }
      @badge_analysis << ("|------+#{'+'.center(147, '-')}|")

      # Prepare a map of the shared destination badges:
      # (all shared source badges shall become a destination badge)
      src_badges = @source.badges.where(season_id: shared_badge_seasons.map(&:id)).map(&:id)
      dest_badges = @dest.badges.where(season_id: shared_badge_seasons.map(&:id)).map(&:id)
      src_badges.each_with_index { |k, idx| @shared_badges.merge!(k => dest_badges[idx]) }

      dest_diff_badge_seasons.each { |season| @badge_analysis << decorate_3column_season_src_and_dest_badges_x_season(season) }
      @badge_analysis << ("+#{''.center(154, '-')}+")
      @badge_analysis
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
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mir_count }</tt>.
    # Each Meeting ID is unique and grouped with its MIR count as associated value.
    # This is extracted from existing MIR rows involving the *source* team and may return Meeting IDs which are shared
    # by the destination team too.
    #
    # (Note: for the MIR analysis, given that legacy MIRs may have nil badges, we'll use the direct link to team, team & season
    # to reconstruct what needs to be done.)
    def src_meeting_ids_from_mirs
      return @src_meeting_ids_from_mirs if @src_meeting_ids_from_mirs.present?

      @src_meeting_ids_from_mirs = GogglesDb::MeetingIndividualResult.joins(:meeting).includes(:meeting)
                                                                     .where(team_id: @source.id)
                                                                     .group('meetings.id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mir_count }</tt>.
    # Each Meeting ID is unique and grouped with its MIR count as associated value.
    # This is extracted from existing MIR rows involving the *destination* team and may return Meeting IDs which are shared
    # by the source team too.
    def dest_meeting_ids_from_mirs
      return @dest_meeting_ids_from_mirs if @dest_meeting_ids_from_mirs.present?

      @dest_meeting_ids_from_mirs = GogglesDb::MeetingIndividualResult.joins(:meeting).includes(:meeting)
                                                                      .where(team_id: @dest.id)
                                                                      .group('meetings.id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MIR rows
    # involving *both* the *source* & the *destination* team.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mirs
      return @shared_meeting_ids_from_mirs if @shared_meeting_ids_from_mirs.present?

      @shared_meeting_ids_from_mirs = dest_meeting_ids_from_mirs.dup.keep_if { |meeting_id, _mir_count| src_meeting_ids_from_mirs.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MIR counts involving *just* the *source* team.
    def src_diff_meeting_ids_from_mirs
      return @src_diff_meeting_ids_from_mirs if @src_diff_meeting_ids_from_mirs.present?

      @src_diff_meeting_ids_from_mirs = src_meeting_ids_from_mirs.dup.delete_if { |meeting_id, _mir_count| dest_meeting_ids_from_mirs.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MIR counts involving *just* the *destination* team.
    def dest_diff_meeting_ids_from_mirs
      return @dest_diff_meeting_ids_from_mirs if @dest_diff_meeting_ids_from_mirs.present?

      @dest_diff_meeting_ids_from_mirs = dest_meeting_ids_from_mirs.dup.delete_if { |meeting_id, _mir_count| src_meeting_ids_from_mirs.key?(meeting_id) }
    end

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
        break unless compatible
      end
      compatible
    end

    # Assuming <tt>mir</tt> is a GogglesDb::MeetingIndividualResult, returns a displayable label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mir(mir)
      mir_season_id = mir.season.id
      badge = mir.badge_id ? mir.badge : GogglesDb::Badge.where(team_id: mir.team_id, team_id: mir.team_id, season_id: mir_season_id).first
      "[MIR #{mir.id}, Meeting #{mir.meeting.id}] team_id: #{mir.team_id} (#{mir.team.complete_name}), team_id: #{mir.team_id}, season: #{mir_season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end

    # Analizes source and destination associations for conflicting MIRs (different source & destination MIRs inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case teams).
    def mir_analysis
      return @mir_analysis if @mir_analysis.present?

      @src_only_mirs += GogglesDb::MeetingIndividualResult.joins(:meeting)
                                                          .where(
                                                            team_id: @source.id,
                                                            'meetings.id': src_diff_meeting_ids_from_mirs.keys
                                                          ).map(&:id)
      @mir_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingIndividualResult.joins(:meeting).includes(:meeting),
        target_decorator: :decorate_mir,
        where_condition: '(meeting_individual_results.team_id = ? OR meeting_individual_results.team_id = ?) AND (meetings.id IN (?))',
        src_list: src_diff_meeting_ids_from_mirs,
        shared_list: shared_meeting_ids_from_mirs,
        dest_list: dest_diff_meeting_ids_from_mirs,
        result_title: 'MIR',
        subj_tuple_title: '(Meeting ID, MIR count)'
      )

      # Check for nil Badges inside *any* MIRs, just for further clearance:
      if all_mirs_with_nil_badge.present?
        @mir_analysis << "\r\n>> WARNING: #{all_mirs_with_nil_badge.count} MIRs with nil badge_id are present:"
        all_mirs_with_nil_badge.each { |mir| @mir_analysis << "- #{decorate_mir(mir)}" }
      end

      @mir_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                                     Lap
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items for the source Team, each one having the format <tt>{ mir_id => lap_count }</tt>.
    def src_mir_ids_with_laps
      return @src_mir_ids_with_laps if @src_mir_ids_with_laps.present?

      @src_mir_ids_with_laps = GogglesDb::Lap.where(team_id: @source.id)
                                             .joins(:meeting_individual_result)
                                             .includes(:meeting_individual_result)
                                             .group('laps.meeting_individual_result_id').count
    end

    # Returns an array of Hash items for the dest Team, each one having the format <tt>{ mir_id => lap_count }</tt>.
    def dest_mir_ids_with_laps
      return @dest_mir_ids_with_laps if @dest_mir_ids_with_laps.present?

      @dest_mir_ids_with_laps = GogglesDb::Lap.where(team_id: @dest.id)
                                              .joins(:meeting_individual_result)
                                              .includes(:meeting_individual_result)
                                              .group('laps.meeting_individual_result_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* MIR IDs extracted from Lap rows
    # involving *both* the *source* & the *destination* team.
    def shared_mir_ids_from_laps
      return @shared_mir_ids_from_laps if @shared_mir_ids_from_laps.present?

      @shared_mir_ids_from_laps = dest_mir_ids_with_laps.dup.keep_if { |mir_id, _count| src_mir_ids_with_laps.key?(mir_id) }
    end

    # Returns the difference array of unique MIR IDs & Lap counts involving *just* the *source* team.
    def src_diff_mir_ids_with_laps
      return @src_diff_mir_ids_with_laps if @src_diff_mir_ids_with_laps.present?

      @src_diff_mir_ids_with_laps = src_mir_ids_with_laps.dup.delete_if { |mir_id, _count| dest_mir_ids_with_laps.key?(mir_id) }
    end

    # Returns the difference array of unique MIR IDs & Lap counts involving *just* the *destination* team.
    def dest_diff_mir_ids_with_laps
      return @dest_diff_mir_ids_with_laps if @dest_diff_mir_ids_with_laps.present?

      @dest_diff_mir_ids_with_laps = dest_mir_ids_with_laps.dup.delete_if { |mir_id, _count| src_mir_ids_with_laps.key?(mir_id) }
    end

    # Laps are considered "compatible for merge" when no rows are shared with the same MIRs.
    # This can only happen if for some reason data integrity has been violated and a MIR from either
    # source or dest was assigned to a Lap set the other team.
    def lap_compatible?
      shared_mir_ids_from_laps.blank?
    end

    # Assumes +lap+ is a valid Lap instance.
    def decorate_lap(lap)
      "[Lap #{lap.id}] MIR #{lap.meeting_individual_result_id}"
    end

    # Analizes source and destination Laps, enlisting all IDs.
    # Table width: 156 character columns (tested with some edge-case teams).
    def lap_analysis
      return @lap_analysis if @lap_analysis.present?

      @src_only_laps += GogglesDb::Lap.where(team_id: @source.id, meeting_individual_result_id: src_diff_mir_ids_with_laps.keys)
                                      .map(&:id)

      @lap_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::Lap,
        target_decorator: :decorate_lap,
        where_condition: '(laps.team_id = ? OR laps.team_id = ?) AND (laps.meeting_individual_result_id IN (?))',
        src_list: src_diff_mir_ids_with_laps,
        shared_list: shared_mir_ids_from_laps,
        dest_list: dest_diff_mir_ids_with_laps,
        result_title: 'LAP',
        subj_tuple_title: '(MIR ID, LAP count)'
      )

      @lap_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                               IndividualRecord
    #-- ------------------------------------------------------------------------
    #++

    # Returns the list of all MIR rows that have a nil Badge ID.
    def all_irs_with_conflicting_data
      return @all_irs_with_conflicting_data if @all_irs_with_conflicting_data

      @all_irs_with_conflicting_data = GogglesDb::IndividualRecord.joins(:meeting_individual_result)
                                                                  .includes(:meeting_individual_result)
                                                                  .where(
                                                                    '(meeting_individual_results.team_id != individual_records.team_id) OR ' \
                                                                    '(meeting_individual_results.team_id != individual_records.team_id)'
                                                                  )
    end
    #-- ------------------------------------------------------------------------
    #++

    # Laps are considered "compatible for merge" when no rows are shared with the same MIRs.
    # This can only happen if for some reason data integrity has been violated and a MIR from either
    # source or dest was assigned to a Lap set the other team.
    def ir_compatible?
      all_irs_with_conflicting_data.blank?
    end

    # Assumes +ir+ is a valid IndividualRecord instance.
    def decorate_ir(ir) # rubocop:disable Metrics/AbcSize
      "[IR  #{ir.id.to_s.rjust(7)}] Team ID #{ir.team_id.to_s.rjust(7)}) #{ir&.team&.complete_name} #{ir&.team&.year_of_birth}, Team ID #{ir.team_id}) #{ir&.team&.name}\r\n  " \
        "[MIR #{ir.meeting_individual_result_id.to_s.rjust(7)}] Team ID #{ir&.meeting_individual_result&.team_id.to_s.rjust(7)}) " \
        "#{ir&.meeting_individual_result&.team&.complete_name} #{ir&.meeting_individual_result&.team&.year_of_birth}, " \
        "Team ID #{ir&.meeting_individual_result&.team_id}) #{ir&.meeting_individual_result&.team&.name}\r\n"
    end

    # Analizes source and destination IRs, enlisting any confliting IR ids.
    def ir_analysis
      return @ir_analysis if @ir_analysis.present?

      # Check for conflicting data inside *any* IRs since any conflicting team_id or team_id
      # (difference between IR & linked MIR) may be a red flag for future merges or even data integrity
      # failure:
      if all_irs_with_conflicting_data.present?
        @ir_analysis = ["\r\n>> WARNING: #{all_irs_with_conflicting_data.count} IRs with *CONFLICTING* team_id or team_id are present:"]
        all_irs_with_conflicting_data.each { |ir| @ir_analysis << "- #{decorate_ir(ir)}" }
      end

      @ir_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                              MeetingRelayTeam
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mrs_count }</tt>.
    # Each Meeting ID is unique and grouped with its MRS count as associated value.
    # This is extracted from existing MRS rows involving the *source* team and may return Meeting IDs which are shared
    # by the destination team too.
    #
    # (Note: for the MRS analysis, given that legacy MRSs may have nil badges, we'll use the direct link to team, team & season
    # to reconstruct what needs to be done.)
    def src_meeting_ids_from_mrss
      return @src_meeting_ids_from_mrss if @src_meeting_ids_from_mrss.present?

      @src_meeting_ids_from_mrss = GogglesDb::MeetingRelayTeam.joins(:meeting).includes(:meeting)
                                                                 .where(team_id: @source.id)
                                                                 .group('meetings.id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mrs_count }</tt>.
    # Each Meeting ID is unique and grouped with its MRS count as associated value.
    # This is extracted from existing MRS rows involving the *destination* team and may return Meeting IDs which are shared
    # by the source team too.
    def dest_meeting_ids_from_mrss
      return @dest_meeting_ids_from_mrss if @dest_meeting_ids_from_mrss.present?

      @dest_meeting_ids_from_mrss = GogglesDb::MeetingRelayTeam.joins(:meeting).includes(:meeting)
                                                                  .where(team_id: @dest.id)
                                                                  .group('meetings.id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRS rows
    # involving *both* the *source* & the *destination* team.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mrss
      return @shared_meeting_ids_from_mrss if @shared_meeting_ids_from_mrss.present?

      @shared_meeting_ids_from_mrss = dest_meeting_ids_from_mrss.dup.keep_if { |meeting_id, _mrs_count| src_meeting_ids_from_mrss.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRS counts involving *just* the *source* team.
    def src_diff_meeting_ids_from_mrss
      return @src_diff_meeting_ids_from_mrss if @src_diff_meeting_ids_from_mrss.present?

      @src_diff_meeting_ids_from_mrss = src_meeting_ids_from_mrss.dup.delete_if { |meeting_id, _mrs_count| dest_meeting_ids_from_mrss.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRS counts involving *just* the *destination* team.
    def dest_diff_meeting_ids_from_mrss
      return @dest_diff_meeting_ids_from_mrss if @dest_diff_meeting_ids_from_mrss.present?

      @dest_diff_meeting_ids_from_mrss = dest_meeting_ids_from_mrss.dup.delete_if { |meeting_id, _mrs_count| src_meeting_ids_from_mrss.key?(meeting_id) }
    end

    # MRSs are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mrs_compatible?
      shared_meeting_ids_from_mrss.blank?
    end

    # Assuming <tt>mrs</tt> is a GogglesDb::MeetingRelayTeam, returns a displayable label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mrs(mrs)
      mrs_season_id = mrs.season.id
      badge = mrs.badge_id ? mrs.badge : GogglesDb::Badge.where(team_id: mrs.team_id, team_id: mrs.team_id, season_id: mrs_season_id).first
      "[MRS #{mrs.id}, Meeting #{mrs.meeting.id}] team_id: #{mrs.team_id} (#{mrs.team.complete_name}), team_id: #{mrs.team_id}, season: #{mrs_season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end

    # Analizes source and destination associations for conflicting MRSs (different source & destination MRSs inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    # Table width: 156 character columns (tested with some edge-case teams).
    def mrs_analysis
      return @mrs_analysis if @mrs_analysis.present?

      @src_only_mrss += GogglesDb::MeetingRelayTeam.joins(:meeting)
                                                      .where(
                                                        team_id: @source.id,
                                                        'meetings.id': src_diff_meeting_ids_from_mrss.keys
                                                      ).map(&:id)
      @mrs_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingRelayTeam.joins(:meeting).includes(:meeting),
        target_decorator: :decorate_mrs,
        where_condition: '(meeting_relay_teams.team_id = ? OR meeting_relay_teams.team_id = ?) AND (meetings.id IN (?))',
        src_list: src_diff_meeting_ids_from_mrss,
        shared_list: shared_meeting_ids_from_mrss,
        dest_list: dest_diff_meeting_ids_from_mrss,
        result_title: 'MRS',
        subj_tuple_title: '(Meeting ID, MRS count)'
      )

      @mrs_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                                   RelayLap
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items for the source Team, each one having the format <tt>{ mrs_id => relay_lap_count }</tt>.
    def src_mrs_ids_with_relay_laps
      return @src_mrs_ids_with_relay_laps if @src_mrs_ids_with_relay_laps.present?

      @src_mrs_ids_with_relay_laps = GogglesDb::RelayLap.where(team_id: @source.id)
                                                        .joins(:meeting_relay_team)
                                                        .includes(:meeting_relay_team)
                                                        .group('relay_laps.meeting_relay_team_id').count
    end

    # Returns an array of Hash items for the dest Team, each one having the format <tt>{ mrs_id => relay_lap_count }</tt>.
    def dest_mrs_ids_with_relay_laps
      return @dest_mrs_ids_with_relay_laps if @dest_mrs_ids_with_relay_laps.present?

      @dest_mrs_ids_with_relay_laps = GogglesDb::RelayLap.where(team_id: @dest.id)
                                                         .joins(:meeting_relay_team)
                                                         .includes(:meeting_relay_team)
                                                         .group('relay_laps.meeting_relay_team_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* MRS IDs extracted from RelayLap rows
    # involving *both* the *source* & the *destination* team.
    def shared_mrs_ids_from_relay_laps
      return @shared_mrs_ids_from_relay_laps if @shared_mrs_ids_from_relay_laps.present?

      @shared_mrs_ids_from_relay_laps = dest_mrs_ids_with_relay_laps.dup.keep_if { |mrs_id, _count| src_mrs_ids_with_relay_laps.key?(mrs_id) }
    end

    # Returns the difference array of unique MRS IDs & RelayLap counts involving *just* the *source* team.
    def src_diff_mrs_ids_with_relay_laps
      return @src_diff_mrs_ids_with_relay_laps if @src_diff_mrs_ids_with_relay_laps.present?

      @src_diff_mrs_ids_with_relay_laps = src_mrs_ids_with_relay_laps.dup.delete_if { |mrs_id, _count| dest_mrs_ids_with_relay_laps.key?(mrs_id) }
    end

    # Returns the difference array of unique MRS IDs & RelayLap counts involving *just* the *destination* team.
    def dest_diff_mrs_ids_with_relay_laps
      return @dest_diff_mrs_ids_with_relay_laps if @dest_diff_mrs_ids_with_relay_laps.present?

      @dest_diff_mrs_ids_with_relay_laps = dest_mrs_ids_with_relay_laps.dup.delete_if { |mrs_id, _count| src_mrs_ids_with_relay_laps.key?(mrs_id) }
    end

    # RelayLaps are considered "compatible for merge" when no rows are shared with the same MRSs.
    # This can only happen if for some reason data integrity has been violated and a MRS from either
    # source or dest was assigned to a RelayLap set the other team.
    def relay_lap_compatible?
      shared_mrs_ids_from_relay_laps.blank?
    end

    # Assumes +relay_lap+ is a valid RelayLap instance.
    def decorate_relay_lap(relay_lap)
      "[RelayLap #{relay_lap.id}] MRS #{relay_lap.meeting_relay_team_id}"
    end

    # Analizes source and destination RelayLaps, enlisting all IDs.
    # Table width: 156 character columns (tested with some edge-case teams).
    def relay_lap_analysis
      return @relay_lap_analysis if @relay_lap_analysis.present?

      @src_only_relay_laps += GogglesDb::RelayLap.where(team_id: @source.id, meeting_relay_team_id: src_diff_mrs_ids_with_relay_laps.keys)
                                                 .map(&:id)
      @relay_lap_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::RelayLap,
        target_decorator: :decorate_relay_lap,
        where_condition: '(relay_laps.team_id = ? OR relay_laps.team_id = ?) AND (relay_laps.meeting_relay_team_id IN (?))',
        src_list: src_diff_mrs_ids_with_relay_laps,
        shared_list: shared_mrs_ids_from_relay_laps,
        dest_list: dest_diff_mrs_ids_with_relay_laps,
        result_title: 'RELAY_LAP',
        subj_tuple_title: '(MRS ID, RELAY_LAP count)'
      )

      @relay_lap_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                                UserResult
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ user_workshop_id => ur_count }</tt>
    # mapped from *source* team UserResults.
    # Each UserWorkshop ID is unique and grouped with its UR count as associated value.
    def src_workshop_ids_from_urs
      return @src_workshop_ids_from_urs if @src_workshop_ids_from_urs.present?

      @src_workshop_ids_from_urs = GogglesDb::UserResult.joins(:user_workshop).includes(:user_workshop)
                                                        .where(team_id: @source.id)
                                                        .group('user_workshops.id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ user_workshop_id => ur_count }</tt>
    # mapped from *destination* team UserResults.
    # Each UserWorkshop ID is unique and grouped with its UR count as associated value.
    def dest_workshop_ids_from_urs
      return @dest_workshop_ids_from_urs if @dest_workshop_ids_from_urs.present?

      @dest_workshop_ids_from_urs = GogglesDb::UserResult.joins(:user_workshop).includes(:user_workshop)
                                                         .where(team_id: @dest.id)
                                                         .group('user_workshops.id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* UserWorkshop IDs extracted from UR rows
    # involving *both* the *source* & the *destination* team.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_workshop_ids_from_urs
      return @shared_workshop_ids_from_urs if @shared_workshop_ids_from_urs.present?

      @shared_workshop_ids_from_urs = dest_workshop_ids_from_urs.dup.keep_if { |workshop_id, _count| src_workshop_ids_from_urs.key?(workshop_id) }
    end

    # Returns the difference array of unique UserWorkshop IDs & UR counts involving *just* the *source* team.
    def src_diff_workshop_ids_from_urs
      return @src_diff_workshop_ids_from_urs if @src_diff_workshop_ids_from_urs.present?

      @src_diff_workshop_ids_from_urs = src_workshop_ids_from_urs.dup.delete_if { |workshop_id, _count| dest_workshop_ids_from_urs.key?(workshop_id) }
    end

    # Returns the difference array of unique UserWorkshop IDs & UR counts involving *just* the *destination* team.
    def dest_diff_workshop_ids_from_urs
      return @dest_diff_workshop_ids_from_urs if @dest_diff_workshop_ids_from_urs.present?

      @dest_diff_workshop_ids_from_urs = dest_workshop_ids_from_urs.dup.delete_if { |workshop_id, _count| src_workshop_ids_from_urs.key?(workshop_id) }
    end

    # UR are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def ur_compatible?
      shared_workshop_ids_from_urs.blank?
    end

    # Assuming <tt>ur</tt> is a GogglesDb::UserResult, returns a displayable label for the row.
    def decorate_ur(ur)
      ur_season_id = ur.season.id
      "[UR #{ur.id}, UserWorkshop #{ur.user_workshop_id}] team_id: #{ur.team_id} (#{ur.team.complete_name}) category_type_id: #{ur.category_type_id}, season: #{ur_season_id}"
    end

    # Analizes source and destination associations for conflicting URs (different source & destination row inside same workshop),
    # returning an array of printable lines as an ASCII table for quick reference.
    def ur_analysis
      return @ur_analysis if @ur_analysis.present?

      @src_only_urs += GogglesDb::UserResult.where(team_id: @source.id, user_workshop_id: src_diff_workshop_ids_from_urs.keys)
                                            .map(&:id)
      @ur_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::UserResult,
        target_decorator: :decorate_ur,
        where_condition: '(user_results.team_id = ? OR user_results.team_id = ?) AND (user_results.user_workshop_id IN (?))',
        src_list: src_diff_workshop_ids_from_urs,
        shared_list: shared_workshop_ids_from_urs,
        dest_list: dest_diff_workshop_ids_from_urs,
        result_title: 'UR',
        subj_tuple_title: '(UserWorkshop ID, UR count)'
      )

      @ur_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                                   UserLap
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items for the source Team, each one having the format <tt>{ ur_id => user_lap_count }</tt>.
    def src_ur_ids_with_user_laps
      return @src_ur_ids_with_user_laps if @src_ur_ids_with_user_laps.present?

      @src_ur_ids_with_user_laps = GogglesDb::UserLap.where(team_id: @source.id)
                                                     .joins(:user_result)
                                                     .includes(:user_result)
                                                     .group('user_laps.user_result_id').count
    end

    # Returns an array of Hash items for the dest Team, each one having the format <tt>{ ur_id => user_lap_count }</tt>.
    def dest_ur_ids_with_user_laps
      return @dest_ur_ids_with_user_laps if @dest_ur_ids_with_user_laps.present?

      @dest_ur_ids_with_user_laps = GogglesDb::UserLap.where(team_id: @dest.id)
                                                      .joins(:user_result)
                                                      .includes(:user_result)
                                                      .group('user_laps.user_result_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* UR IDs extracted from UserLap rows
    # involving *both* the *source* & the *destination* team.
    def shared_ur_ids_from_user_laps
      return @shared_ur_ids_from_user_laps if @shared_ur_ids_from_user_laps.present?

      @shared_ur_ids_from_user_laps = dest_ur_ids_with_user_laps.dup.keep_if { |ur_id, _count| src_ur_ids_with_user_laps.key?(ur_id) }
    end

    # Returns the difference array of unique UR IDs & UserLap counts involving *just* the *source* team.
    def src_diff_ur_ids_with_user_laps
      return @src_diff_ur_ids_with_user_laps if @src_diff_ur_ids_with_user_laps.present?

      @src_diff_ur_ids_with_user_laps = src_ur_ids_with_user_laps.dup.delete_if { |ur_id, _count| dest_ur_ids_with_user_laps.key?(ur_id) }
    end

    # Returns the difference array of unique UR IDs & UserLap counts involving *just* the *destination* team.
    def dest_diff_ur_ids_with_user_laps
      return @dest_diff_ur_ids_with_user_laps if @dest_diff_ur_ids_with_user_laps.present?

      @dest_diff_ur_ids_with_user_laps = dest_ur_ids_with_user_laps.dup.delete_if { |ur_id, _count| src_ur_ids_with_user_laps.key?(ur_id) }
    end

    # Laps are considered "compatible for merge" when no rows are shared with the same URs.
    def user_lap_compatible?
      shared_ur_ids_from_user_laps.blank?
    end

    # Assumes +user_lap+ is a valid Lap instance.
    def decorate_user_lap(user_lap)
      "[UserLap #{user_lap.id}] UR #{user_lap.user_result_id}"
    end

    # Analizes source and destination UserLaps, enlisting all IDs.
    # Table width: 156 character columns (tested with some edge-case teams).
    def user_lap_analysis
      return @user_lap_analysis if @user_lap_analysis.present?

      @src_only_user_laps += GogglesDb::UserResult.where(team_id: @source.id, user_result_id: src_diff_ur_ids_with_user_laps.keys)
                                                  .map(&:id)
      @user_lap_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::UserLap,
        target_decorator: :decorate_user_lap,
        where_condition: '(user_laps.team_id = ? OR user_laps.team_id = ?) AND (user_laps.user_result_id IN (?))',
        src_list: src_diff_ur_ids_with_user_laps,
        shared_list: shared_ur_ids_from_user_laps,
        dest_list: dest_diff_ur_ids_with_user_laps,
        result_title: 'USER_LAP',
        subj_tuple_title: '(UR ID, USER_LAP count)'
      )

      @user_lap_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                               MeetingReservation
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mres_count }</tt>
    # mapped from *source* team MeetingReservation.
    # Each Meeting ID is unique and grouped with its MRes count as associated value.
    def src_meeting_ids_from_mres
      return @src_meeting_ids_from_mres if @src_meeting_ids_from_mres.present?

      @src_meeting_ids_from_mres = GogglesDb::MeetingReservation.where(team_id: @source.id)
                                                                .group('meeting_id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mres_count }</tt>
    # mapped from *destination* team MeetingReservation.
    # Each Meeting ID is unique and grouped with its MRes count as associated value.
    def dest_meeting_ids_from_mres
      return @dest_meeting_ids_from_mres if @dest_meeting_ids_from_mres.present?

      @dest_meeting_ids_from_mres = GogglesDb::MeetingReservation.where(team_id: @dest.id)
                                                                 .group('meeting_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRes rows
    # involving *both* the *source* & the *destination* team.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mres
      return @shared_meeting_ids_from_mres if @shared_meeting_ids_from_mres.present?

      @shared_meeting_ids_from_mres = dest_meeting_ids_from_mres.dup.keep_if { |meeting_id, _count| src_meeting_ids_from_mres.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRes counts involving *just* the *source* team.
    def src_diff_meeting_ids_from_mres
      return @src_diff_meeting_ids_from_mres if @src_diff_meeting_ids_from_mres.present?

      @src_diff_meeting_ids_from_mres = src_meeting_ids_from_mres.dup.delete_if { |meeting_id, _count| dest_meeting_ids_from_mres.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRes counts involving *just* the *destination* team.
    def dest_diff_meeting_ids_from_mres
      return @dest_diff_meeting_ids_from_mres if @dest_diff_meeting_ids_from_mres.present?

      @dest_diff_meeting_ids_from_mres = dest_meeting_ids_from_mres.dup.delete_if { |meeting_id, _count| src_meeting_ids_from_mres.key?(meeting_id) }
    end

    # MRes are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mres_compatible?
      shared_meeting_ids_from_mres.blank?
    end

    # Assuming <tt>mres</tt> is a GogglesDb::MeetingReservation, returns a displayable label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mres(mres)
      season_id = mres.season.id
      badge = mres.badge_id ? mres.badge : GogglesDb::Badge.where(team_id: mres.team_id, team_id: mres.team_id, season_id:).first
      "[MRES #{mres.id}, Meeting #{mres.meeting_id}] team_id: #{mres.team_id} (#{mres.team.complete_name}) badge_id: #{mres.badge_id}, season: #{season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end

    # Analizes source and destination associations for conflicting MRESs (different source & destination row inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    def mres_analysis
      return @mres_analysis if @mres_analysis.present?

      @src_only_mres += GogglesDb::MeetingReservation.where(team_id: @source.id, meeting_id: src_diff_meeting_ids_from_mres.keys)
                                                     .map(&:id)
      @mres_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingReservation,
        target_decorator: :decorate_mres,
        where_condition: '(meeting_reservations.team_id = ? OR meeting_reservations.team_id = ?) AND (meeting_reservations.meeting_id IN (?))',
        src_list: src_diff_meeting_ids_from_mres,
        shared_list: shared_meeting_ids_from_mres,
        dest_list: dest_diff_meeting_ids_from_mres,
        result_title: 'MRES',
        subj_tuple_title: '(Meeting ID, MRES count)'
      )

      @mres_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                             MeetingEventReservation
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mev_res_count }</tt>
    # mapped from *source* team MeetingEventReservation.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def src_meeting_ids_from_mev_res
      return @src_meeting_ids_from_mev_res if @src_meeting_ids_from_mev_res.present?

      @src_meeting_ids_from_mev_res = GogglesDb::MeetingEventReservation.where(team_id: @source.id)
                                                                        .group('meeting_id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mev_res_count }</tt>
    # mapped from *destination* team MeetingEventReservation.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def dest_meeting_ids_from_mev_res
      return @dest_meeting_ids_from_mev_res if @dest_meeting_ids_from_mev_res.present?

      @dest_meeting_ids_from_mev_res = GogglesDb::MeetingEventReservation.where(team_id: @dest.id)
                                                                         .group('meeting_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRelRes rows
    # involving *both* the *source* & the *destination* team.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mev_res
      return @shared_meeting_ids_from_mev_res if @shared_meeting_ids_from_mev_res.present?

      @shared_meeting_ids_from_mev_res = dest_meeting_ids_from_mev_res.dup.keep_if { |meeting_id, _count| src_meeting_ids_from_mev_res.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRelRes counts involving *just* the *source* team.
    def src_diff_meeting_ids_from_mev_res
      return @src_diff_meeting_ids_from_mev_res if @src_diff_meeting_ids_from_mev_res.present?

      @src_diff_meeting_ids_from_mev_res = src_meeting_ids_from_mev_res.dup.delete_if { |meeting_id, _count| dest_meeting_ids_from_mev_res.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MEvRes counts involving *just* the *destination* team.
    def dest_diff_meeting_ids_from_mev_res
      return @dest_diff_meeting_ids_from_mev_res if @dest_diff_meeting_ids_from_mev_res.present?

      @dest_diff_meeting_ids_from_mev_res = dest_meeting_ids_from_mev_res.dup.delete_if { |meeting_id, _count| src_meeting_ids_from_mev_res.key?(meeting_id) }
    end

    # MEvRes are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mev_res_compatible?
      shared_meeting_ids_from_mev_res.blank?
    end

    # Assuming <tt>mev_res</tt> is a GogglesDb::MeetingEventReservation, returns a displayable label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mev_res(mev_res)
      season_id = mev_res.season.id
      badge = mev_res.badge_id ? mev_res.badge : GogglesDb::Badge.where(team_id: mev_res.team_id, team_id: mev_res.team_id, season_id:).first
      "[MEV_RES #{mev_res.id}, Meeting #{mev_res.meeting_id}] team_id: #{mev_res.team_id} (#{mev_res.team.complete_name}) badge_id: #{mev_res.badge_id}, season: #{season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end

    # Analizes source and destination associations for conflicting MRESs (different source & destination row inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    def mev_res_analysis
      return @mev_res_analysis if @mev_res_analysis.present?

      @src_only_mev_res += GogglesDb::MeetingEventReservation.where(team_id: @source.id, meeting_id: src_diff_meeting_ids_from_mev_res.keys)
                                                             .map(&:id)
      @mev_res_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingEventReservation,
        target_decorator: :decorate_mev_res,
        where_condition: '(meeting_event_reservations.team_id = ? OR meeting_event_reservations.team_id = ?) AND (meeting_event_reservations.meeting_id IN (?))',
        src_list: src_diff_meeting_ids_from_mev_res,
        shared_list: shared_meeting_ids_from_mev_res,
        dest_list: dest_diff_meeting_ids_from_mev_res,
        result_title: 'MEV_RES',
        subj_tuple_title: '(Meeting ID, MEV_RES count)'
      )

      @mev_res_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                             MeetingRelayReservation
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mrel_res_count }</tt>
    # mapped from *source* team MeetingRelayReservation.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def src_meeting_ids_from_mrel_res
      return @src_meeting_ids_from_mrel_res if @src_meeting_ids_from_mrel_res.present?

      @src_meeting_ids_from_mrel_res = GogglesDb::MeetingRelayReservation.where(team_id: @source.id)
                                                                         .group('meeting_id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_id => mrel_res_count }</tt>
    # mapped from *destination* team MeetingRelayReservation.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def dest_meeting_ids_from_mrel_res
      return @dest_meeting_ids_from_mrel_res if @dest_meeting_ids_from_mrel_res.present?

      @dest_meeting_ids_from_mrel_res = GogglesDb::MeetingRelayReservation.where(team_id: @dest.id)
                                                                          .group('meeting_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRelRes rows
    # involving *both* the *source* & the *destination* team.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_meeting_ids_from_mrel_res
      return @shared_meeting_ids_from_mrel_res if @shared_meeting_ids_from_mrel_res.present?

      @shared_meeting_ids_from_mrel_res = dest_meeting_ids_from_mrel_res.dup.keep_if { |meeting_id, _count| src_meeting_ids_from_mrel_res.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRelRes counts involving *just* the *source* team.
    def src_diff_meeting_ids_from_mrel_res
      return @src_diff_meeting_ids_from_mrel_res if @src_diff_meeting_ids_from_mrel_res.present?

      @src_diff_meeting_ids_from_mrel_res = src_meeting_ids_from_mrel_res.dup.delete_if { |meeting_id, _count| dest_meeting_ids_from_mrel_res.key?(meeting_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRelRes counts involving *just* the *destination* team.
    def dest_diff_meeting_ids_from_mrel_res
      return @dest_diff_meeting_ids_from_mrel_res if @dest_diff_meeting_ids_from_mrel_res.present?

      @dest_diff_meeting_ids_from_mrel_res = dest_meeting_ids_from_mrel_res.dup.delete_if { |meeting_id, _count| src_meeting_ids_from_mrel_res.key?(meeting_id) }
    end

    # MRelRes are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mrel_res_compatible?
      shared_meeting_ids_from_mrel_res.blank?
    end

    # Assuming <tt>mrel_res</tt> is a GogglesDb::MeetingRelayReservation, returns a displayable label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mrel_res(mrel_res)
      season_id = mrel_res.season.id
      badge = mrel_res.badge_id ? mrel_res.badge : GogglesDb::Badge.where(team_id: mrel_res.team_id, team_id: mrel_res.team_id, season_id:).first
      "[MREL_RES #{mrel_res.id}, Meeting #{mrel_res.meeting_id}] team_id: #{mrel_res.team_id} (#{mrel_res.team.complete_name}) " \
        "badge_id: #{mrel_res.badge_id}, season: #{season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end

    # Analizes source and destination associations for conflicting MREL_RES (different source & destination row inside same meeting),
    # returning an array of printable lines as an ASCII table for quick reference.
    def mrel_res_analysis
      return @mrel_res_analysis if @mrel_res_analysis.present?

      @src_only_mrel_res += GogglesDb::MeetingRelayReservation.where(team_id: @source.id, meeting_id: src_diff_meeting_ids_from_mrel_res.keys)
                                                              .map(&:id)
      @mrel_res_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingRelayReservation,
        target_decorator: :decorate_mrel_res,
        where_condition: '(meeting_relay_reservations.team_id = ? OR meeting_relay_reservations.team_id = ?) AND (meeting_relay_reservations.meeting_id IN (?))',
        src_list: src_diff_meeting_ids_from_mrel_res,
        shared_list: shared_meeting_ids_from_mrel_res,
        dest_list: dest_diff_meeting_ids_from_mrel_res,
        result_title: 'MREL_RES',
        subj_tuple_title: '(Meeting ID, MREL_RES count)'
      )

      @mrel_res_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                                MeetingEntry
    #-- ------------------------------------------------------------------------
    #++

    # Returns an array of Hash items each one having the format <tt>{ mprg_id => mes_count }</tt>
    # mapped from *source* team MeetingEntry.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def src_mprg_ids_from_mes
      return @src_mprg_ids_from_mes if @src_mprg_ids_from_mes.present?

      @src_mprg_ids_from_mes = GogglesDb::MeetingEntry.where(team_id: @source.id)
                                                      .group('meeting_program_id').count
    end

    # Returns an array of Hash items each one having the format <tt>{ meeting_program_id => mes_count }</tt>
    # mapped from *destination* team MeetingEntry.
    # Each Meeting ID is unique and grouped with its MRelRes count as associated value.
    def dest_mprg_ids_from_mes
      return @dest_mprg_ids_from_mes if @dest_mprg_ids_from_mes.present?

      @dest_mprg_ids_from_mes = GogglesDb::MeetingEntry.where(team_id: @dest.id)
                                                       .group('meeting_program_id').count
    end

    # Returns an array similar to the one above regarding shared and *conflicting* Meeting IDs extracted from MRelRes rows
    # involving *both* the *source* & the *destination* team.
    # NOTE: source & destination will be "merge-compatible" ONLY IF this array is empty.
    def shared_mprg_ids_from_mes
      return @shared_mprg_ids_from_mes if @shared_mprg_ids_from_mes.present?

      @shared_mprg_ids_from_mes = dest_mprg_ids_from_mes.dup.keep_if { |mprg_id, _count| src_mprg_ids_from_mes.key?(mprg_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRelRes counts involving *just* the *source* team.
    def src_diff_mprg_ids_from_mes
      return @src_diff_mprg_ids_from_mes if @src_diff_mprg_ids_from_mes.present?

      @src_diff_mprg_ids_from_mes = src_mprg_ids_from_mes.dup.delete_if { |mprg_id, _count| dest_mprg_ids_from_mes.key?(mprg_id) }
    end

    # Returns the difference array of unique Meeting IDs & MRelRes counts involving *just* the *destination* team.
    def dest_diff_mprg_ids_from_mes
      return @dest_diff_mprg_ids_from_mes if @dest_diff_mprg_ids_from_mes.present?

      @dest_diff_mprg_ids_from_mes = dest_mprg_ids_from_mes.dup.delete_if { |mprg_id, _count| src_mprg_ids_from_mes.key?(mprg_id) }
    end

    # MEntries are considered "compatible for merge" when:
    # - NO different instances (non-nil) are found inside the same meeting.
    #   (No conflicting results.)
    def mes_compatible?
      shared_mprg_ids_from_mes.blank?
    end

    # Assuming <tt>mes</tt> is a GogglesDb::MeetingEntry, returns a displayable label for the row,
    # checking also if the associated badge_id is set and existing.
    def decorate_mes(mes)
      season_id = mes.season.id
      badge = mes.badge_id ? mes.badge : GogglesDb::Badge.where(team_id: mes.team_id, team_id: mes.team_id, season_id:).first
      "[MEntry #{mes.id}, M.Progr. #{mes.meeting_program_id}] team_id: #{mes.team_id} (#{mes.team.complete_name}) " \
        "badge_id: #{mes.badge_id}, season: #{season_id} => Badge: #{badge.nil? ? '❌' : badge.id}"
    end

    # Analizes source and destination associations for conflicting MEntries
    # (different source & destination row inside same Meeting Program),
    # returning an array of printable lines as an ASCII table for quick reference.
    def mes_analysis
      return @mes_analysis if @mes_analysis.present?

      @src_only_mes += GogglesDb::MeetingEntry.where(team_id: @source.id, meeting_program_id: src_diff_mprg_ids_from_mes.keys)
                                              .map(&:id)
      @mes_analysis = report_fill_for(
        result_array: [],
        target_domain: GogglesDb::MeetingEntry,
        target_decorator: :decorate_mes,
        where_condition: '(meeting_entries.team_id = ? OR meeting_entries.team_id = ?) AND (meeting_entries.meeting_program_id IN (?))',
        src_list: src_diff_mprg_ids_from_mes,
        shared_list: shared_mprg_ids_from_mes,
        dest_list: dest_diff_mprg_ids_from_mes,
        result_title: 'M_ENTRY',
        subj_tuple_title: '( M.Progr. ID, MEntry count)'
      )

      @mes_analysis
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    # Maps source and destination associations for possible conflicting rows; that is, different
    # source & destination sibling rows associated to the same parent row).
    # Returns an array of displayable lines as an ASCII table for quick reference.
    #
    # Table width: 156 character columns (tested with some edge-case teams).
    #
    # == Options:
    # - <tt>:result_array</tt> => target array to be filled with decorated rows from the
    #   provided domains;
    #
    # - <tt>:target_domain</tt>: actual ActiveRecord target domain for the analysis;
    #   E.g., for "MRR"s should be something including the parent entity like this:
    #     GogglesDb::MeetingRelayTeam.joins(:meeting).includes(:meeting)
    #
    # - <tt>:target_decorator</tt>: symbolic name of the method used to decorate the sibling
    #   rows extracted for reporting purposes (e.g.: ':decorate_mrs' for MRS target rows).
    #
    # - <tt>:where_condition</tt>: string WHERE condition binding target columns with the sibling filtered
    #   rows; the where_condition is assumed to use as parameters: @source.id, @dest.id (order doesn't matter)
    #   and the array of filtered parent IDs as last parameter.
    #   E.g. for MIRs:
    #     '(meeting_individual_results.team_id = ? OR meeting_individual_results.team_id = ?) AND (meetings.id IN (?))'
    #
    # - <tt>:src_list</tt>, <tt>:shared_list</tt>, <tt>:dest_list</tt> =>
    #   filtered lists of tuples to be included in the analysis report, having format
    #   [<parent row_id>, <sibling/target count>];
    #
    # - <tt>:result_title</tt>: label title to be used for this section of the analysis;
    #
    # - <tt>:subj_tuple_title</tt>: descriptive label for the tuple stored in the domains,
    #   usually describing the format (<parent row_id>, <sibling/target count>).
    #
    def report_fill_for(opts = {}) # rubocop:disable Metrics/AbcSize
      return opts[:result_array] if opts[:result_array].present?

      opts[:result_array] = [prepare_section_title(opts[:result_title])]

      if opts[:src_list].present?
        centered_title = " SOURCE #{opts[:subj_tuple_title]} x [#{@source.id}: #{@source.display_label}] ".center(154, ' ')
        opts[:result_array] = fill_array_with_report_lines(tuple_list: opts[:src_list], result_array: opts[:result_array], centered_title:)
      else
        opts[:result_array] << ">> NO source-only #{opts[:result_title]}s."
      end

      if opts[:dest_list].present?
        centered_title = " DEST #{opts[:subj_tuple_title]} x [#{@dest.id}: #{@dest.display_label}] ".center(154, ' ')
        opts[:result_array] = fill_array_with_report_lines(tuple_list: opts[:dest_list], result_array: opts[:result_array], centered_title:)
      else
        opts[:result_array] << ">> NO destination-only #{opts[:result_title]}s."
      end

      if opts[:shared_list].present?
        centered_title = " *** CONFLICTING #{opts[:subj_tuple_title]}s *** ".center(154, ' ')
        opts[:result_array] = fill_array_with_report_lines(tuple_list: opts[:shared_list], result_array: opts[:result_array], centered_title:)

        opts[:result_array] << "+#{'- Offending rows: -'.center(154, ' ')}+"
        shared_parent_keys = opts[:shared_list].map(&:first)
        # Foreach row in a shared parent, report a decorated line:
        opts[:target_domain].where(opts[:where_condition], @source.id, @dest.id, shared_parent_keys).each do |row|
          opts[:result_array] << "- #{send(opts[:target_decorator], row)}"
        end
        opts[:result_array] << "+#{''.center(154, '-')}+"
      else
        opts[:result_array] << ">> NO conflicting #{opts[:result_title]}s."
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
    # report prepared by a specific section of an analysis (Badges, MIRs, MRRs).
    # Assumes <tt>result_array</tt> to be already initialized as an Array.
    #
    # == Params:
    # - tuple_list: filtered list of tuples to be used for filling the subtable;
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
  end
end
