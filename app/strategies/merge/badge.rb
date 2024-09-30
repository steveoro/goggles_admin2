# frozen_string_literal: true

module Merge
  #
  # = Merge::Badge
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20240930
  #
  class Badge # rubocop:disable Metrics/ClassLength
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
      # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''

      prepare_script_for_disjointed_mirs(badge_id: @source.id,
                                         mevent_ids: @checker.src_only_mevent_ids_from_mirs.keys)
      prepare_script_for_shared_mirs
      prepare_script_for_disjointed_mirs(badge_id: @dest.id,
                                         mevent_ids: @checker.dest_only_mevent_ids_from_mirs.keys,
                                         subset_title: 'dest')

      prepare_script_for_disjointed_mrss(badge_id: @source.id,
                                         mevent_ids: @checker.src_only_mevent_ids_from_mirs.keys)
      prepare_script_for_shared_mrss
      prepare_script_for_disjointed_mrss(badge_id: @dest.id,
                                         mevent_ids: @checker.dest_only_mevent_ids_from_mrss.keys,
                                         subset_title: 'dest')
      # The following 2 need to be added just once per resulting script:
      add_script_for_mrs_counter_update
      add_script_for_relay_lap_counter_update

      # TODO:
      # - meeting entries
      # - meeting reservations, events & relays
      # - delete source badge only at the very end

      # Remove the source before making the destination columns a duplicate of it:
      @sql_log << "DELETE FROM badges WHERE id=#{@source.id};"
      # Overwrite all commonly used columns at the end, if requested (this will update the index too):
      # unless @skip_columns
      #   @sql_log << "UPDATE badges SET updated_at=NOW(), last_name=\"#{@source.last_name}\", first_name=\"#{@source.first_name}\", year_of_birth=#{@source.year_of_birth},"
      #   @sql_log << "  complete_name=\"#{@source.complete_name}\", nickname=\"#{@source.nickname || 'NULL'}\","
      #   @sql_log << "  associated_user_id=#{@source.associated_user_id || 'NULL'}, gender_type_id=#{@source.gender_type_id}, year_guessed=#{@source.year_guessed} WHERE id=#{@dest.id};\r\n"
      # end

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

      if (@source.category_type_id == @dest.category_type_id) || @force_conflict
        @final_category_type_id = @source.category_type_id
      elsif @keep_dest_columns || @keep_dest_category
        @final_category_type_id = @dest.category_type_id
      end
      return if @final_category_type_id.blank? # Signal error otherwise (difference & no forced override)

      @final_category_type_id
    end

    # Returns the expected <tt>#team_id</tt> value for the destination row.
    def final_team_id
      return @final_team_id if @final_team_id.present?

      if (@source.team_id == @dest.team_id) || @force_conflict
        @final_team_id = @source.team_id
      elsif @keep_dest_columns || @keep_dest_team
        @final_team_id = @dest.team_id
      end
      return if @final_team_id.blank? # Signal error otherwise (difference & no forced override)

      @final_team_id
    end

    # Returns the expected <tt>#team_affiliation_id</tt> value for the destination row.
    def final_team_affiliation_id
      return @final_team_affiliation_id if @final_team_affiliation_id.present?

      if (@source.team_affiliation_id == @dest.team_affiliation_id) || @force_conflict
        @final_team_affiliation_id = @source.team_affiliation_id
      elsif @keep_dest_columns || @keep_dest_team
        @final_team_affiliation_id = @dest.team_affiliation_id
      end
      return if @final_team_affiliation_id.blank? # Signal error otherwise (difference & no forced override)

      @final_team_affiliation_id
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    #-- ------------------------------------------------------------------------
    #                                  MIRS + Laps
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "MIR update" phase involving all MIRs & sub-entities that
    # belong to "disjointed" events and either belong to just the source or just the destination Badge.
    #
    # This basically implies that:
    # 1. all domain MIRs (either source or destination) need to be moved/updated to the correct IDs;
    # 2. all linked domain MIR's Laps need to be moved/updated (but not deleted as there's no duplication here).
    # 3. no deletion of rows is needed (because the update moves them to the correct destination).
    #
    # == Params
    # * +badge_id+: filtering badge ID (either source or dest.);
    # * +mevent_ids+: list of event IDs that are "disjointed" in usage between the two badges
    #                 and thus include MIRs only from either the source or the destination Badge
    #                 (but not both, which would require handling the duplication).
    # * +subset_title+: string title to identify this domain subset in the log.
    #
    def prepare_script_for_disjointed_mirs(badge_id:, mevent_ids:, subset_title: 'source') # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      mir_updates = 0
      mprg_inserts = 0
      lap_updates = 0
      @sql_log << "-- (#{subset_title}-only MIRs) --"

      mevent_ids.each do |mevent_id|
        # NOTE: for each meeting event: 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 result => (many laps)
        disjointed_mir_ids = GogglesDb::MeetingIndividualResult.joins(:meeting_event)
                                                               .where(
                                                                 badge_id:, 'meeting_events.id': mevent_id
                                                               ).pluck(:id)
        raise("Found #{disjointed_mir_ids.size} #{subset_title} MIRs for event #{mevent_id}!") if disjointed_mir_ids.size != 1

        mir_updates += 1 # (only 1 MIR for event -- see above)
        final_mir_id = disjointed_mir_ids.first
        # Destination program may or may not be already there when there's a difference in category:
        dest_mprg = GogglesDb::MeetingProgram.where(meeting_event_id: mevent_id, category_type_id: final_category_type_id).first

        # Update MIR (and Laps) or Insert MPrg + Update MIR (and Laps)?
        if dest_mprg.present?
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), badge_id=#{@dest.id}, " \
                      "meeting_program_id=#{dest_mprg.id}, team_id=#{final_team_id}, " \
                      "team_affiliation_id=#{final_team_affiliation_id} " \
                      "WHERE id=#{final_mir_id});"
          prepare_script_for_laps(mir_id: final_mir_id, mprg_id: dest_mprg.id, team_id: final_team_id,
                                  mir_id_list: disjointed_mir_ids)
        else
          # Insert missing MPrg, then do the update:
          mprg_inserts += 1
          @sql_log << 'INSERT INTO meeting_programs (updated_at, category_type_id, gender_type_id, autofilled) ' \
                      "VALUES (NOW(), #{final_category_type_id}, #{@dest.gender_type.id}, 1);"
          @sql_log << 'SELECT LAST_INSERT_ID() INTO @last_id;'
          # Move source-only MIR using correct IDs:
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), badge_id=#{@dest.id}, " \
                      "meeting_program_id=@last_id, team_id=#{final_team_id}, " \
                      "team_affiliation_id=#{final_team_affiliation_id} " \
                      "WHERE id=#{final_mir_id});"
          prepare_script_for_laps(mir_id: final_mir_id, mprg_id: '@last_id', team_id: final_team_id,
                                  mir_id_list: disjointed_mir_ids)
          lap_updates += GogglesDb::Lap.where(meeting_individual_result_id: final_mir_id).count
        end
      end
      @checker.log << "--- (#{subset_title}-only MIRs) ---"
      @checker.log << "- #{'Updates for MIRs'.ljust(44, '.')}: #{mir_updates}" if mir_updates.positive?
      @checker.log << "- #{'Updates for Laps'.ljust(44, '.')}: #{lap_updates}" if lap_updates.positive?
      @checker.log << "- #{'Inserts for MPrograms'.ljust(44, '.')}: #{mprg_inserts}" if mprg_inserts.positive?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "MIR update" phase involving all MIRs that belong to
    # an event that is "shared" between both the source & destination Badge and have been deemed
    # as "non conflicting". (That is, having the same timing result even when there are differences
    # in category/team/affiliation -- which implies any source row being a duplicate of some sort
    # on destination.)
    #
    # This basically results in:
    # 1. DEST. MIR UPDATES: the destination MIRs are to be kept and possibly updated with the
    #    correct IDs where needed;
    # 2. MISSING LAPS UPDATES: the destination MIRs may be missing some of or all of the Laps
    #    from the source MIRs (and these will need to be moved/updated);
    # 3. EXISTING LAPS UPDATES: any existing destination sub-entities (Laps) will need to map to the
    #    correct IDs (same category/team).
    # 4. DUPLICATED SOURCE ENTITIES DELETION: at the end, everything that has been correctly ported to
    #    the destination (MIRs and laps) and is a duplicate, will be deleted.
    #
    # == Example:
    # Same event, same swimmer but 2 MIRs with same timing involving different badges (which we are merging).
    # - MIRs are basically the same, mapped 1:1 (probably due to an error during data-import - hence the "duplicated" badge)
    # - Only the sub-entities differences need to be reported (moved or updated) to destination;
    # - Source laps missing from dest. need to be reassigned/updated.
    # - Destination MPrg, MIRs and Laps need to be updated with the correct IDs.
    # - At the end, duplicated source entities need to be deleted.
    def prepare_script_for_shared_mirs # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      mir_updates = 0
      lap_updates = 0
      lap_deletes = 0
      mprg_inserts = 0
      @sql_log << '-- (shared MIRs domain) --'

      # == Recap on the MEvents domain:
      # "Shared" events are collected from MIR's badges that are either from
      # source or destination. So:
      # 1. if the event is there, then "at least" both MIR should always be there;
      #     (at least -- meaning that for some rare errors it's possible to find even more duplicates)
      # 2. 1 MIR for 1 MeetingEvent only => 1 MIR has to be deleted
      # 3. the actual destination MIR must always be tied to @dest badge
      # 4. the MProgram could change (or need to be created) only due to a category change
      @checker.shared_mevent_ids_from_mirs.each_key do |mevent_id| # rubocop:disable Metrics/BlockLength
        # NOTE: for each meeting event: 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 result (many laps)
        src_mir = GogglesDb::MeetingIndividualResult.joins(:meeting_event).includes(:meeting_event)
                                                    .where(badge_id: @source.id, 'meeting_events.id': mevent_id)
                                                    .first
        dest_mir = GogglesDb::MeetingIndividualResult.joins(:meeting_event).includes(:meeting_event)
                                                     .where(badge_id: @dest.id, 'meeting_events.id': mevent_id)
                                                     .first
        raise("Unexpected: missing shared source MIR for event #{mevent_id}! (Both should be still existing)") if src_mir.blank?
        raise("Unexpected: missing shared destination MIR for event #{mevent_id}! (Both should be still existing)") if dest_mir.blank?
        # Make sure the overlapping MIRs are different in IDs:
        raise("Unexpected: source MIR (ID #{src_mir.id}) must be != dest. MIR (ID #{dest_mir.id})!") if src_mir.id == dest_mir.id

        mir_updates += 1 # (only 1 MIR for event/badge -- see above)

        # Destination program may or may not be already there when there's a difference in category:
        dest_mprg = GogglesDb::MeetingProgram.where(meeting_event_id: mevent_id, category_type_id: final_category_type_id).first
        # Find all Laps missing from destination by rejecting any source lap
        # for which there's already a correspondent lap:
        existing_lap_lengths = dest_mir.laps.map(&:length_in_meters)
        existing_lap_ids = dest_mir.laps.pluck(:id)
        missing_lap_ids = src_mir.laps.to_a
                                 .reject { |lap| existing_lap_lengths.include?(lap.length_in_meters) }
                                 .pluck(:id)
        duplicated_lap_ids = src_mir.laps.to_a
                                    .keep_if { |lap| existing_lap_lengths.include?(lap.length_in_meters) }
                                    .pluck(:id)

        # Just update MIR & laps or Insert MPrg + update MIR & laps?
        if dest_mprg.present?
          # Update destination MIR with the correct IDs:
          @sql_log << 'UPDATE meeting_individual_results SET updated_at=NOW(), ' \
                      "meeting_program_id=#{dest_mprg.id}, team_id=#{final_team_id}, " \
                      "team_affiliation_id=#{final_team_affiliation_id} " \
                      "WHERE id=#{dest_mir.id};"
          # Update missing source Laps with correct IDs:
          prepare_script_for_laps(mir_id: dest_mir.id, mprg_id: dest_mprg.id, team_id: final_team_id,
                                  lap_id_list: missing_lap_ids)
          # Update existing dest Laps with correct IDs:
          prepare_script_for_laps(mir_id: dest_mir.id, mprg_id: dest_mprg.id, team_id: final_team_id,
                                  lap_id_list: existing_lap_ids)
        else
          # Insert missing MPrg, then do the update:
          mprg_inserts += 1
          @sql_log << 'INSERT INTO meeting_programs (updated_at, category_type_id, gender_type_id, autofilled) ' \
                      "VALUES (NOW(), #{final_category_type_id}, #{@dest.gender_type.id}, 1);"
          @sql_log << 'SELECT LAST_INSERT_ID() INTO @last_id;'
          # Update destination MIR with the correct IDs:
          @sql_log << 'UPDATE meeting_individual_results SET updated_at=NOW(), ' \
                      "meeting_program_id=@last_id, team_id=#{final_team_id}, " \
                      "team_affiliation_id=#{final_team_affiliation_id} " \
                      "WHERE id=#{dest_mir.id};"

          # Update missing source Laps with correct IDs:
          prepare_script_for_laps(mir_id: dest_mir.id, mprg_id: '@last_id', team_id: final_team_id,
                                  lap_id_list: missing_lap_ids)
          # Update existing dest Laps with correct IDs:
          prepare_script_for_laps(mir_id: dest_mir.id, mprg_id: '@last_id', team_id: final_team_id,
                                  lap_id_list: existing_lap_ids)
          lap_updates += missing_lap_ids.size + existing_lap_ids.size
        end

        # Delete duplicated source MIR:
        @sql_log << "DELETE FROM laps WHERE meeting_individual_result_id=#{src_mir.id};"
        # Delete also any duplicated laps:
        if duplicated_lap_ids.present?
          lap_deletes += duplicated_lap_ids.size
          @sql_log << "DELETE FROM laps WHERE id IN (#{duplicated_lap_ids.join(', ')});"
        end
      end

      @checker.log << '--- (shared MIRs domain) ---'
      if mir_updates.positive?
        @checker.log << "- #{'Shared updates for MIRs'.ljust(44, '.')}: #{mir_updates}"
        @checker.log << "- #{'Shared deletions for MIRs'.ljust(44, '.')}: #{mir_updates}"
      end
      @checker.log << "- #{'Shared updates for Laps'.ljust(44, '.')}: #{lap_updates}" if lap_updates.positive?
      @checker.log << "- #{'Shared deletions for Laps'.ljust(44, '.')}: #{lap_deletes}" if lap_deletes.present?
      @checker.log << "- #{'Shared insertions for MPrograms'.ljust(44, '.')}: #{mprg_inserts}" if mprg_inserts.positive?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for any "Laps update" phase, according to the options specified,
    # updating directly the <tt>@sql_log</tt> member.
    #
    # The options allow to specify:
    # - the correct destination meeting_program_id
    # - the correct destination team_id
    # - the correct destination MIR_id
    # - a list of MIR_ids for the WHERE filter
    # - a list of laps ids for the WHERE filter
    #
    # Two Possible types of updates (both can be generated in one go):
    # 1. Updates laps where laps.MIR_id IN (<mir_id_list>)
    # 2. Updates laps where laps.id IN (<lap_id_list>)
    # Both updates set the correct team_id, meeting_program_id and meeting_individual_result_id
    # specified with the parameters.
    #
    # == Options:
    # - <tt>:mir_id</tt>: resulting meeting_individual_result_id for the laps update;
    # - <tt>:mprg_id</tt>: resulting meeting_program_id for the laps update;
    # - <tt>:team_id</tt>: resulting team_id for the laps update;
    # - <tt>:mir_id_list</tt>: meeting_individual_result_id list used as WHERE filter;
    # - <tt>:lap_id_list</tt>: meeting_individual_result_id list used as WHERE filter;
    #
    # Note that if any of the destination IDs are missing or both the filtering arrays
    # are left blank no SQL output will be generated.
    def prepare_script_for_laps(options = {})
      mir_id = options[:mir_id]
      mprg_id = options[:mprg_id]
      team_id = options[:team_id]
      mir_id_list = options[:mir_id_list]
      lap_id_list = options[:lap_id_list]
      return if mir_id.blank? || mprg_id.blank? || team_id.blank?

      if mir_id_list.present?
        @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{mprg_id}, " \
                    "team_id=#{team_id}, meeting_individual_result_id=#{mir_id}" \
                    "WHERE meeting_individual_result_id IN (#{mir_id_list.join(', ')});"
      end
      return if lap_id_list.blank?

      @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{mprg_id}, " \
                  "team_id=#{team_id}, meeting_individual_result_id=#{mir_id}" \
                  "WHERE id IN (#{lap_id_list.join(', ')});"
    end

    #-- ------------------------------------------------------------------------
    #                                MRSs + RelayLaps
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "MRS update" phase involving all MRS & sub-entities rows that
    # belong to "disjointed" events and either belong to just the source or just the destination Badge.
    #
    # This basically implies that:
    # 1. all domain MRSs (either source or destination) need to be moved/updated to the correct IDs;
    # 2. all linked domain MRS's RelayLaps need to be moved/updated (but not deleted as there's no duplication here).
    # 3. no deletion of rows is needed (because the update moves them to the correct destination).
    #
    # == NOTE:
    # The edge case where updating (fixing) the swimmer category changes the overall
    # *relay* category type is UNSUPPORTED and will raise an exception if that happens.
    #
    # == Params
    # * +badge_id+: filtering badge ID (either source or dest.);
    # * +mevent_ids+: list of event IDs that are "disjointed" in usage between the two badges
    #                 and thus include MRSs only from either the source or the destination Badge
    #                 (but not both, which would require handling the duplication).
    # * +subset_title+: string title to identify this domain subset in the log.
    #
    def prepare_script_for_disjointed_mrss(badge_id:, mevent_ids:, subset_title: 'source') # rubocop:disable Metrics/AbcSize
      raise("Final 'fixed' dest. category_type_id different from original: possible relay category type change!") if final_category_type_id != @dest.category_type_id

      # Implied updates for MRSs:
      # 1. MRR...... => meeting_program_id (no change), team_id, team_affiliation_id, meeting_relay_swimmers_count (no change unless duplicate)
      # 2. MRS...... => badge_id, meeting_relay_result_id (no change unless duplicate), relay_laps_count (no change unless duplicate)
      # 3. RelayLaps => team_id, meeting_relay_result_id (no change), meeting_relay_swimmer_id (no change unless duplicate)
      #
      # (*** NOTE: relay category changes in MPrograms for relays are NOT supported! ***)
      mrs_updates = 0
      mrr_updates = 0
      lap_updates = 0
      @sql_log << "-- (#{subset_title}-only MRSs) --"

      # == Recap on the MEvents domain:
      # "Disjointed" events are collected from just from one of the MRS's badges, being that either
      # source or destination (but no intersection in between). So:
      # 1. if the event is there, then "usually" only one MRS should be there;
      #     (meaning that in some rare cases it's possible to find even more duplicates from just one badge)
      # 2. 1 MRS x badge x 1 MeetingEvent only => 1 MRS is either source or destination
      # 3. the actual destination MRS must always be tied to @dest badge
      # 4. NO MProgram changes here, because relay category changes are NOT SUPPORTED.
      mevent_ids.each do |mevent_id|
        # 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 relay result => (many swimmers + relay_laps)
        disjointed_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event)
                                                        .where(badge_id:, 'meeting_events.id': mevent_id)
        raise("Found #{disjointed_mrss.count} #{subset_title} MRSs for event #{mevent_id}! (It should always be 1)") if disjointed_mrss.count != 1

        disjointed_mrs_id = disjointed_mrss.first.id
        disjointed_mrr_id = disjointed_mrss.first.meeting_relay_result_id
        mrs_updates += 1 # (only 1 MRS for event -- see above)

        # Update needed for MRR too?
        if final_team_id != @dest.team_id
          @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), team_id=#{final_team_id}, " \
                      "team_affiliation_id=#{final_team_affiliation_id} WHERE id=#{disjointed_mrr_id});"
          mrr_updates += 1
        end
        @sql_log << "UPDATE meeting_relay_swimmers SET updated_at=NOW(), badge_id=#{@dest.id}, " \
                    "team_id=#{final_team_id}, team_affiliation_id=#{final_team_affiliation_id} " \
                    "WHERE id=#{disjointed_mrs_id});"

        prepare_script_for_relay_laps(mrs_id: disjointed_mrs_id, team_id: final_team_id, mrs_id_list: [disjointed_mrs_id])
        lap_updates += GogglesDb::Lap.where(meeting_relay_swimmer_id: disjointed_mrs_id).count
      end

      @checker.log << "--- (#{subset_title}-only MRSs) ---"
      @checker.log << "- #{'Updates for MRSs'.ljust(44, '.')}: #{mrs_updates}" if mrs_updates.positive?
      @checker.log << "- #{'Updates for MRRs (=> team_id CHANGE!)'.ljust(44, '.')}: #{mrr_updates}" if mrr_updates.positive?
      @checker.log << "- #{'Updates for RelayLaps'.ljust(44, '.')}: #{lap_updates}" if lap_updates.positive?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "MRS update" phase involving all MRSs that belong to
    # an event that is "shared" between both the source & destination Badge and have been deemed
    # as "non conflicting". (That is, having the same timing result even when there are differences
    # in category/team/affiliation -- which implies any source row being a duplicate of some sort
    # on destination.)
    #
    # This basically results in: (same as #prepare_script_for_shared_mirs())
    # 1. DEST. MRS UPDATES: the destination MRSs are to be kept and possibly updated with the
    #    correct IDs where needed;
    # 2. MISSING RELAY_LAPS UPDATES: the destination MRSs may be missing some of or all of the RelayLaps
    #    from the source MRSs (and these will need to be moved/updated);
    # 3. EXISTING RELAY_LAPS UPDATES: any existing destination sub-entities (RelayLaps) will need to map to the
    #    correct IDs (same category/team).
    # 4. DUPLICATED SOURCE ENTITIES DELETION: at the end, everything that has been correctly ported to
    #    the destination (MRSs and RelayLaps) and is a duplicate, will be deleted.
    #
    # == NOTE:
    # The edge case where updating (fixing) the swimmer category changes the overall
    # *relay* category type is UNSUPPORTED and will raise an exception if that happens.
    #
    def prepare_script_for_shared_mrss # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      raise("Final 'fixed' dest. category_type_id different from original: possible relay category type change!") if final_category_type_id != @dest.category_type_id

      # Implied updates for MRSs:
      # 1. MRR...... => meeting_program_id (no change), team_id, team_affiliation_id, meeting_relay_swimmers_count (no change unless duplicate)
      # 2. MRS...... => badge_id, meeting_relay_result_id (no change unless duplicate), relay_laps_count (no change unless duplicate)
      # 3. RelayLaps => team_id, meeting_relay_result_id (no change), meeting_relay_swimmer_id (no change unless duplicate)
      #
      # (*** NOTE: relay category changes in MPrograms for relays are NOT supported! ***)
      mrs_updates = 0
      mrr_updates = 0
      lap_updates = 0
      lap_deletes = 0
      @sql_log << '-- (shared MRSs domain) --'

      # == Recap on the MEvents domain:
      # "Shared" events are collected from MRS's badges that are either from
      # source or destination. So:
      # 1. if the event is there, then "at least" both MRS should always be there;
      #     (at least -- meaning that for some rare errors it's possible to find even more duplicates)
      # 2. 1 MRS for 1 MeetingEvent only => 1 MRS has to be deleted
      # 3. the actual destination MRS must always be tied to @dest badge
      # 4. NO MProgram changes here, because relay category changes are NOT SUPPORTED.
      @checker.shared_mevent_ids_from_mrss.each_key do |mevent_id|
        # 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 relay result => (many swimmers + relay_laps)
        src_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event)
                                                 .includes(:meeting_event, :meeting_relay_result)
                                                 .where(badge_id: @source.id, 'meeting_events.id': mevent_id)
        raise("Unexpected: missing shared source MRS for event #{mevent_id}! (Both src & dest should be still existing)") if src_mrss.blank?
        raise("Found #{src_mrss.count} source MRSs for event #{mevent_id}! (It should always be 1)") if src_mrss.count != 1

        src_mrs = src_mrss.first
        dest_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event).includes(:meeting_event)
                                                  .includes(:meeting_event, :meeting_relay_result)
                                                  .where(badge_id: @dest.id, 'meeting_events.id': mevent_id)
        raise("Unexpected: missing shared destination MRS for event #{mevent_id}! (Both src & dest should be still existing)") if dest_mrss.blank?
        raise("Found #{dest_mrss.count} destination MRSs for event #{mevent_id}! (It should always be 1)") if src_mrss.count != 1

        dest_mrs = dest_mrss.first
        dest_mrr_id = dest_mrs.meeting_relay_result_id
        # Make sure the overlapping MRSs are different in IDs:
        raise("Unexpected: source MRS (ID #{src_mrs.id}) must be != dest. MRS (ID #{dest_mrs.id})!") if src_mrs.id == dest_mrs.id

        mrs_updates += 1 # (only 1 MRS for event/badge -- see above)

        # Find all RelayLaps missing from destination by rejecting any source lap
        # for which there's already a correspondent dest. lap:
        existing_lap_lengths = dest_mrs.relay_laps.map(&:length_in_meters)
        existing_lap_ids = dest_mrs.relay_laps.pluck(:id)
        missing_lap_ids = src_mrs.relay_laps.to_a
                                 .reject { |lap| existing_lap_lengths.include?(lap.length_in_meters) }
                                 .pluck(:id)
        duplicated_lap_ids = src_mrs.relay_laps.to_a
                                    .keep_if { |lap| existing_lap_lengths.include?(lap.length_in_meters) }
                                    .pluck(:id)

        # Update needed for MRR too? (only destination)
        if final_team_id != @dest.team_id
          @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), team_id=#{final_team_id}, " \
                      "team_affiliation_id=#{final_team_affiliation_id} WHERE id=#{dest_mrr_id});"
          mrr_updates += 1
        end
        # Update destination MRS with the correct IDs:
        @sql_log << "UPDATE meeting_relay_swimmers SET updated_at=NOW(), badge_id=#{@dest.id}, " \
                    "team_id=#{final_team_id}, team_affiliation_id=#{final_team_affiliation_id} " \
                    "WHERE id=#{dest_mrs.id});"

        # Update missing source Laps with correct IDs:
        prepare_script_for_relay_laps(mrs_id: dest_mrs.id, team_id: final_team_id, lap_id_list: missing_lap_ids)

        # Update existing dest Laps with correct IDs:
        prepare_script_for_relay_laps(mrs_id: dest_mrs.id, team_id: final_team_id, lap_id_list: existing_lap_ids)
        lap_updates += missing_lap_ids.size + existing_lap_ids.size

        # Delete duplicated source MRS:
        @sql_log << "DELETE FROM laps WHERE meeting_relay_swimmer_id=#{src_mrs.id};"
        # Delete also any duplicated laps:
        if duplicated_lap_ids.present?
          lap_deletes += duplicated_lap_ids.size
          @sql_log << "DELETE FROM laps WHERE id IN (#{duplicated_lap_ids.join(', ')});"
        end
      end

      @checker.log << '--- (shared MRSs domain) ---'
      if mrs_updates.positive?
        # (Each time we update a "shared" MRSs we'll have the same number of deletes:)
        @checker.log << "- #{'Shared updates for MRSs'.ljust(44, '.')}: #{mrs_updates}"
        @checker.log << "- #{'Shared deletions for MRSs'.ljust(44, '.')}: #{mrs_updates}"
      end
      @checker.log << "- #{'Updates for MRRs (=> team_id CHANGE!)'.ljust(44, '.')}: #{mrr_updates}" if mrr_updates.positive?
      @checker.log << "- #{'Shared updates for Laps'.ljust(44, '.')}: #{lap_updates}" if lap_updates.positive?
      @checker.log << "- #{'Shared deletions for Laps'.ljust(44, '.')}: #{lap_deletes}" if lap_deletes.present?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Updates the meeting_relay_swimmers_count for each MRR (from the related MRSs).
    # The query is generic and will involve *all* MRR rows, so it's needed just once per script.
    def add_script_for_mrs_counter_update
      # Update MRR's meeting_relay_swimmers_count (generic update for *all* swimmer count in MRR):
      @sql_log << 'UPDATE meeting_relay_results mrr ' \
                  'JOIN (SELECT meeting_relay_result_id, COUNT(*) AS meeting_relay_swimmers_count ' \
                  'FROM meeting_relay_swimmers GROUP BY meeting_relay_result_id) r ' \
                  'ON mrr.id = r.meeting_relay_result_id ' \
                  'SET mrr.meeting_relay_swimmers_count = r.meeting_relay_swimmers_count;'
    end

    # Updates the relay_laps_count for each MRS (from the related RelayLaps).
    # The query is generic and will involve *all* MRS rows, so it's needed just once per script.
    def add_script_for_relay_lap_counter_update
      # Update MRS's relay_laps_count as above (generic update for relay lap count in MRS):
      @sql_log << 'UPDATE meeting_relay_swimmers mrs ' \
                  'JOIN (SELECT meeting_relay_swimmer_id, COUNT(*) AS relay_laps_count ' \
                  'FROM relay_laps GROUP BY meeting_relay_swimmer_id) r ' \
                  'ON mrs.id = r.meeting_relay_swimmer_id ' \
                  'SET mrs.relay_laps_count = r.relay_laps_count;'
    end

    # Prepares the SQL text for any "RelayLaps update" phase, according to the options specified,
    # updating directly the <tt>@sql_log</tt> member.
    #
    # The options allow to specify:
    # - the correct destination team_id
    # - the correct destination MRS_id
    # - a list of MRS_ids for the WHERE filter
    # - a list of relay_laps ids for the WHERE filter
    #
    # Two Possible types of updates (both can be generated in one go):
    # 1. Updates laps where relay_laps.MRS_id IN (<mrs_id_list>)
    # 2. Updates laps where relay_laps.id IN (<lap_id_list>)
    # Both updates set the correct team_id and meeting_relay_swimmer_id specified
    # with the parameters.
    #
    # == Options:
    # - <tt>:mrs_id</tt>: resulting meeting_relay_swimmer_id for the laps update;
    # - <tt>:team_id</tt>: resulting team_id for the laps update;
    # - <tt>:mrs_id_list</tt>: meeting_relay_swimmer_id list used as WHERE filter;
    # - <tt>:lap_id_list</tt>: relay_laps.id list used as WHERE filter;
    #
    # Note that if any of the destination IDs are missing or both the filtering arrays
    # are left blank no SQL output will be generated.
    def prepare_script_for_relay_laps(options = {})
      mrs_id = options[:mrs_id]
      team_id = options[:team_id]
      mrs_id_list = options[:mrs_id_list]
      lap_id_list = options[:lap_id_list]
      return if mrs_id.blank? || mprg_id.blank? || team_id.blank?

      if mrs_id_list.present?
        @sql_log << "UPDATE laps SET updated_at=NOW(), team_id=#{team_id}, " \
                    "meeting_relay_swimmer_id=#{mrs_id}" \
                    "WHERE meeting_relay_swimmer_id IN (#{mrs_id_list.join(', ')});"
      end
      return if lap_id_list.blank?

      @sql_log << "UPDATE laps SET updated_at=NOW(), team_id=#{team_id}, " \
                  "meeting_relay_swimmer_id=#{mrs_id}" \
                  "WHERE id IN (#{lap_id_list.join(', ')});"
    end

    # Prepares the SQL text for the "Badge update" phase involving all entities that have a
    # foreign key to the source swimmer's Badge.
    # def prepare_script_for_badge_links
    #   # Entities names implied in a badge IDs update (+ swimmer_id):
    #   tables_with_badge = %w[
    #     meeting_individual_results meeting_relay_swimmers meeting_reservations
    #     meeting_event_reservations meeting_relay_reservations
    #     meeting_entries badge_payments swimmer_season_scores
    #   ]

    #   @checker.log << "- #{'Updates for MeetingReservations'.ljust(44, '.')}: #{@checker.src_only_mres.count}" if @checker.src_only_mres.present?
    #   @checker.log << "- #{'Updates for MeetingEventReservations'.ljust(44, '.')}: #{@checker.src_only_mev_res.count}" if @checker.src_only_mev_res.present?
    #   @checker.log << "- #{'Updates for MeetingRelayReservations'.ljust(44, '.')}: #{@checker.src_only_mrel_res.count}" if @checker.src_only_mrel_res.present?
    #   @checker.log << "- #{'Updates for MeetingEntries'.ljust(44, '.')}: #{@checker.src_only_ments.count}" if @checker.src_only_ments.present?
    #   @sql_log << '-- [Source-only badges updates:]'

    #   # Update source-only badge_id references in sub-entities and move them to destination badge_id updating them also
    #   # with the correct final category & team/affiliation IDs:
    #   tables_with_badge.each do |sub_entity|
    #     # TODO:
    #     # For each involved sub-entity, get its direct parent and detect its correct value (key)
    #     # 1. MEvent -> MPrg(category) -> MIR -> Laps
    #     # 2. MEvent -> MPrg(category) -> MRR -> MRS -> RelayLaps

    #     @sql_log << "UPDATE #{sub_entity} SET updated_at=NOW(), badge_id=#{@dest.id} WHERE badge_id IN (#{@checker.src_only_badges.join(', ')});"
    #   end
    #   @sql_log << '' # empty line separator every badge update
    #   return if @checker.shared_badges.blank?

    #   @checker.log << "- #{'Badges to be updated and DELETED'.ljust(44, '.')}: #{@checker.shared_badges.count}"
    #   @sql_log << '-- [Shared badges:]'
    #   # For each sub-entity linked to a SHARED source badge (key), move it to the destination
    #   # swimmer and badge ID (value):
    #   @checker.shared_badges.each do |src_badge_id, dest_badge_id|
    #     tables_with_badge.each do |sub_entity|
    #       @sql_log << "UPDATE #{sub_entity} SET updated_at=NOW(), swimmer_id=#{@dest.id}, badge_id=#{dest_badge_id} " \
    #                   "WHERE badge_id=#{src_badge_id};"
    #     end
    #     @sql_log << '' # empty line separator every badge update
    #   end
    #   @sql_log << ''

    #   # Delete source shared badges (keys) after sub-entity update:
    #   @sql_log << "DELETE FROM badges WHERE id IN (#{@checker.shared_badges.keys.join(', ')});"
    # end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "Swimmer-only" update phase involving all entities that have a
    # foreign key to Badge.
    # def prepare_script_for_swimmer_only_links
    #   # Entities implied in a swimmer_id-only update:
    #   [
    #     GogglesDb::Lap, GogglesDb::RelayLap, GogglesDb::UserResult, GogglesDb::UserLap
    #     # GogglesDb::IndividualRecord TODO
    #   ].each do |entity|
    #     next unless entity.exists?(swimmer_id: @source.id)

    #     @checker.log << "- Updates for #{entity.name.split('::').last.ljust(32, '.')}: #{entity.where(swimmer_id: @source.id).count}"
    #     @sql_log << "UPDATE #{entity.table_name} SET updated_at=NOW(), swimmer_id=#{@dest.id} WHERE swimmer_id=#{@source.id};"
    #   end
    # end
    #-- ------------------------------------------------------------------------
    #++
  end
end
