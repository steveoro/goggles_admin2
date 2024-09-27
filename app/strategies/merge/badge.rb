# frozen_string_literal: true

module Merge
  #
  # = Merge::Badge
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20240926
  #
  class Badge
    attr_reader :sql_log, :checker, :source, :dest

    # Allows a source Badge to be merged into a destination one. All related entities
    # will be handled (all results, laps, ...).
    #
    # "Merging" implies moving all source data into the destination, so also the final source
    # columns values will usually become the new destination values (values from SOURCE/Master |=>
    # become new values for DESTINATION/Slave).
    # For this reason, use the dedicated parameter whenever the destination master row needs to
    # keep its columns untouched.
    #
    # More schematically:
    #
    #   [SOURCE] ------------------------> [DESTINATION]
    #   - to be purged (ID disappears)  /  - to be kept (ID remains)
    #   1. copies "master" column values into "slave" dest. values (overwritten)
    #   2. copies source sub-enties which are totally missing from dest.
    #   3. updates "shared" sub-enties which present some differences at any level of the hierarchy.
    #
    # While the first step is pretty straightforward, both the second and third steps
    # involve defining what is a "shared" sub-entity and what may make two rows similar or
    # overlapping for the specific entity we are trying to merge.
    #
    # In most cases, the merge is considered "unfeasible" (at least automatically) if
    # there are any shared/conflicting parent entities linked to any of the sub-entities involved,
    # so step '3' from above won't even happen.
    #
    # === "Shared sub-entities" for Badge-merging:
    # The typical example are two results identical in timing, for the same meeting, event
    # and swimmer but different in category assignment due to any error.
    #
    # Given that we can only have 1 swimmer per meeting event per badge, whenver 2 results
    # identical in timing belong to the same swimmer, meeting event and badge, merging
    # a badge that will imply a category change for the destination will imply also
    # updating all related results to the new, correct MeetingPrograms or "master" rows.
    # (e.g.: a MIR for an M25 badge moved to an M30 badge will need to get its meeting_program_id
    # link updated as well, and so on for all its sub-entities).
    #
    # == Additional notes:
    # This merge class won't actually touch the DB: it will just prepare the script so
    # that this process can be replicated on any DB that is in sync with the current one.
    #
    # == Params
    # - <tt>:source</tt> => source Badge row, *required*
    # - <tt>:dest</tt>   => destination Badge row; whenever this is left +nil+ (default)
    #                       the source Badge will be considered for fixing (in case the category needs
    #                       to be recomputed for any reason).
    #
    # All of the following flags are basically needed to force the merge in case of conflicts
    # between the two rows:
    #
    # - <tt>:keep_dest_columns</tt>
    #   => Forces merge from source to destination even in case of category or team conflict, but all
    #      key values from destination will act as "masters" (mainly category & team/affiliation).
    #
    #      Set this to +true+ to avoid updating *all* destination row columns
    #      with the values stored in source ("it keeps destination intact" and uses both its
    #      category and team/affiliation); default: +false+.
    #      This will only skip updating the destination row, not any sub-entities that will need updating.
    #      E.g.:
    #      - keep_dest_columns: true, dest. category 'M30', source category 'M25'
    #        => destination category will remain "M30", but any missing sub-entities will still be copied
    #           from source, getting the correct dest. category.
    #           (Any MIR, MRR => updated with Badge & MeetingProgram from dest)
    #
    # - <tt>:keep_dest_category</tt>
    #   => Set this to +true+ to consider the category_type_id inside destination as
    #      the correct one; default: +false+ (correct category comes from source).
    #      This will also force the merge to ignore any conflicts for category (only).
    #
    # - <tt>:keep_dest_team</tt>
    #   => Set this to +true+ to consider the team_id & team_affiliation_id inside destination as
    #      the correct ones; default: +false+ (correct team/affiliation comes from source).
    #      This will also force the merge to ignore any conflicts for team (only).
    #
    # - <tt>:force_conflict</tt>
    #   => Opposite of 'keep_dest_columns' but for source (uses the full source as key values even in case of differences).
    #      Forces merge from source to destination even in case of category or team conflict (from source).
    #
    #      Set this to +true+ to ignore any conflicts for category and/or team/affiliation and overwrite
    #      every key value in destination; default: +false+.
    #      This flag is only needed when there's one or more conflict and none of the previous
    #      flags are usable.
    #
    # === Parameters examples:
    #
    # /-keep_dest_columns: true
    # |-keep_dest_category: (ignored)
    # |-keep_dest_team: (ignored)
    # |-force_conflict: (ignored)
    # |
    # \--> MASTER = destination, will merge with conflicts in category or team,
    #      dest. gets all missing data from source, adapting it accordingly
    #      (keeping both category & team from destination => different programs for MIRs, MRRs, ...)
    #
    # /-keep_dest_columns: (ignored)
    # |-keep_dest_category: true
    # |-keep_dest_team: (ignored)
    # |-force_conflict: (ignored)
    # |
    # \--> MASTER = source, but correct category type comes from destination;
    #      merge will ignore ONLY category conflicts and will halt for team conflict,
    #      dest. gets all missing data from source, adapting it accordingly
    #      (keeping only category from destination => different programs for MIRs, MRRs, ...)
    #
    def initialize(options = [])
      source = options[:source]
      dest = options[:dest]
      raise(ArgumentError, 'Invalid source Badge!') unless source.is_a?(GogglesDb::Badge)
      raise(ArgumentError, 'Invalid destination!') unless dest.blank? || dest.is_a?(GogglesDb::Badge)

      # Convert options to boolean:
      @keep_dest_columns = options[:keep_dest_columns].present?
      @keep_dest_category = options[:keep_dest_category].present?
      @keep_dest_team = options[:keep_dest_team].present?
      @force_conflict = options[:force_conflict].present?

      @checker = BadgeChecker.new(source:, dest:)
      @source = @checker.source
      @dest = @checker.dest
      @sql_log = []
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the merge script inside a single transaction checking also all source and destination data
    # involved in the merge.
    def prepare # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      result_ok = @checker.run && !@checker.unrecoverable_conflict
      with_conflict = (@source.category_type_id != @dest.category_type_id) || (@source.team_id != @dest.team_id)
      can_ignore = @keep_dest_columns || @keep_dest_category || @keep_dest_team || @force_conflict
      @checker.display_report && return if !result_ok || (with_conflict && !can_ignore)

      # Detect the correct key values for the destination:
      raise(ArgumentError, 'Unable to detect correct team_id! Additional overrides may be needed.') if final_team_id.blank?
      raise(ArgumentError, 'Unable to detect correct team_affiliation_id! Additional overrides may be needed.') if final_team_affiliation_id.blank?
      raise(ArgumentError, 'Unable to detect correct category_type_id! Additional overrides may be needed.') if final_category_type_id.blank?

      @checker.log << "\r\n\r\n- #{'Checker'.ljust(44, '.')}: #{result_ok ? '✅ OK' : '🟡 Overridden conflicts'}"
      @sql_log << "\r\n-- Merge Badge (#{@source.id}) #{@source.display_label} |=> (#{@dest.id}) #{@dest.display_label}-- \r\n"
      # NOTE: uncommenting the following may yield nulls for created_at & updated_at if we don't provide values in the row
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''

      prepare_script_for_src_only_mirs
      prepare_script_for_src_only_mrss

      # TODO:
      # - update all categories in destination when different category from source is used
      # - consider all categories in source as categories from dest when different category from dest is used (skip columns & different category)
      # - "equal entities" (even when there's a difference in category as per above)
      #   => update categories according to correct ones (meeting progs., category_type_ids, ...)
      # - missing/new rows in dest => move them from source to dest
      # - "totally" existing/equal rows in source => to be purged at the end

      prepare_script_for_badge_and_swimmer_links
      prepare_script_for_swimmer_only_links

      # Move any swimmer-only association too:
      @sql_log << "UPDATE individual_records SET updated_at=NOW(), swimmer_id=#{@dest.id} WHERE swimmer_id=#{@source.id};"
      @sql_log << "UPDATE users SET updated_at=NOW(), swimmer_id=#{@dest.id} WHERE swimmer_id=#{@source.id};"
      # Remove the source swimmer before making the destination columns a duplicate of it:
      @sql_log << "DELETE FROM swimmers WHERE id=#{@source.id};"

      # Overwrite all commonly used columns at the end, if requested (this will update the index too):
      unless @skip_columns
        @sql_log << "UPDATE badges SET updated_at=NOW(), last_name=\"#{@source.last_name}\", first_name=\"#{@source.first_name}\", year_of_birth=#{@source.year_of_birth},"
        @sql_log << "  complete_name=\"#{@source.complete_name}\", nickname=\"#{@source.nickname || 'NULL'}\","
        @sql_log << "  associated_user_id=#{@source.associated_user_id || 'NULL'}, gender_type_id=#{@source.gender_type_id}, year_guessed=#{@source.year_guessed} WHERE id=#{@dest.id};\r\n"
      end

      @sql_log << ''
      @sql_log << 'COMMIT;'

      # FUTUREDEV: *** Cups & Records ***
      # - IndividualRecord: TODO, missing model (but table is there, links both team & swimmer)
      # - SeasonPersonalStandard: currently used only in old CSI meetings and not used nor updated anymore
      # - GoggleCupStandard: TODO
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the <tt>#log</tt> array from the internal BadgeChecker instance.
    def log
      @checker.log
    end

    # Returns the <tt>#errors</tt> array from the internal BadgeChecker instance.
    def errors
      @checker.errors
    end

    # Returns the <tt>#unrecoverable_conflict</tt> flag (true/false) from the internal BadgeChecker instance.
    def unrecoverable_conflict
      @checker.unrecoverable_conflict
    end

    # Returns the <tt>#warnings</tt> array from the internal BadgeChecker instance.
    def warnings
      @checker.warnings
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the expected <tt>#category_type_id</tt> value for the destination row.
    def final_category_type_id
      return @final_category_type_id if @final_category_type_id.present?

      @final_category_type_id = @source.category_type_id if (@source.category_type_id == @dest.category_type_id) || @force_conflict || @keep_dest_team
      @final_category_type_id = @dest.category_type_id if @keep_dest_columns || @keep_dest_category
      return if @final_category_type_id.blank? # Signal error otherwise (difference & no forced override)

      @final_category_type_id
    end

    # Returns the expected <tt>#team_id</tt> value for the destination row.
    def final_team_id
      return @final_team_id if @final_team_id.present?

      @final_team_id = @source.team_id if (@source.team_id == @dest.team_id) || @force_conflict || @keep_dest_category
      @final_team_id = @dest.team_id if @keep_dest_columns || @keep_dest_team
      return if @final_team_id.blank? # Signal error otherwise (difference & no forced override)

      @final_team_id
    end

    # Returns the expected <tt>#team_affiliation_id</tt> value for the destination row.
    def final_team_affiliation_id
      return @final_team_affiliation_id if @final_team_affiliation_id.present?

      if (@source.team_affiliation_id == @dest.team_affiliation_id) ||
         @force_conflict || @keep_dest_category
        @final_team_affiliation_id = @source.team_affiliation_id
      end
      return if @final_team_affiliation_id.blank? # Signal error otherwise (difference & no forced override)

      @final_team_affiliation_id
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    # Prepares the SQL text for the "MIR update" phase involving all entities that have a
    # foreign key to the source Badge.
    def prepare_script_for_src_only_mirs # rubocop:disable Metrics/AbcSize
      # NOTE: for each meeting event there can only be: 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 result (many laps)
      # (this will be checked below)
      mir_updates = 0
      mprg_inserts = 0
      @checker.src_only_mevent_ids_from_mirs.each_key do |mevent_id|
        same_event_mir_ids = GogglesDb::MeetingIndividualResult.joins(:meeting_event)
                                                               .where(
                                                                 badge_id: @source.id,
                                                                 'meeting_events.id': mevent_id
                                                               ).pluck(:id)
        raise("Found #{same_event_mir_ids.size} MIRs for event #{mevent_id}!") if same_event_mir_ids.size != 1

        mir_updates += 1
        # Destination program may or may not be already there when there's a difference in category:
        dest_mprg = GogglesDb::MeetingProgram.where(meeting_event_id: mevent_id, category_type_id: final_category_type_id).first

        # Update or Insert+Update?
        if dest_mprg.present?
          # Update source-only MIRs with the correct IDs:
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), badge_id=#{@dest.id}, " \
                      "meeting_program_id=#{dest_mprg.id}, team_id=#{final_team_id}, " \
                      "team_affiliation_id=#{final_team_affiliation_id} " \
                      "WHERE id IN (#{same_event_mir_ids.join(', ')});"
          # Update source-only Laps with the correct IDs:
          @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, team_id=#{final_team_id} " \
                      "WHERE meeting_individual_result_id IN (#{same_event_mir_ids.join(', ')});"

          # Update source & destination Laps with the correct IDs:
          prepare_script_for_laps(dest_mir.id, dest_mprg.id, final_team_id, missing_lap_ids,
                                  update_existing: false)
        else
          # Insert missing MPrg, then do the update:
          mprg_inserts += 1
          @sql_log << 'INSERT INTO meeting_programs (updated_at, category_type_id, gender_type_id, autofilled) ' \
                      "VALUES (NOW(), #{final_category_type_id}, #{@dest.gender_type.id}, 1);"
          @sql_log << 'SELECT LAST_INSERT_ID() INTO @last_id;'
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), badge_id=#{@dest.id}, " \
                      "meeting_program_id=@last_id, team_id=#{final_team_id}, " \
                      "team_affiliation_id=#{final_team_affiliation_id} " \
                      "WHERE id IN (#{same_event_mir_ids.join(', ')});"
          @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=@last_id, team_id=#{final_team_id} " \
                      "WHERE meeting_individual_result_id IN (#{same_event_mir_ids.join(', ')});"
        end
      end
      @checker.log << "- #{'Source-only updates for MIRs'.ljust(44, '.')}: #{mir_updates}" if mir_updates.positive?
      lap_updates = GogglesDb::Lap.where(meeting_individual_result_id: same_event_mir_ids).count
      @checker.log << "- #{'Source-only updates for Laps'.ljust(44, '.')}: #{lap_updates}" if lap_updates.positive?
      @checker.log << "- #{'Source-only updates for MPrograms'.ljust(44, '.')}: #{mprg_inserts}" if mprg_inserts.positive?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "MIR update" phase involving all MIRs that have a
    # shared link to both the source & destination Badge and have been deemed as "non conflicting".
    # (That is, having the same timing result even when there are difference in category/team/affiliation.)
    #
    # == Example:
    # Same event, same swimmer but 2 MIRs with same timing involving different badges (which we are merging).
    # - MIRs are basically the same, mapped 1:1 (probably due to an error during data-import - hence the "duplicated" badge)
    # - Only the sub-entities differences need to be reported (moved or updated) to destination;
    # - Source laps missing from dest. need to be reassigned/updated.
    # - Destination MPrg, MIRs and Laps need to be updated with the correct IDs.
    # - At the end, duplicated entities need to be deleted.
    def prepare_script_for_shared_mirs # rubocop:disable Metrics/AbcSize
      mir_updates = 0
      mprg_inserts = 0
      @checker.shared_mevent_ids_from_mirs.each_key do |mevent_id|
        # (1 MIR x Badge x Event only -- not checking with exception this here)
        src_mir = GogglesDb::MeetingIndividualResult.joins(:meeting_event).includes(:meeting_event)
                                                    .where(badge_id: @source.id, 'meeting_events.id': mevent_id)
                                                    .first
        dest_mir = GogglesDb::MeetingIndividualResult.joins(:meeting_event).includes(:meeting_event)
                                                     .where(badge_id: @dest.id, 'meeting_events.id': mevent_id)
                                                     .first
        raise("Unexpected: missing shared source MIR for event #{mevent_id}! (Both should be still existing)") if src_row.blank?
        raise("Unexpected: missing shared destination MIR for event #{mevent_id}! (Both should be still existing)") if dest_row.blank?

        # Destination program may or may not be already there when there's a difference in category:
        dest_mprg = GogglesDb::MeetingProgram.where(meeting_event_id: mevent_id, category_type_id: final_category_type_id).first
        existing_lap_lengths = dest_mir.laps.map(&:length_in_meters)
        # Reject any source lap for which there's already a correspondent lap in the destination:
        missing_lap_ids = src_mir.laps.to_a.reject { |lap| existing_lap_lengths.include?(lap.length_in_meters) }

        # Update MIR (and laps) or Insert MPrg + Update MIR (and laps)?
        if dest_mprg.present?
          # Update destination MIR with the correct IDs:
          # TODO
          # @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), badge_id=#{@dest.id}, " \
          #             "meeting_program_id=#{dest_mprg.id}, team_id=#{final_team_id}, " \
          #             "team_affiliation_id=#{final_team_affiliation_id} " \
          #             "WHERE id IN (#{same_event_mir_ids.join(', ')});"

          # Update source & destination Laps with the correct IDs:
          prepare_script_for_laps(dest_mir.id, dest_mprg.id, final_team_id, missing_lap_ids,
                                  update_existing: existing_lap_lengths.present?)

          # TODO
          # @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, team_id=#{final_team_id} " \
          #             "WHERE meeting_individual_result_id IN (#{same_event_mir_ids.join(', ')});"
        else
          # Insert missing MPrg, then do the update:
          mprg_inserts += 1
          # TODO
          @sql_log << 'INSERT INTO meeting_programs (updated_at, category_type_id, gender_type_id, autofilled) ' \
                      "VALUES (NOW(), #{final_category_type_id}, #{@dest.gender_type.id}, 1);"
          @sql_log << 'SELECT LAST_INSERT_ID() INTO @last_id;'
          # @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), badge_id=#{@dest.id}, " \
          #             "meeting_program_id=@last_id, team_id=#{final_team_id}, " \
          #             "team_affiliation_id=#{final_team_affiliation_id} " \
          #             "WHERE id IN (#{same_event_mir_ids.join(', ')});"

          # Update source & destination Laps with the correct IDs:
          prepare_script_for_laps(dest_mir.id, '@last_id', final_team_id, missing_lap_ids,
                                  update_existing: existing_lap_lengths.present?)

          # @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=@last_id, team_id=#{final_team_id} " \
          #             "WHERE meeting_individual_result_id IN (#{same_event_mir_ids.join(', ')});"
        end

        if existing_lap_lengths.present?
          # Update any existing destination laps with the correct IDs:
          @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, team_id=#{final_team_id} " \
                      "WHERE meeting_individual_result_id=#{dest_mir.id};"
        end

        if missing_lap_ids.present?
          # Move all source laps that may are missing from destination:
          @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, " \
                      "team_id=#{final_team_id}, meeting_individual_result_id=#{dest_mir.id}" \
                      "WHERE id IN (#{missing_lap_ids.join(', ')});"
        end

        mir_updates += 1
      end
      @checker.log << "- #{'Shared updates for MIRs'.ljust(44, '.')}: #{mir_updates}" if mir_updates.positive?
      lap_updates = GogglesDb::Lap.where(meeting_individual_result_id: same_event_mir_ids).count
      @checker.log << "- #{'Shared updates for Laps'.ljust(44, '.')}: #{lap_updates}" if lap_updates.positive?
      @checker.log << "- #{'Shared updates for MPrograms'.ljust(44, '.')}: #{mprg_inserts}" if mprg_inserts.positive?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "Laps update" phase involving the given <tt>mir_id</tt>
    # and <tt>mprg_id</tt>.
    # The script will update any existing destination laps with the correct IDs
    # if <tt>update_existing</tt> is set to +true+ (default), and then move all source laps that may
    # be missing from destination if <tt>missing_lap_ids</tt> is not empty.
    def prepare_script_for_laps(mir_id, mprg_id, team_id, missing_lap_ids, update_existing: true)
      # TODO: Refactor
      # 3 cases:
      # 1. update laps where MIR id=list
      # 2. update laps where MIR id=value
      # 3. update laps where id=list
      # - provide all needed parameters
      # laps will be purged when the MIR is deleted at the end

      #############################################################

      # # Update source-only Laps with the correct IDs:
      # @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, team_id=#{final_team_id} " \
      #             "WHERE meeting_individual_result_id IN (#{same_event_mir_ids.join(', ')});"

      # Update anyexisting destination laps with the correct IDs?
      if update_existing
        @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{mprg_id}, team_id=#{team_id} " \
                    "WHERE meeting_individual_result_id=#{mir_id};"
      end
      return if missing_lap_ids.blank?

      # Move all source laps that may be missing from destination:
      @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{mprg_id}, " \
                  "team_id=#{team_id}, meeting_individual_result_id=#{mir_id}" \
                  "WHERE id IN (#{missing_lap_ids.join(', ')});"
    end

    # Prepares the SQL text for the "MRS update" phase involving all entities that have a
    # foreign key to the source Badge.
    def prepare_script_for_src_only_mrss # rubocop:disable Metrics/AbcSize
      # NOTE: for each meeting event there can only be: 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 result (many sub-laps)
      # (this will be checked below)
      mrs_updates = 0
      @checker.src_only_mevent_ids_from_mrss.each_key do |mevent_id|
        same_event_mrs_ids = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event)
                                                           .where(
                                                             badge_id: @source.id,
                                                             'meeting_events.id': mevent_id
                                                           ).pluck(:id)
        raise("Found #{same_event_mrs_ids.size} MRSs for event #{mevent_id}!") if same_event_mrs_ids.size != 1

        mrs_updates += 1
        # Update source-only MRSs with the correct IDs:
        # NOTE: edge case where updating (fixing) the swimmer category changes the overall *relay* category type
        #       is UNSUPPORTED!
        @sql_log << "UPDATE meeting_relay_swimmers SET updated_at=NOW(), badge_id=#{@dest.id} " \
                    "WHERE id IN (#{same_event_mrs_ids.join(', ')});"
        @sql_log << "UPDATE relay_laps SET updated_at=NOW(), team_id=#{final_team_id} " \
                    "WHERE meeting_relay_swimmer_id IN (#{same_event_mrs_ids.join(', ')});"
      end
      @checker.log << "- #{'Updates for MeetingRelaySwimmers'.ljust(44, '.')}: #{mrs_updates}" if mrs_updates.positive?
      rlap_updates = GogglesDb::Lap.where(meeting_individual_result_id: same_event_mrs_ids).count
      @checker.log << "- #{'Updates for RelayLaps'.ljust(44, '.')}: #{rlap_updates}" if rlap_updates.positive?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "Badge update" phase involving all entities that have a
    # foreign key to the source swimmer's Badge.
    def prepare_script_for_badge_links # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      # Entities names implied in a badge IDs update (+ swimmer_id):
      tables_with_badge = %w[
        meeting_individual_results meeting_relay_swimmers meeting_reservations
        meeting_event_reservations meeting_relay_reservations
        meeting_entries badge_payments swimmer_season_scores
      ]

      @checker.log << "- #{'Updates for MeetingReservations'.ljust(44, '.')}: #{@checker.src_only_mres.count}" if @checker.src_only_mres.present?
      @checker.log << "- #{'Updates for MeetingEventReservations'.ljust(44, '.')}: #{@checker.src_only_mev_res.count}" if @checker.src_only_mev_res.present?
      @checker.log << "- #{'Updates for MeetingRelayReservations'.ljust(44, '.')}: #{@checker.src_only_mrel_res.count}" if @checker.src_only_mrel_res.present?
      @checker.log << "- #{'Updates for MeetingEntries'.ljust(44, '.')}: #{@checker.src_only_ments.count}" if @checker.src_only_ments.present?
      @sql_log << '-- [Source-only badges updates:]'

      # Update source-only badge_id references in sub-entities and move them to destination badge_id updating them also
      # with the correct final category & team/affiliation IDs:
      tables_with_badge.each do |sub_entity|
        # TODO:
        # For each involved sub-entity, get its direct parent and detect its correct value (key)
        # 1. MEvent -> MPrg(category) -> MIR -> Laps
        # 2. MEvent -> MPrg(category) -> MRR -> MRS -> RelayLaps

        @sql_log << "UPDATE #{sub_entity} SET updated_at=NOW(), badge_id=#{@dest.id} WHERE badge_id IN (#{@checker.src_only_badges.join(', ')});"
      end
      @sql_log << '' # empty line separator every badge update
      return if @checker.shared_badges.blank?

      @checker.log << "- #{'Badges to be updated and DELETED'.ljust(44, '.')}: #{@checker.shared_badges.count}"
      @sql_log << '-- [Shared badges:]'
      # For each sub-entity linked to a SHARED source badge (key), move it to the destination
      # swimmer and badge ID (value):
      @checker.shared_badges.each do |src_badge_id, dest_badge_id|
        tables_with_badge.each do |sub_entity|
          @sql_log << "UPDATE #{sub_entity} SET updated_at=NOW(), swimmer_id=#{@dest.id}, badge_id=#{dest_badge_id} " \
                      "WHERE badge_id=#{src_badge_id};"
        end
        @sql_log << '' # empty line separator every badge update
      end
      @sql_log << ''

      # Delete source shared badges (keys) after sub-entity update:
      @sql_log << "DELETE FROM badges WHERE id IN (#{@checker.shared_badges.keys.join(', ')});"
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "Swimmer-only" update phase involving all entities that have a
    # foreign key to Badge.
    def prepare_script_for_swimmer_only_links
      # Entities implied in a swimmer_id-only update:
      [
        GogglesDb::Lap, GogglesDb::RelayLap, GogglesDb::UserResult, GogglesDb::UserLap
        # GogglesDb::IndividualRecord TODO
      ].each do |entity|
        next unless entity.exists?(swimmer_id: @source.id)

        @checker.log << "- Updates for #{entity.name.split('::').last.ljust(32, '.')}: #{entity.where(swimmer_id: @source.id).count}"
        @sql_log << "UPDATE #{entity.table_name} SET updated_at=NOW(), swimmer_id=#{@dest.id} WHERE swimmer_id=#{@source.id};"
      end
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
