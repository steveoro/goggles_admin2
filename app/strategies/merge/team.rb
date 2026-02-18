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
    # inline using Merge::Badge. Orphan source badges (no dest counterpart) get a simple
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
    def initialize(source:, dest:, skip_columns: false)
      raise(ArgumentError, 'Both source and destination must be Teams!') unless source.is_a?(GogglesDb::Team) && dest.is_a?(GogglesDb::Team)

      @skip_columns = skip_columns
      @checker = TeamChecker.new(source:, dest:)
      @source = @checker.source
      @dest = @checker.dest
      @sql_log = []
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the merge script inside a single transaction.
    # Contrary to other Merge classes, this strategy class does not halt in case of conflicts
    # and always displays the checker report.
    #
    # == Script phases:
    # 1. Delete deprecated reservations for the source team
    # 2. Per-season TA processing (badge sub-merges, orphan updates, remaining TA links)
    # 3. Team-only link updates
    # 4. DuplicateResultCleaner safety net (per shared season)
    # 5. Destination column updates & source team deletion
    #
    def prepare
      return if @sql_log.present? # Don't allow a second run

      @checker.run
      @checker.display_report

      prepare_script_header
      prepare_script_for_reservation_cleanup

      # Per-season TeamAffiliation processing:
      GogglesDb::TeamAffiliation.where(team_id: @source.id).order(:season_id).each do |src_ta|
        dest_ta = GogglesDb::TeamAffiliation.where(season_id: src_ta.season_id, team_id: @dest.id).first
        prepare_script_for_season(src_ta, dest_ta)
      end

      prepare_script_for_team_only_links
      prepare_script_for_duplicate_cleanup
      prepare_dest_column_updates

      @sql_log << ''
      @sql_log << "DELETE FROM team_aliases WHERE team_id=#{@source.id};"
      @sql_log << "DELETE FROM teams WHERE id=#{@source.id};"
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
      @sql_log << "\r\n-- Merge team (#{@source.id}) #{@source.display_label} |=> (#{@dest.id}) #{@dest.display_label}"
      # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''
    end

    # Deletes all source-team reservation rows (deprecated entities).
    def prepare_script_for_reservation_cleanup
      @sql_log << '-- Delete all source-team reservations (deprecated entities)'
      @sql_log << "DELETE FROM meeting_event_reservations WHERE team_id=#{@source.id};"
      @sql_log << "DELETE FROM meeting_relay_reservations WHERE team_id=#{@source.id};"
      @sql_log << "DELETE FROM meeting_reservations WHERE team_id=#{@source.id};"
      @sql_log << ''
    end

    # Dispatches per-season processing depending on whether a destination TA exists.
    def prepare_script_for_season(src_ta, dest_ta)
      if dest_ta
        prepare_script_for_season_with_dest_ta(src_ta, dest_ta)
      else
        prepare_script_for_season_recycle_ta(src_ta)
      end
    end

    # Processes a source TA when a matching dest TA exists:
    # 1. Badge sub-merges for shared swimmers
    # 2. Orphan badge updates
    # 3. Catch-all for remaining TA-linked entities
    # 4. Delete source TA
    #
    # rubocop:disable Metrics/AbcSize
    def prepare_script_for_season_with_dest_ta(src_ta, dest_ta)
      @sql_log << "\r\n-- Season #{src_ta.season_id}, dest. TA found #{dest_ta.id}, processing source TA #{src_ta.id}:"

      # Badge sub-merges for shared badge couples:
      prepare_script_for_badge_merges(src_ta.season_id)

      # Orphan source badges (no dest counterpart) — simple team_id + TA update:
      prepare_script_for_orphan_badges(src_ta.season_id, dest_ta)

      # Catch-all for remaining TA-linked entities (rows not already handled by badge merges):
      @sql_log << "-- Remaining TA-linked entity updates for source TA #{src_ta.id}:"
      @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "UPDATE managed_affiliations SET updated_at=NOW(), team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "UPDATE meeting_entries SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << 'UPDATE meeting_individual_results SET updated_at=NOW(), ' \
                  "team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "UPDATE meeting_team_scores SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "DELETE FROM team_affiliations WHERE id=#{src_ta.id};"
    end
    # rubocop:enable Metrics/AbcSize

    # Processes a source TA when no dest TA exists — recycle the source TA by updating its team_id.
    def prepare_script_for_season_recycle_ta(src_ta)
      @sql_log << "\r\n-- Season #{src_ta.season_id}, dest. TA MISSING, recycling source TA #{src_ta.id} (updating only team references):"
      @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
      # (managed_affiliations table is already ok, as src will become "new dest")
      @sql_log << "UPDATE meeting_entries SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "UPDATE meeting_team_scores SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
      @sql_log << "UPDATE team_affiliations SET updated_at=NOW(), team_id=#{@dest.id} WHERE id=#{src_ta.id};"
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

    # Updates orphan source badges (no dest counterpart for the same swimmer+season).
    def prepare_script_for_orphan_badges(season_id, dest_ta)
      orphans = @checker.orphan_src_badges_by_season[season_id]
      return if orphans.blank?

      orphan_ids = orphans.map(&:id)
      @sql_log << "-- Orphan badge updates for season #{season_id} (#{orphans.size} badge(s)):"
      @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE id IN (#{orphan_ids.join(', ')});"
    end

    # Prepares the SQL text for the "Team update" phase involving all entities that have a
    # foreign key to the source Team ID.
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
      @sql_log << "\r\n-- Team-only updates (source Team #{@source.id} |=> dest #{@dest.id})"
      @sql_log << "UPDATE computed_season_rankings SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE goggle_cups SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE individual_records SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE laps SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE meetings SET updated_at=NOW(), home_team_id=#{@dest.id} WHERE home_team_id=#{@source.id};"
      @sql_log << "UPDATE relay_laps SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE team_lap_templates SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE user_workshops SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
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

    # Overwrites commonly used destination team columns at the end.
    def prepare_dest_column_updates
      attrs = []
      if @skip_columns
        # Update just the name variations:
        dest_variations = @dest.name_variations.to_s
        name_variations = dest_variations.include?(@source.name) ? dest_variations : "#{dest_variations};#{@source.name}"
        attrs << "name_variations=\"#{name_variations}\""
      else
        # Update only attributes with values (don't overwrite existing with nulls):
        attrs << "name=\"#{@source.name}\""
        attrs << "editable_name=\"#{@source.editable_name}\"" if @source.editable_name.present?
        attrs << "name_variations=\"#{@source.name_variations}\"" if @source.name_variations.present?
        attrs << "city_id=#{@source.city_id}" if @source.city_id.present?
      end
      @sql_log << "\r\nUPDATE teams SET updated_at=NOW(), #{attrs.join(', ')} WHERE id=#{@dest.id};"
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
