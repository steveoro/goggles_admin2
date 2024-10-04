# frozen_string_literal: true

module Merge
  #
  # = Merge::Badge
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20241003
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
    # Note that destination overrides have precedence over source overrides ('force_conflict').
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
    def prepare # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/MethodLength
      return if @sql_log.present? # Don't allow a second run of this strategy

      result_ok = @checker.run && !@checker.unrecoverable_conflict
      with_conflict = @dest.present? &&
                      ((@source.category_type_id != @dest.category_type_id) || (@source.team_id != @dest.team_id))
      can_ignore = @keep_dest_columns || @keep_dest_category || @keep_dest_team || @force_conflict
      @checker.display_report && return if !result_ok || (with_conflict && !can_ignore)

      # Detect the correct key values for the destination:
      raise(ArgumentError, 'Unable to detect correct team_id! Additional overrides may be needed.') if final_team_id.blank?
      raise(ArgumentError, 'Unable to detect correct team_affiliation_id! Additional overrides may be needed.') if final_team_affiliation_id.blank?

      @checker.log << "\r\n\r\n- #{'Checker'.ljust(44, '.')}: #{result_ok ? '✅ OK' : '🟡 Overridden conflicts'}"
      prepare_script_header

      # MIRs/Laps:
      prepare_script_for_disjointed_mirs(badge_id: @source.id,
                                         mevent_ids: @checker.src_only_mevent_ids_from_mirs.keys)
      # Standard merge or category "auto-fix" mode? (With @dest.nil?)
      # For auto-fix, skip over entities that do not require MPrograms updates due to category changes:
      if @dest.present?
        prepare_script_for_shared_mirs
        prepare_script_for_disjointed_mirs(badge_id: @dest.id,
                                           mevent_ids: @checker.dest_only_mevent_ids_from_mirs.keys,
                                           subset_title: 'dest')
      end

      # MRR/MRS/RelayLaps:
      prepare_script_for_disjointed_mrss(badge_id: @source.id,
                                         mevent_ids: @checker.src_only_mevent_ids_from_mrss.keys)
      if @dest.present?
        prepare_script_for_shared_mrss
        prepare_script_for_disjointed_mrss(badge_id: @dest.id,
                                           mevent_ids: @checker.dest_only_mevent_ids_from_mrss.keys,
                                           subset_title: 'dest')
      end
      # The following 2 need to be added just once per resulting script:
      @sql_log << '-- (MRS & relay_laps counters update) --'
      add_script_for_mrs_counter_update
      add_script_for_relay_lap_counter_update

      # MeetingEntries:
      prepare_script_for_disjointed_ments(badge_id: @source.id,
                                          mevent_ids: @checker.src_only_mevent_ids_from_ments.keys)
      if @dest.present?
        prepare_script_for_shared_ments
        prepare_script_for_disjointed_ments(badge_id: @dest.id,
                                            mevent_ids: @checker.dest_only_mevent_ids_from_ments.keys,
                                            subset_title: 'dest')
        # MReservations:
        # Do just a simplified update for the reservations entities (we won't care about duplicates here)
        @sql_log << "UPDATE meeting_reservations SET updated_at=NOW(), badge_id=#{@dest.id} WHERE badge_id = #{@source.id};"
        @sql_log << "UPDATE meeting_event_reservations SET updated_at=NOW(), badge_id=#{@dest.id} WHERE badge_id = #{@source.id};"
        @sql_log << "UPDATE meeting_relay_reservations SET updated_at=NOW(), badge_id=#{@dest.id} WHERE badge_id = #{@source.id};"
        # Remove the source before making it possible duplicate by updating the destination columns:
        @sql_log << "\r\nDELETE FROM badges WHERE id=#{@source.id};"
      end

      # Overwrite main dest. columns at the end (this will update the index too):
      @sql_log << "UPDATE badges SET updated_at=NOW(), #{update_statement_values(actual_dest_badge)} "
      @sql_log << "  WHERE id=#{actual_dest_badge.id};"

      # FUTUREDEV: *** Cups & Records ***
      # - IndividualRecord: TODO, missing model (but table is there, links both team & swimmer)
      # - SeasonPersonalStandard: currently used only in old CSI meetings and not used nor updated anymore
      # - GoggleCupStandard: TODO
      nil
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

    # Returns a "START TRANSACTION" header as an array of SQL string statements.
    # This merger class separates the SQL log from its single-transaction wrapper so
    # that externally it can be combined externally multiple times with other results.
    def start_transaction_log
      [
        # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
        "\r\n-- SET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";",
        'SET AUTOCOMMIT = 0;',
        "START TRANSACTION;\r\n"
      ]
    end

    # Returns a "COMMIT" footer as an array of SQL string statements.
    # This merger class separates the SQL log from its single-transaction wrapper so
    # that it can be combined externally multiple times with other results.
    def end_transaction_log
      [ "\r\nCOMMIT;" ]
    end

    # Returns the SQL log wrapped in a single transaction, as an array of SQL string statements.
    def single_transaction_sql_log
      start_transaction_log + @sql_log + end_transaction_log
    end

    # Adds a descriptive header to the @sql_log member.
    def prepare_script_header
      @sql_log << "-- Merge Badge (#{@source.id}) #{@source.display_label}, season #{@source.season_id}"
      @sql_log << "--   |   team #{@source.team_id}, category_type #{@source.category_type_id} (#{@source.category_type.code})"
      if @dest.present?
        @sql_log << '--   |'
        @sql_log << "--   +=> (#{@dest.id}) #{@dest.display_label}, season #{@dest.season_id}"
        @sql_log << "--       team #{@dest.team_id}, category_type #{@dest.category_type_id} (#{@dest.category_type.code})\r\n"
      end
      raise(ArgumentError, 'Unable to detect final category_type_id! Additional overrides may be needed.') if final_category_type_id.blank?

      final_category_type_code = GogglesDb::CategoryType.find(final_category_type_id).code
      @sql_log << "--   +=> FINAL team: #{final_team_id}, FINAL category_type: #{final_category_type_id} (#{final_category_type_code})\r\n"
      @sql_log << '-- Keep ALL dest. columns' if @keep_dest_columns
      @sql_log << '-- Keep dest. category' if @keep_dest_category
      @sql_log << '-- Keep dest. team' if @keep_dest_team
      @sql_log << '-- Enforce ALL source columns conflicts' if @force_conflict
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the "actual destination" Badge instance, depending on the operations mode:
    # - @dest for a merge, where both source & destination are defined;
    # - @source for a "category auto-fix" (where destination is left +nil+).
    def actual_dest_badge
      @dest.present? ? @dest : @source
    end

    # Returns the expected <tt>#category_type_id</tt> value for the destination row.
    # Destination overrides have precedence over source.
    #
    # Whenever either the source or the destination have a wrongly assigned relay category,
    # the resulting final category will be enforced to the other one with an automatic override.
    #
    # If both have a relay-only category, the result will be computed using the esteemed swimmer age.
    #
    # PLEASE MIND THAT the result won't necessarily match <tt>actual_dest_badge.category_type_id</tt>.
    # (As a matter of fact, output will be generated only when the two are different.)
    def final_category_type_id # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity,Metrics/AbcSize
      return @final_category_type_id if @final_category_type_id.present?
      return compute_final_category_type if @checker.category_auto_fixing?

      if @dest.present? && !@dest.category_type.relay? &&
         (@keep_dest_columns || @keep_dest_category || @source.category_type.relay?)
        @final_category_type_id = @dest.category_type_id

      elsif !@source.category_type.relay? &&
            (
              @force_conflict ||
              (@dest.present? && ((@source.category_type_id == @dest.category_type_id) || @dest.category_type.relay?))
            )
        @final_category_type_id = @source.category_type_id
      end
      return if @final_category_type_id.blank? # Signal error (difference & no forced override)

      if @source.category_type.relay? || (@dest.present? && @dest.category_type.relay?)
        @checker.log << '-- RELAY-ONLY CATEGORY DETECTED in src or dest. => ' \
                        "FORCING final category_type_id = #{@final_category_type_id} (regardless of other overrides)"
      end
      @final_category_type_id
    end

    # Returns the expected <tt>#team_id</tt> value for the destination row.
    # Destination overrides have precedence over source.
    #
    # PLEASE MIND THAT the result won't necessarily match <tt>actual_dest_badge.team_id</tt>.
    # (As a matter of fact, output will be generated only when the two are different.)
    def final_team_id # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      return @final_team_id if @final_team_id.present?

      if @dest.present? && (@keep_dest_columns || @keep_dest_team)
        @final_team_id = @dest.team_id
      elsif @force_conflict || (@dest.present? && (@source.team_id == @dest.team_id))
        @final_team_id = @source.team_id
      end
      return if @final_team_id.blank? # Signal error otherwise (difference & no forced override)

      @final_team_id
    end

    # Returns the expected <tt>#team_affiliation_id</tt> value for the destination row.
    # Destination overrides have precedence over source.
    #
    # PLEASE MIND THAT the result won't necessarily match <tt>actual_dest_badge.team_affiliation_id</tt>.
    # (As a matter of fact, output will be generated only when the two are different.)
    def final_team_affiliation_id # rubocop:disable Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
      return @final_team_affiliation_id if @final_team_affiliation_id.present?

      if @dest.present? && (@keep_dest_columns || @keep_dest_team)
        @final_team_affiliation_id = @dest.team_affiliation_id
      elsif @force_conflict || (@dest.present? && (@source.team_affiliation_id == @dest.team_affiliation_id))
        @final_team_affiliation_id = @source.team_affiliation_id
      end
      return if @final_team_affiliation_id.blank? # Signal error otherwise (difference & no forced override)

      @final_team_affiliation_id
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    # Computes the CategoryType to use for the badge after merging.
    #
    # Given the swimmer year of birth and the season begin date, it finds the
    # CategoryType that best matches the swimmer age in the given season.
    # The result is stored into the <tt>@final_category_type_id</tt> instance variable.
    def compute_final_category_type
      swimmer_age = @source.season.begin_date.year - @source.swimmer.year_of_birth
      computed_category_type = @source.season.category_types
                                      .where('relay = false AND age_begin <= ? AND age_end >= ?', swimmer_age, swimmer_age)
                                      .first
      msg = "-- COMPUTED category type: #{computed_category_type&.id} (#{computed_category_type&.code})"
      @sql_log << msg
      @checker.log << msg
      @final_category_type_id = computed_category_type&.id
    end

    # Returns +true+ if the destination badge will be different than the source.
    def change_in_badge_id?
      actual_dest_badge.id != @source.id
    end

    # Returns +true+ if the destination badge will have its <tt>category_type_id</tt> changed as a result of the merge.
    def change_in_category_type_id?
      actual_dest_badge.category_type_id != final_category_type_id
    end

    # Returns +true+ if the destination badge will have its <tt>team_id</tt> changed as a result of the merge.
    # When this is true a change in team_affiliation_id is implied as well.
    def change_in_team_id?
      actual_dest_badge.team_id != final_team_id
    end

    # Returns the SQL string sub-statement for an 'UPDATE' involving just
    # the changed column values in the specified ActiveRecord row.
    # The <tt>row</tt> parameter is only used for its structure, not its values
    # (which will be taken from the "#final_<XXX>" helper methods enlisted above).
    def update_statement_values(row)
      result = []
      if row.respond_to?(:badge_id) && row.badge_id != actual_dest_badge.id
        result << "badge_id=#{actual_dest_badge.id}"
      end
      if row.respond_to?(:team_id) && row.team_id != final_team_id
        result << "team_id = #{final_team_id}"
      end
      if row.respond_to?(:team_affiliation_id) && row.team_affiliation_id != final_team_affiliation_id
        result << "team_affiliation_id=#{final_team_affiliation_id}"
      end
      if row.respond_to?(:category_type_id) && row.category_type_id != final_category_type_id
        result << "category_type_id=#{final_category_type_id}"
      end
      result.join(', ')
    end

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
    def prepare_script_for_disjointed_mirs(badge_id:, mevent_ids:, subset_title: 'source') # rubocop:disable Metrics/AbcSize,Metrics/MethodLength,Metrics/PerceivedComplexity
      return if mevent_ids.blank?

      mir_updates = 0
      mprg_inserts = 0
      lap_updates = 0
      @sql_log << "-- (#{subset_title}-only MIRs) --"

      mevent_ids.each do |mevent_id|
        # NOTE: for each meeting event: 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 result => (many laps)
        disjointed_mirs = GogglesDb::MeetingIndividualResult.joins(:meeting_event)
                                                            .where(badge_id:, 'meeting_events.id': mevent_id)
        raise("Found #{disjointed_mirs.size} #{subset_title} MIRs for event #{mevent_id}!") if disjointed_mirs.size != 1

        final_mir = disjointed_mirs.first
        # Destination program may or may not be already there when there's a difference in category:
        dest_mprg = GogglesDb::MeetingProgram.where(meeting_event_id: mevent_id, category_type_id: final_category_type_id).first
        update_statement = update_statement_values(final_mir)
        lap_count = GogglesDb::Lap.where(meeting_individual_result_id: final_mir.id).count
        # Nothing to update?
        next if update_statement.blank? && lap_count.zero? &&
                dest_mprg && (dest_mprg.id == final_mir.meeting_program_id)

        disjointed_mirs_ids = disjointed_mirs.pluck(:id)

        # Update MIR (and Laps) or Insert MPrg + Update MIR (and Laps)?
        if dest_mprg.present?
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, " \
                      "#{update_statement} WHERE id = #{final_mir.id};"
          mir_updates += 1 # (only 1 MIR for event -- see above)
          prepare_script_for_laps(mir_id: final_mir.id, mprg_id: dest_mprg.id, team_id: final_team_id,
                                  mir_id_list: disjointed_mirs_ids)
        else
          # Insert missing MPrg, then do the update:
          @sql_log << 'INSERT INTO meeting_programs (updated_at, category_type_id, gender_type_id, autofilled) ' \
                      "VALUES (NOW(), #{final_category_type_id}, #{@source.gender_type.id}, 1);"
          mprg_inserts += 1
          @sql_log << 'SELECT LAST_INSERT_ID() INTO @last_id;'
          # Move source-only MIR using correct IDs:
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), meeting_program_id=@last_id, " \
                      "#{update_statement} WHERE id = #{final_mir.id};"
          mir_updates += 1 # (only 1 MIR for event -- see above)
          prepare_script_for_laps(mir_id: final_mir.id, mprg_id: '@last_id', team_id: final_team_id,
                                  mir_id_list: disjointed_mirs_ids)
          lap_updates += lap_count
        end
      end

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
    #
    # Note that during a category "auto-fix" (where destination is supposed to be +nil+),
    # this method does nothing.
    #
    def prepare_script_for_shared_mirs # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      return if @checker.shared_mevent_ids_from_mirs.keys.blank?

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
      # 3. the actual destination MIR must always be tied to @dest badge (when in "merge mode")
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

        # Destination program may or may not be already there when there's a difference in category:
        dest_mprg = GogglesDb::MeetingProgram.where(meeting_event_id: mevent_id, category_type_id: final_category_type_id).first
        update_statement = update_statement_values(dest_mir)

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
        # Nothing to update?
        next if update_statement.blank? &&
                dest_mprg && (dest_mprg.id == dest_mir.meeting_program_id) &&
                existing_lap_ids.empty? && missing_lap_ids.empty? && duplicated_lap_ids.empty?

        # Just update MIR & laps or Insert MPrg + update MIR & laps?
        if dest_mprg.present?
          # Update destination MIR with the correct IDs:
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, " \
                      "#{update_statement} WHERE id = #{dest_mir.id};"
          mir_updates += 1 # (only 1 MIR for event/badge -- see above)

          # Update missing source Laps with correct IDs:
          prepare_script_for_laps(mir_id: dest_mir.id, mprg_id: dest_mprg.id, team_id: final_team_id,
                                  lap_id_list: missing_lap_ids)
          # Update existing dest Laps with correct IDs:
          prepare_script_for_laps(mir_id: dest_mir.id, mprg_id: dest_mprg.id, team_id: final_team_id,
                                  lap_id_list: existing_lap_ids)
          lap_updates += missing_lap_ids.size + existing_lap_ids.size
        else
          # Insert missing MPrg, then do the update:
          @sql_log << 'INSERT INTO meeting_programs (updated_at, category_type_id, gender_type_id, autofilled) ' \
                      "VALUES (NOW(), #{final_category_type_id}, #{@dest.gender_type.id}, 1);"
          mprg_inserts += 1
          @sql_log << 'SELECT LAST_INSERT_ID() INTO @last_id;'
          # Update destination MIR with the correct IDs:
          @sql_log << 'UPDATE meeting_individual_results SET updated_at=NOW(), meeting_program_id=@last_id, ' \
                      "#{update_statement} WHERE id = #{dest_mir.id};"
          mir_updates += 1 # (only 1 MIR for event/badge -- see above)

          # Update missing source Laps with correct IDs:
          prepare_script_for_laps(mir_id: dest_mir.id, mprg_id: '@last_id', team_id: final_team_id,
                                  lap_id_list: missing_lap_ids)
          # Update existing dest Laps with correct IDs:
          prepare_script_for_laps(mir_id: dest_mir.id, mprg_id: '@last_id', team_id: final_team_id,
                                  lap_id_list: existing_lap_ids)
          lap_updates += missing_lap_ids.size + existing_lap_ids.size
        end

        # Delete duplicated source MIR:
        @sql_log << "DELETE FROM meeting_individual_results WHERE id = #{src_mir.id};"
        # Delete also any duplicated laps:
        if duplicated_lap_ids.present?
          @sql_log << "DELETE FROM laps WHERE id IN (#{duplicated_lap_ids.join(', ')});"
          lap_deletes += duplicated_lap_ids.size
        end
      end

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
        where_filter = mir_id_list.size > 1 ? "IN (#{mir_id_list.join(', ')})" : "= #{mir_id_list.first}"
        @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{mprg_id}, " \
                    "meeting_individual_result_id=#{mir_id}, team_id = #{final_team_id} " \
                    "WHERE meeting_individual_result_id #{where_filter};"
      end
      return if lap_id_list.blank?

      where_filter = lap_id_list.size > 1 ? "IN (#{lap_id_list.join(', ')})" : "= #{lap_id_list.first}"
      @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{mprg_id}, " \
                  "meeting_individual_result_id=#{mir_id}, team_id = #{final_team_id} " \
                  "WHERE id #{where_filter};"
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
    def prepare_script_for_disjointed_mrss(badge_id:, mevent_ids:, subset_title: 'source') # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      return if mevent_ids.blank?
      # Handling of relay category changes is currently UNSUPPORTED: (updating it involves potentially changing multiple badges)
      if change_in_category_type_id?
        @checker.warnings << "WARNING: UNSUPPORTED category_type_id change that involves #{subset_title} relays!"
        @checker.warnings << "======== Final 'fixed' category_type_id (ID #{final_category_type_id}) different from original destination (ID #{actual_dest_badge.category_type_id});"
        @checker.warnings << "         involving MRS in events: #{mevent_ids.join(', ')}"
      end

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

      # == Recap on the MEvents domain (for relays):
      # "Shared" events are collected from MRS's badges that are either from
      # source or destination. Thus:
      #
      # 1. if the event is there, then "at least" both MRS should always be there;
      #    (at least -- meaning that in some cases it's possible to find > 1 row for the same event)
      #
      # 2. MANY MRS for 1 MeetingEvent => Loop on each MRS, and update each + find out possible duplicates.
      #    Typical case:
      #    - "4x100 MX" event, stored as a single event, even though it supports 2 different
      #      events: 1x "4x100 MX single gender" + 1x "4x100 MX mixed gender";
      #      in this case, if the rules of a Meeting allows it, a swimmer may enroll in both relays;
      #      => results in 2 MRS for 1 event, but different MPrograms.
      #
      # 3. the actual destination MRS must always be tied to @dest badge
      #
      # 4. NO MProgram changes here, because relay category changes are NOT SUPPORTED.
      mevent_ids.each do |mevent_id|
        # 1 Swimmer => 1 Badge => 1 Event => 1-2 Programs => 1 relay result for each => (many swimmers + relay_laps)
        disjointed_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event, :meeting_relay_result)
                                                        .includes(:meeting_event, :meeting_relay_result)
                                                        .where(badge_id:, 'meeting_events.id': mevent_id)
        if disjointed_mrss.count > 2 || disjointed_mrss.count.zero?
          raise("Found #{disjointed_mrss.count} #{subset_title} MRSs for event #{mevent_id}! (It should always be 1 or 2 max.)")
        end

        # Loop on all MRSS in this event:
        disjointed_mrss.each do |disjointed_mrs|
          disjointed_mrr = disjointed_mrs.meeting_relay_result
          update_statement = update_statement_values(disjointed_mrr)

          # Update needed for MRR too?
          if update_statement.present?
            @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), " \
                        "#{update_statement} WHERE id = #{disjointed_mrr.id};"
            mrr_updates += 1
          end

          # Update needed for MRS even when auto-fixing category? (which shouldn't involve a MProgram change for relays)
          update_statement = update_statement_values(disjointed_mrs)
          lap_count = GogglesDb::RelayLap.where(meeting_relay_swimmer_id: disjointed_mrs.id).count
          next if update_statement.blank? && lap_count.zero? # (no change in category here)

          @sql_log << "UPDATE meeting_relay_swimmers SET updated_at=NOW(), " \
                      "#{update_statement} WHERE id = #{disjointed_mrs.id};"
          mrs_updates += 1
          prepare_script_for_relay_laps(mrs_id: disjointed_mrs.id, team_id: final_team_id, mrs_id_list: [disjointed_mrs.id])
          lap_updates += lap_count
        end
      end

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
    # Note also that during a category "auto-fix" (where destination is supposed to be +nil+),
    # this method does nothing.
    #
    def prepare_script_for_shared_mrss # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      return if @checker.shared_mevent_ids_from_mrss.keys.blank?
      # Handling of relay category changes is currently UNSUPPORTED: (updating it involves potentially changing multiple badges)
      if change_in_category_type_id?
        @checker.warnings << "WARNING: UNSUPPORTED category_type_id change that involves relays (with shared events)!"
        @checker.warnings << "======== Final 'fixed' category_type_id (ID #{final_category_type_id}) different from original destination (ID #{actual_dest_badge.category_type_id});"
        @checker.warnings << "         involving MRS in events: #{mevent_ids.join(', ')}"
      end

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

      # == Recap on the MEvents domain (for relays):
      # "Shared" events are collected from MRS's badges that are either from
      # source or destination. Thus:
      #
      # 1. if the event is there, then "at least" both MRS should always be there;
      #    (at least -- meaning that in some cases it's possible to find > 1 row for the same event)
      #
      # 2. MANY MRS for 1 MeetingEvent => Loop on each MRS, and update each + find out possible duplicates.
      #    Typical case:
      #    - "4x100 MX" event, stored as a single event, even though it supports 2 different
      #      events: 1x "4x100 MX single gender" + 1x "4x100 MX mixed gender";
      #      in this case, if the rules of a Meeting allows it, a swimmer may enroll in both relays;
      #      => results in 2 MRS for 1 event, but different MPrograms.
      #
      # 3. the actual destination MRS must always be tied to @dest badge
      #
      # 4. NO MProgram changes here, because relay category changes are NOT SUPPORTED.
      @checker.shared_mevent_ids_from_mrss.each_key do |mevent_id|
        # 1 Swimmer => 1 Badge => 1 Event => 1-2 Programs => 1 relay result for each => (many swimmers + relay_laps)
        src_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event, :meeting_program, :meeting_relay_result)
                                                 .includes(:meeting_event, :meeting_program, :meeting_relay_result)
                                                 .where(badge_id: @source.id, 'meeting_events.id': mevent_id)
        raise("Unexpected: missing shared source MRS for event #{mevent_id}! (Both src & dest should be still existing)") if src_mrss.blank?
        raise("Found #{src_mrss.count} source MRSs for event #{mevent_id}! (It should always be 1 or 2 max.)") if src_mrss.count > 2 || src_mrss.count.zero?

        # Loop on all MRSS in this event (both source and destination):
        src_mrss.each do |src_mrs| # rubocop:disable Metrics/BlockLength
          # Get all existing & matching dest. MRSs belonging to the same "kind" of MProgram (regardless of category,
          # which could be slightly different between the two due to age miscalculations):
          dest_mrss = GogglesDb::MeetingRelaySwimmer.joins(:meeting_event, :meeting_program, :meeting_relay_result)
                                                    .includes(:meeting_event, :meeting_program, :meeting_relay_result)
                                                    .where(
                                                      badge_id: @dest.id,
                                                      'meeting_programs.gender_type_id': src_mrs.meeting_program.gender_type_id,
                                                      'meeting_events.id': mevent_id
                                                    )
          raise("Unexpected: missing shared destination MRS for event #{mevent_id}! (Both src & dest should be still existing)") if dest_mrss.blank?
          if dest_mrss.count > 2 || dest_mrss.count.zero?
            raise("Found #{dest_mrss.count} destination MRSs for event #{mevent_id}! (It should always be 1 or 2 max.)")
          end

          dest_mrss.each do |dest_mrs|
            # Make sure the overlapping MRSs are different in IDs:
            raise("Unexpected: source MRS (ID #{src_mrs.id}) must be != dest. MRS (ID #{dest_mrs.id})!") if src_mrs.id == dest_mrs.id

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

            # Update needed for dest.MRR?
            dest_mrr = dest_mrs.meeting_relay_result
            update_statement = update_statement_values(dest_mrr)
            if update_statement.present?
              @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), " \
                          "#{update_statement} WHERE id = #{dest_mrr.id};"
              mrr_updates += 1
            end

            # Update needed for dest. MRS? (+ RelayLaps)
            update_statement = update_statement_values(dest_mrs)
            next if update_statement.blank? &&
                    existing_lap_ids.empty? && missing_lap_ids.empty? && duplicated_lap_ids.empty?

            @sql_log << "UPDATE meeting_relay_swimmers SET updated_at=NOW(), " \
                        "#{update_statement} WHERE id = #{dest_mrs.id};"
            mrs_updates += 1

            # Update missing source Laps with correct IDs:
            prepare_script_for_relay_laps(mrs_id: dest_mrs.id, team_id: final_team_id, lap_id_list: missing_lap_ids)

            # Update existing dest Laps with correct IDs:
            prepare_script_for_relay_laps(mrs_id: dest_mrs.id, team_id: final_team_id, lap_id_list: existing_lap_ids)
            lap_updates += missing_lap_ids.size + existing_lap_ids.size

            # Delete duplicated source MRS:
            @sql_log << "DELETE FROM meeting_relay_swimmers WHERE id = #{src_mrs.id};"
            # Delete also any duplicated laps:
            if duplicated_lap_ids.present?
              lap_deletes += duplicated_lap_ids.size
              @sql_log << "DELETE FROM relay_laps WHERE id IN (#{duplicated_lap_ids.join(', ')});"
            end
            # (dest_mrs)
          end
          # (src_mrs)
        end
        # (mevent_id)
      end

      if mrs_updates.positive?
        # (Each time we update a "shared" MRSs we'll have the same number of deletes:)
        @checker.log << "- #{'Shared updates for MRSs'.ljust(44, '.')}: #{mrs_updates}"
        @checker.log << "- #{'Shared deletions for MRSs'.ljust(44, '.')}: #{mrs_updates}"
      end
      @checker.log << "- #{'Updates for MRRs (=> team_id CHANGE!)'.ljust(44, '.')}: #{mrr_updates}" if mrr_updates.positive?
      @checker.log << "- #{'Shared updates for RelayLaps'.ljust(44, '.')}: #{lap_updates}" if lap_updates.positive?
      @checker.log << "- #{'Shared deletions for RelayLaps'.ljust(44, '.')}: #{lap_deletes}" if lap_deletes.present?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Updates the meeting_relay_swimmers_count for each MRR (from the related MRSs).
    # The query is generic and will involve *all* MRR rows, so it's needed just once per script.
    def add_script_for_mrs_counter_update
      # Update MRR's meeting_relay_swimmers_count (generic update for *all* swimmer count in MRR):
      @sql_log << 'UPDATE meeting_relay_results mrr'
      @sql_log << '  JOIN (SELECT meeting_relay_result_id, COUNT(*) AS meeting_relay_swimmers_count ' \
                  'FROM meeting_relay_swimmers GROUP BY meeting_relay_result_id) r'
      @sql_log << '  ON mrr.id = r.meeting_relay_result_id'
      @sql_log << "  SET mrr.meeting_relay_swimmers_count = r.meeting_relay_swimmers_count;\r\n"
    end

    # Updates the relay_laps_count for each MRS (from the related RelayLaps).
    # The query is generic and will involve *all* MRS rows, so it's needed just once per script.
    def add_script_for_relay_lap_counter_update
      # Update MRS's relay_laps_count as above (generic update for relay lap count in MRS):
      @sql_log << 'UPDATE meeting_relay_swimmers mrs'
      @sql_log << '  JOIN (SELECT meeting_relay_swimmer_id, COUNT(*) AS relay_laps_count ' \
                  'FROM relay_laps GROUP BY meeting_relay_swimmer_id) r'
      @sql_log << '  ON mrs.id = r.meeting_relay_swimmer_id'
      @sql_log << "  SET mrs.relay_laps_count = r.relay_laps_count;\r\n"
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
      return if mrs_id.blank? || team_id.blank?

      if mrs_id_list.present?
        where_filter = mrs_id_list.size > 1 ? "IN (#{mrs_id_list.join(', ')})" : "= #{mrs_id_list.first}"
        @sql_log << "UPDATE relay_laps SET updated_at=NOW(), team_id=#{team_id}, " \
                    "meeting_relay_swimmer_id=#{mrs_id} " \
                    "WHERE meeting_relay_swimmer_id #{where_filter};"
      end
      return if lap_id_list.blank?

      where_filter = lap_id_list.size > 1 ? "IN (#{lap_id_list.join(', ')})" : "= #{lap_id_list.first}"
      @sql_log << "UPDATE relay_laps SET updated_at=NOW(), team_id=#{team_id}, " \
                  "meeting_relay_swimmer_id=#{mrs_id} " \
                  "WHERE id #{where_filter};"
    end
    #-- ------------------------------------------------------------------------
    #++

    #-- ------------------------------------------------------------------------
    #                          MEntries (deletable when in conflict)
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "MEntries update" phase involving all MEntries that
    # belong to "disjointed" events and either belong to just the source or just the destination Badge.
    #
    # This somewhat similar to the "MIRs update" phase, but without laps.
    # Also, any conflicting MEntry is deletable.
    #
    # == Params
    # * +badge_id+: filtering badge ID (either source or dest.);
    # * +mevent_ids+: list of event IDs that are "disjointed" in usage between the two badges
    #                 and thus include MEntries only from either the source or the destination Badges
    #                 (but not both).
    # * +subset_title+: string title to identify this domain subset in the log.
    #
    def prepare_script_for_disjointed_ments(badge_id:, mevent_ids:, subset_title: 'source') # rubocop:disable Metrics/AbcSize
      return if mevent_ids.blank?

      ments_updates = 0
      mprg_inserts = 0
      @sql_log << "-- (#{subset_title}-only MEntries) --"

      mevent_ids.each do |mevent_id|
        # NOTE: for each meeting event: 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 meeting entry
        disjointed_ments = GogglesDb::MeetingEntry.joins(:meeting_event)
                                                  .where(badge_id:, 'meeting_events.id': mevent_id)
        raise("Found #{disjointed_ments.count} #{subset_title} MEntries for event #{mevent_id}!") if disjointed_ments.count != 1

        final_mentry = disjointed_ments.first
        # Destination program may or may not be already there when there's a difference in category:
        dest_mprg = GogglesDb::MeetingProgram.where(meeting_event_id: mevent_id, category_type_id: final_category_type_id).first
        update_statement = update_statement_values(final_mentry)
        # Nothing to update?
        next if update_statement.blank? &&
                dest_mprg && (dest_mprg.id == final_mentry.meeting_program_id)

        # Simple update or Insert MPrg too?
        if dest_mprg.present?
          @sql_log << "UPDATE meeting_entries SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, " \
                      "#{update_statement} WHERE id = #{final_mentry.id};"
          ments_updates += 1 # (only 1 MEntry for event -- see above)
        else
          @sql_log << 'INSERT INTO meeting_programs (updated_at, category_type_id, gender_type_id, autofilled) ' \
                      "VALUES (NOW(), #{final_category_type_id}, #{@source.gender_type.id}, 1);"
          mprg_inserts += 1
          @sql_log << 'SELECT LAST_INSERT_ID() INTO @last_id;'
          # Move source-only MEntry using correct IDs:
          @sql_log << 'UPDATE meeting_entries SET updated_at=NOW(), meeting_program_id=@last_id, ' \
                      "#{update_statement} WHERE id = #{final_mentry.id};"
          ments_updates += 1 # (only 1 MEntry for event -- see above)
        end
      end

      @checker.log << "- #{'Updates for MEntries'.ljust(44, '.')}: #{ments_updates}" if ments_updates.positive?
      @checker.log << "- #{'Inserts for MPrograms'.ljust(44, '.')}: #{mprg_inserts}" if mprg_inserts.positive?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "MEntries update" phase involving all MEntries that belong to
    # an event that is "shared" between both the source & destination Badge.
    #
    # This somewhat similar to the "MIRs update" phase, but without laps.
    # Also, any conflicting MEntry is deletable.
    def prepare_script_for_shared_ments # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      return if @checker.shared_mevent_ids_from_ments.keys.blank?

      mentry_updates = 0
      mprg_inserts = 0
      @sql_log << '-- (shared MEntries domain) --'

      @checker.shared_mevent_ids_from_ments.each_key do |mevent_id|
        # NOTE: for each meeting event: 1 Swimmer => 1 Badge => 1 Event => 1 Program => 1 meeting entry
        src_mentry = GogglesDb::MeetingEntry.joins(:meeting_event).includes(:meeting_event)
                                            .where(badge_id: @source.id, 'meeting_events.id': mevent_id)
                                            .first
        dest_mentry = GogglesDb::MeetingEntry.joins(:meeting_event).includes(:meeting_event)
                                             .where(badge_id: @dest.id, 'meeting_events.id': mevent_id)
                                             .first
        raise("Unexpected: missing shared source MEntry for event #{mevent_id}! (Both should be still existing)") if src_mentry.blank?
        raise("Unexpected: missing shared destination MEntry for event #{mevent_id}! (Both should be still existing)") if dest_mentry.blank?
        # Make sure the overlapping MEntrys are different in IDs:
        raise("Unexpected: source MEntry (ID #{src_mentry.id}) must be != dest. MEntry (ID #{dest_mentry.id})!") if src_mentry.id == dest_mentry.id

        # WARNING: NOT HANDLING here the very rare case in which relays MEntry are linked to different programs belonging to the same event!
        #          (e.g.: "4x100 MX" both storing events for single-gender & mixed-gender relays)

        # Destination program may or may not be already there when there's a difference in category:
        dest_mprg = GogglesDb::MeetingProgram.where(meeting_event_id: mevent_id, category_type_id: final_category_type_id).first
        update_statement = update_statement_values(dest_mentry)

        # Nothing to update?
        next if update_statement.blank? &&
                dest_mprg && (dest_mprg.id == dest_mentry.meeting_program_id)

        # Simple update or Insert MPrg too?
        if dest_mprg.present?
          # Update destination MEntry with the correct IDs:
          @sql_log << "UPDATE meeting_entries SET updated_at=NOW(), meeting_program_id=#{dest_mprg.id}, " \
                      "WHERE id=#{dest_mentry.id};"
                      "#{update_statement} WHERE id = #{dest_mentry.id};"
          mentry_updates += 1 # (only 1 MEntry for event/badge -- see above)
        else
          @sql_log << 'INSERT INTO meeting_programs (updated_at, category_type_id, gender_type_id, autofilled) ' \
                      "VALUES (NOW(), #{final_category_type_id}, #{@source.gender_type.id}, 1);"
          mprg_inserts += 1
          @sql_log << 'SELECT LAST_INSERT_ID() INTO @last_id;'
          # Update destination MEntry with the correct IDs:
          @sql_log << 'UPDATE meeting_entries SET updated_at=NOW(), meeting_program_id=@last_id, ' \
                      "#{update_statement} WHERE id = #{dest_mentry.id};"
          mentry_updates += 1 # (only 1 MEntry for event/badge -- see above)
        end
        # Delete duplicated source MEntry:
        @sql_log << "DELETE FROM meeting_entries WHERE id=#{src_mentry.id};"
      end

      if mentry_updates.positive?
        @checker.log << "- #{'Shared updates for MEntrys'.ljust(44, '.')}: #{mentry_updates}"
        @checker.log << "- #{'Shared deletions for MEntrys'.ljust(44, '.')}: #{mentry_updates}"
      end
      @checker.log << "- #{'Shared insertions for MPrograms'.ljust(44, '.')}: #{mprg_inserts}" if mprg_inserts.positive?
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
