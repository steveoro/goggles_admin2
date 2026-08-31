# frozen_string_literal: true

module Merge
  #
  # = Merge::Team
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #   - build:    20260207
  #
  class Team # rubocop:disable Metrics/ClassLength
    attr_reader :sql_log, :checker, :source, :dest

    # Allows a source Team to be merged into a destination one, producing a single-transaction
    # SQL script that handles all sub-entities including full duplicate elimination.
    #
    # For each shared season, shared badge couples (same swimmer on both teams) are merged
    # inline using Merge::Badge. Orphan merged badges (no kept counterpart) get a simple
    # team_id / team_affiliation_id update. All remaining TA-linked entities are then
    # updated with a catch-all pass.
    #
    # At the end, Merge::DuplicateResultCleaner runs per shared season as a safety net.
    #
    # === Involved entities (in alphabetical order):
    #
    # - Badge                   (#team_id, #team_affiliation_id)
    # - ComputedSeasonRanking   (#team_id)
    # - GoggleCup               (#team_id)
    # - IndividualRecord        (#team_id)
    # - Lap                     (#team_id)
    # - ManagedAffiliation      (#team_affiliation_id)
    # - MeetingEntry            (#team_id, #team_affiliation_id)
    # - MeetingEventReservation (#team_id) — deleted (deprecated)
    # - MeetingReservation      (#team_id) — deleted (deprecated)
    # - MeetingRelayReservation (#team_id) — deleted (deprecated)
    # - MeetingIndividualResult (#team_id, #team_affiliation_id)
    # - MeetingRelayResult      (#team_id, #team_affiliation_id)
    # - MeetingTeamScore        (#team_id, #team_affiliation_id)
    # - Meeting                 (#home_team_id)
    # - RelayLap                (#team_id)
    # (- Team)
    # - TeamAffiliation         (#team_id) (*)unique idx with team_id & season_id
    # - TeamAlias               (#team_id) (*)unique idx with team_id & name
    # - TeamLapTemplate         (#team_id)
    # - UserWorkshop            (#team_id)
    #
    # == Additional notes:
    # This merge class won't actually touch the DB: it will just prepare the script so
    # that this process can be replicated on any DB that is in sync with the current one.
    #
    # == Params
    # - <tt>:source</tt> => source Team row, *required*
    # - <tt>:dest</tt>   => destination Team row, *required*
    #
    # - <tt>:skip_columns</tt> => Force this to +true+ to avoid updating the destination row columns
    #   with the values stored in source; default: +false+.
    #
    # - <tt>:keep_as_alias</tt> => Set to +true+ to keep the overwritten team as an alias of the
    #   resulting team. The surviving "main" team is selected by <tt>skip_columns</tt>:
    #   when +false+, <tt>source</tt> is kept and <tt>dest</tt> is deleted;
    #   when +true+, <tt>dest</tt> is kept and <tt>source</tt> is deleted.
    #   Default: +false+ (legacy behaviour).
    #
    def initialize(source:, dest:, skip_columns: false, keep_as_alias: false)
      raise(ArgumentError, 'Both source and destination must be Teams!') unless source.is_a?(GogglesDb::Team) && dest.is_a?(GogglesDb::Team)

      @source = source.decorate
      @dest = dest.decorate
      @skip_columns = skip_columns
      @keep_as_alias = keep_as_alias

      # Determine which team survives (kept) and which is deleted (merged):
      if @keep_as_alias
        @kept_team = @skip_columns ? @dest : @source
        @merged_team = @skip_columns ? @source : @dest
      else
        @kept_team = @dest
        @merged_team = @source
      end

      @checker = TeamChecker.new(source: @merged_team.object, dest: @kept_team.object)
      @sql_log = []
      @dest_ta_sql_ref_by_season = {}
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the merge script inside a single transaction.
    # Contrary to other Merge classes, this strategy class does not halt in case of conflicts
    # and always displays the checker report.
    #
    # == Script phases:
    # 1. Delete deprecated reservations for the merged team
    # 2. Per-season TA processing (badge sub-merges, orphan updates, remaining TA links)
    # 3. Team-only link updates
    # 4. DuplicateResultCleaner safety net (per shared season)
    # 5. Main team column updates, alias handling & merged team deletion
    #
    def prepare
      return if @sql_log.present? # Don't allow a second run

      @checker.run
      @checker.display_report

      prepare_script_header
      prepare_script_for_reservation_cleanup
      seed_dest_ta_sql_refs

      # Per-season TeamAffiliation processing:
      GogglesDb::TeamAffiliation.where(team_id: @merged_team.id).order(:season_id).each do |merged_ta|
        kept_ta = GogglesDb::TeamAffiliation.where(season_id: merged_ta.season_id, team_id: @kept_team.id).first
        prepare_script_for_season(merged_ta, kept_ta)
      end

      prepare_script_for_team_only_links
      prepare_script_for_remaining_team_references
      prepare_script_for_duplicate_cleanup
      prepare_kept_column_updates
      prepare_script_for_alias_handling

      @sql_log << "DELETE FROM teams WHERE id=#{@merged_team.id};"
      @sql_log << "\r\nCOMMIT;"
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the <tt>#log</tt> array from the internal TeamChecker instance.
    delegate :log, to: :@checker
    #-- ------------------------------------------------------------------------
    #++

    private

    # Adds the transaction header to @sql_log.
    def prepare_script_header
      @sql_log << "\r\n-- Merge team (#{@merged_team.id}) #{@merged_team.display_label} |=> (#{@kept_team.id}) #{@kept_team.display_label}"
      @sql_log << "-- keep_as_alias: #{@keep_as_alias}, skip_columns: #{@skip_columns}"
      # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''
    end

    # Deletes all merged-team reservation rows (deprecated entities).
    def prepare_script_for_reservation_cleanup
      @sql_log << '-- Delete all merged-team reservations (deprecated entities)'
      @sql_log << "DELETE FROM meeting_event_reservations WHERE team_id=#{@merged_team.id};"
      @sql_log << "DELETE FROM meeting_relay_reservations WHERE team_id=#{@merged_team.id};"
      @sql_log << "DELETE FROM meeting_reservations WHERE team_id=#{@merged_team.id};"
      @sql_log << ''
    end

    # Dispatches per-season processing depending on whether a kept TA exists.
    def prepare_script_for_season(merged_ta, kept_ta)
      if kept_ta
        prepare_script_for_season_with_kept_ta(merged_ta, kept_ta)
      else
        prepare_script_for_season_recycle_ta(merged_ta)
      end
    end

    # Processes a merged TA when a matching kept TA exists:
    # 1. Badge sub-merges for shared swimmers
    # 2. Orphan badge updates
    # 3. Catch-all for remaining TA-linked entities
    # 4. Delete merged TA
    #
    # rubocop:disable-next Metrics/AbcSize
    def prepare_script_for_season_with_kept_ta(merged_ta, kept_ta)
      register_dest_ta_sql_ref(merged_ta.season_id, kept_ta.id)
      @sql_log << "\r\n-- Season #{merged_ta.season_id}, kept TA found #{kept_ta.id}, processing merged TA #{merged_ta.id}:"

      # Badge sub-merges for shared badge couples:
      prepare_script_for_badge_merges(merged_ta.season_id)

      # Orphan merged badges (no kept counterpart) — simple team_id + TA update:
      prepare_script_for_orphan_badges(merged_ta.season_id, kept_ta)

      # Catch-all for remaining TA-linked entities (rows not already handled by badge merges):
      @sql_log << "-- Remaining TA-linked entity updates for merged TA #{merged_ta.id}:"
      @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@kept_team.id}, team_affiliation_id=#{kept_ta.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << 'UPDATE managed_affiliations SET updated_at=NOW(), ' \
                  "team_affiliation_id=#{kept_ta.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << "UPDATE meeting_entries SET updated_at=NOW(), team_id=#{@kept_team.id}, " \
                  "team_affiliation_id=#{kept_ta.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << 'UPDATE meeting_individual_results SET updated_at=NOW(), ' \
                  "team_id=#{@kept_team.id}, team_affiliation_id=#{kept_ta.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), team_id=#{@kept_team.id}, " \
                  "team_affiliation_id=#{kept_ta.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << "UPDATE meeting_team_scores SET updated_at=NOW(), team_id=#{@kept_team.id}, " \
                  "team_affiliation_id=#{kept_ta.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << "DELETE FROM team_affiliations WHERE id=#{merged_ta.id};"
    end

    # Processes a merged TA when no kept TA exists — recycle the merged TA by updating its team_id.
    def prepare_script_for_season_recycle_ta(merged_ta)
      register_dest_ta_sql_ref(merged_ta.season_id, merged_ta.id)
      @sql_log << "\r\n-- Season #{merged_ta.season_id}, kept TA MISSING, recycling merged TA #{merged_ta.id} (updating only team references):"
      @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_affiliation_id=#{merged_ta.id};"
      # (managed_affiliations table is already ok, as merged will become "new kept")
      @sql_log << "UPDATE meeting_entries SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << "UPDATE meeting_team_scores SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_affiliation_id=#{merged_ta.id};"
      @sql_log << "UPDATE team_affiliations SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE id=#{merged_ta.id};"
    end

    # Composes Merge::Badge sub-merges for each shared badge couple in the given season.
    # Each badge merger's sql_log is appended (without its own transaction wrapper).
    # If a single badge merge fails, a warning is logged and processing continues.
    def prepare_script_for_badge_merges(season_id)
      couples = @checker.shared_badge_couples_by_season[season_id]
      return if couples.blank?

      @sql_log << "-- Badge sub-merges for #{couples.size} shared swimmer(s) in season #{season_id}:"
      couples.each do |src_badge, dest_badge|
        next if src_badge.blank? || dest_badge.blank?

        begin
          badge_merger = Merge::Badge.new(source: src_badge, dest: dest_badge, keep_dest_team: true, force: true)
          badge_merger.prepare
          @sql_log.concat(badge_merger.sql_log)
        rescue StandardError => e
          @sql_log << "-- WARNING: Badge merge failed for badge #{src_badge.id} => #{dest_badge.id}: #{e.message}"
          @sql_log << '-- (Manual merge may be needed for this badge couple)'
        end
        @sql_log << ''
      end
    end

    # Updates orphan merged badges (no kept counterpart for the same swimmer+season).
    def prepare_script_for_orphan_badges(season_id, kept_ta)
      orphans = @checker.orphan_src_badges_by_season[season_id]
      return if orphans.blank?

      orphan_ids = orphans.map(&:id)
      @sql_log << "-- Orphan badge updates for season #{season_id} (#{orphans.size} badge(s)):"
      @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@kept_team.id}, team_affiliation_id=#{kept_ta.id} WHERE id IN (#{orphan_ids.join(', ')});"
    end

    # Prepares the SQL text for the "Team update" phase involving all entities that have a
    # foreign key to the merged Team ID.
    #
    # == Team is bound to:
    # - ComputedSeasonRanking   (#team_id)
    # - GoggleCup               (#team_id)
    # - IndividualRecord        (#team_id)
    # - Lap                     (#team_id)
    # - Meeting                 (#home_team_id)
    # - RelayLap                (#team_id)
    # - TeamLapTemplate         (#team_id)
    # - UserWorkshop            (#team_id)
    #
    def prepare_script_for_team_only_links # rubocop:disable Metrics/AbcSize
      @sql_log << "\r\n-- Team-only updates (merged Team #{@merged_team.id} |=> kept #{@kept_team.id})"
      @sql_log << "UPDATE computed_season_rankings SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_id=#{@merged_team.id};"
      @sql_log << "UPDATE goggle_cups SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_id=#{@merged_team.id};"
      @sql_log << "UPDATE individual_records SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_id=#{@merged_team.id};"
      @sql_log << "UPDATE laps SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_id=#{@merged_team.id};"
      @sql_log << "UPDATE meetings SET updated_at=NOW(), home_team_id=#{@kept_team.id} WHERE home_team_id=#{@merged_team.id};"
      @sql_log << "UPDATE relay_laps SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_id=#{@merged_team.id};"
      @sql_log << "UPDATE team_lap_templates SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_id=#{@merged_team.id};"
      @sql_log << "UPDATE user_workshops SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_id=#{@merged_team.id};"
    end

    # Global safety net: catches badges (and other dual-FK entities) still referencing the
    # merged team_id after per-season TA processing. This covers badges in seasons where the
    # merged team has NO TeamAffiliation, or badges whose team_affiliation_id didn't match any
    # merged TA.
    def prepare_script_for_remaining_team_references # rubocop:disable Metrics/AbcSize
      remaining_badges = GogglesDb::Badge.where(team_id: @merged_team.id)
      if remaining_badges.exists?
        @sql_log << "\r\n-- Global safety net: #{remaining_badges.count} badge(s) still referencing merged team #{@merged_team.id}"
        remaining_badges.group_by(&:season_id).each do |season_id, badges|
          badge_ids = badges.map(&:id).join(', ')
          ta_sql_ref = @dest_ta_sql_ref_by_season[season_id]
          unless ta_sql_ref
            # No known kept TA for this season — create one (if needed), then update badges
            ta_sql_ref = "@dest_ta_#{season_id}"
            @sql_log << "-- WARNING: creating kept TA for season #{season_id} (was missing)"
            @sql_log << 'INSERT INTO team_affiliations (team_id, season_id, name, created_at, updated_at) ' \
                        "SELECT #{@kept_team.id}, #{season_id}, '#{escaped_dest_ta_name}', NOW(), NOW() " \
                        "WHERE NOT EXISTS (SELECT 1 FROM team_affiliations WHERE season_id=#{season_id} AND team_id=#{@kept_team.id});"
            @sql_log << "SET #{ta_sql_ref} = (SELECT id FROM team_affiliations WHERE season_id=#{season_id} AND team_id=#{@kept_team.id} LIMIT 1);"
            register_dest_ta_sql_ref(season_id, ta_sql_ref)
          end

          @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@kept_team.id}, " \
                      "team_affiliation_id=#{ta_sql_ref} WHERE id IN (#{badge_ids});"
        end
      end

      # Same pattern for other dual-FK entities that reference both team_id and team_affiliation_id
      %w[meeting_individual_results meeting_relay_results meeting_entries meeting_team_scores].each do |table|
        count = ActiveRecord::Base.connection.select_value(
          "SELECT COUNT(*) FROM #{table} WHERE team_id=#{@merged_team.id}"
        ).to_i
        next unless count.positive?

        @sql_log << "-- Safety net: #{count} #{table} row(s) still referencing merged team #{@merged_team.id}"
        @sql_log << "UPDATE #{table} SET updated_at=NOW(), team_id=#{@kept_team.id} WHERE team_id=#{@merged_team.id};"
      end
    end

    # Runs Merge::DuplicateResultCleaner for each shared season as a safety net.
    def prepare_script_for_duplicate_cleanup
      return if @checker.shared_season_ids.blank?

      @sql_log << "\r\n-- DuplicateResultCleaner safety net --"
      @checker.shared_season_ids.each do |season_id|
        season = GogglesDb::Season.find_by(id: season_id)
        next unless season

        cleaner = Merge::DuplicateResultCleaner.new(season:, autofix: true)
        cleaner.prepare
        next if cleaner.sql_log.blank?

        @sql_log.concat(cleaner.sql_log)
      end
    end

    # Overwrites/updates the kept team columns at the end.
    # rubocop:disable-next Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    def prepare_kept_column_updates
      attrs = []

      if @keep_as_alias
        # Combine both teams' names and aliases into a single, deduplicated alias list:
        attrs << "name_variations=#{quote_value(build_name_variations)}"

        unless @skip_columns
          # Use the kept team's own main columns:
          attrs << "name=#{quote_value(@kept_team.name)}"
          attrs << "editable_name=#{quote_value(@kept_team.editable_name)}" if @kept_team.editable_name.present?
          attrs << "city_id=#{@kept_team.city_id}" if @kept_team.city_id.present?
        end
      elsif @skip_columns
        # Legacy: update just the name variations, appending the merged team's name:
        kept_variations = @kept_team.name_variations.to_s
        name_variations = kept_variations.include?(@merged_team.name) ? kept_variations : "#{kept_variations};#{@merged_team.name}"
        attrs << "name_variations=#{quote_value(name_variations)}"
      else
        # Legacy: overwrite kept with merged columns:
        attrs << "name=#{quote_value(@merged_team.name)}"
        attrs << "editable_name=#{quote_value(@merged_team.editable_name)}" if @merged_team.editable_name.present?
        attrs << "name_variations=#{quote_value(@merged_team.name_variations)}" if @merged_team.name_variations.present?
        attrs << "city_id=#{@merged_team.city_id}" if @merged_team.city_id.present?
      end

      @sql_log << "\r\nUPDATE teams SET updated_at=NOW(), #{attrs.join(', ')} WHERE id=#{@kept_team.id};"
    end

    # Moves the merged team's TeamAlias rows to the kept team, deleting any that would
    # violate the unique (team_id, name) index. Also emits a final cleanup delete.
    def prepare_script_for_alias_handling
      if @keep_as_alias
        merged_aliases = GogglesDb::TeamAlias.where(team_id: @merged_team.id)
        if merged_aliases.exists?
          @sql_log << "\r\n-- Moving team_aliases from merged team #{@merged_team.id} to kept team #{@kept_team.id}"
          kept_alias_names = GogglesDb::TeamAlias.where(team_id: @kept_team.id).pluck(:name).to_set

          merged_aliases.each do |team_alias|
            if kept_alias_names.include?(team_alias.name)
              @sql_log << "DELETE FROM team_aliases WHERE id=#{team_alias.id}; -- duplicate of kept team alias"
            else
              @sql_log << "UPDATE team_aliases SET team_id=#{@kept_team.id}, updated_at=NOW() WHERE id=#{team_alias.id};"
              kept_alias_names << team_alias.name
            end
          end
        end
      else
        @sql_log << ''
        @sql_log << "DELETE FROM team_aliases WHERE team_id=#{@merged_team.id};"
      end
    end

    def seed_dest_ta_sql_refs
      GogglesDb::TeamAffiliation.where(team_id: @kept_team.id).pluck(:season_id, :id).each do |season_id, ta_id|
        register_dest_ta_sql_ref(season_id, ta_id)
      end
    end

    def register_dest_ta_sql_ref(season_id, sql_ref)
      @dest_ta_sql_ref_by_season[season_id] = sql_ref.to_s
    end

    # Returns a properly SQL-quoted string value using ActiveRecord's connection quoting.
    # This handles both single and double quotes correctly.
    def quote_value(value)
      ActiveRecord::Base.connection.quote(value.to_s)
    end

    def escaped_dest_ta_name
      quote_value(@kept_team.editable_name.presence || @kept_team.name)
    end

    # Builds a deduplicated, semicolon-separated alias list for the kept team from
    # both the kept and the merged team names, name_variations and team_aliases.
    # rubocop:disable-next Metrics/AbcSize
    def build_name_variations
      tokens = []

      tokens << @kept_team.name
      tokens << @kept_team.editable_name if @kept_team.editable_name.present? && @kept_team.editable_name != @kept_team.name
      tokens.concat tokenize(@kept_team.name_variations)

      tokens << @merged_team.name
      tokens << @merged_team.editable_name if @merged_team.editable_name.present? && @merged_team.editable_name != @merged_team.name
      tokens.concat tokenize(@merged_team.name_variations)

      if @keep_as_alias
        merged_alias_names = GogglesDb::TeamAlias.where(team_id: @merged_team.id).pluck(:name)
        tokens.concat merged_alias_names
      end

      tokens.uniq.map(&:strip).compact_blank.join(';')
    end

    # Splits a stored alias list on comma or semicolon and returns clean tokens.
    def tokenize(variations)
      return [] if variations.blank?

      variations.to_s.split(/[,;]/).map(&:strip).compact_blank
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
