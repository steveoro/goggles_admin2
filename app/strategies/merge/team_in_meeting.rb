# frozen_string_literal: true

module Merge
  # = Merge::TeamInMeeting
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #   - build:    20250126
  #
  # Merges wrongly-assigned team results within a *single* meeting.
  #
  # Typical use case: fixing duplicated results when the same team was assigned
  # to a similarly-named team during data import.
  #
  # This strategy:
  # 1. Updates badges for swimmers participating with the wrong team
  # 2. Updates team_id and team_affiliation_id across laps, MIRs, relay_laps, MRRs, MRSs
  # 3. Deletes duplicate rows that result from the merge
  #
  # == Usage:
  #   merger = Merge::TeamInMeeting.new(meeting: meeting, src_team: wrong_team, dest_team: good_team)
  #   merger.display_report  # Preview what will be changed
  #   merger.prepare         # Generate SQL statements
  #   # Then use the rake task helper to save/execute the SQL
  #
  class TeamInMeeting
    attr_reader :meeting, :src_team, :dest_team, :season,
                :src_ta, :dest_ta, :sql_log, :full_report, :index

    # == Params:
    # - <tt>:meeting</tt> => Meeting instance, *required*
    # - <tt>:src_team</tt> => source (wrong) Team instance, *required*
    # - <tt>:dest_team</tt> => destination (correct) Team instance, *required*
    # - <tt>:full_report</tt> => when true, displays all IDs (10 per row) and badge merge pairs (default: false)
    # - <tt>:index</tt> => starting file index for suggested badge merge commands (default: 1)
    #
    def initialize(meeting:, src_team:, dest_team:, full_report: false, index: 1)
      raise(ArgumentError, 'meeting must be a Meeting!') unless meeting.is_a?(GogglesDb::Meeting)
      raise(ArgumentError, 'src_team must be a Team!') unless src_team.is_a?(GogglesDb::Team)
      raise(ArgumentError, 'dest_team must be a Team!') unless dest_team.is_a?(GogglesDb::Team)
      raise(ArgumentError, 'Identical source and destination teams!') if src_team.id == dest_team.id

      @meeting = meeting
      @src_team = src_team
      @dest_team = dest_team
      @season = meeting.season
      @sql_log = []
      @full_report = full_report
      @index = index

      resolve_team_affiliations
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the ActiveRecord Relation of Laps for the source team in this meeting.
    def src_laps
      @src_laps ||= laps_for_team(@src_team.id)
    end

    # Returns the ActiveRecord Relation of Laps for the destination team in this meeting.
    def dest_laps
      @dest_laps ||= laps_for_team(@dest_team.id)
    end

    # Returns the ActiveRecord Relation of MIRs for the source team in this meeting.
    def src_mirs
      @src_mirs ||= mirs_for_team(@src_team.id)
    end

    # Returns the ActiveRecord Relation of MIRs for the destination team in this meeting.
    def dest_mirs
      @dest_mirs ||= mirs_for_team(@dest_team.id)
    end

    # Returns the ActiveRecord Relation of RelayLaps for the source team in this meeting.
    def src_relay_laps
      @src_relay_laps ||= relay_laps_for_team(@src_team.id)
    end

    # Returns the ActiveRecord Relation of RelayLaps for the destination team in this meeting.
    def dest_relay_laps
      @dest_relay_laps ||= relay_laps_for_team(@dest_team.id)
    end

    # Returns the ActiveRecord Relation of MRRs for the source team in this meeting.
    def src_mrrs
      @src_mrrs ||= mrrs_for_team(@src_team.id)
    end

    # Returns the ActiveRecord Relation of MRRs for the destination team in this meeting.
    def dest_mrrs
      @dest_mrrs ||= mrrs_for_team(@dest_team.id)
    end

    # Returns Badges (via MIR swimmers) that need team_id update.
    # These are badges where the swimmer participated with the wrong team,
    # and no badge exists for the correct team.
    def mir_badges_to_update
      @mir_badges_to_update ||= GogglesDb::Badge
                                .joins(<<~SQL.squish)
                                  INNER JOIN meeting_individual_results mir ON badges.swimmer_id = mir.swimmer_id
                                  INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
                                  INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
                                  INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
                                SQL
                                .where(ms: { meeting_id: @meeting.id })
                                .where(mir: { team_id: @src_team.id })
                                .where(season_id: @season.id, team_id: @src_team.id)
                                .where(<<~SQL.squish, @dest_team.id, @season.id)
                                  NOT EXISTS (
                                    SELECT 1 FROM badges b2
                                    WHERE b2.swimmer_id = badges.swimmer_id
                                      AND b2.team_id = ?
                                      AND b2.season_id = ?
                                  )
                                SQL
                                .distinct
      # Original for lines 107-108: `.where('ms.meeting_id = ?', @meeting.id)` and `.where('mir.team_id = ?', @src_team.id)`
    end

    # Returns Badges (via MRS swimmers) that need team_id update.
    def mrs_badges_to_update
      @mrs_badges_to_update ||= GogglesDb::Badge
                                .joins(<<~SQL.squish)
                                  INNER JOIN meeting_relay_swimmers mrs ON badges.swimmer_id = mrs.swimmer_id
                                  INNER JOIN meeting_relay_results mrr ON mrs.meeting_relay_result_id = mrr.id
                                  INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
                                  INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
                                  INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
                                SQL
                                .where(ms: { meeting_id: @meeting.id })
                                .where(mrr: { team_id: @src_team.id })
                                .where(season_id: @season.id, team_id: @src_team.id)
                                .where(<<~SQL.squish, @dest_team.id, @season.id)
                                  NOT EXISTS (
                                    SELECT 1 FROM badges b2
                                    WHERE b2.swimmer_id = badges.swimmer_id
                                      AND b2.team_id = ?
                                      AND b2.season_id = ?
                                  )
                                SQL
                                .distinct
      # Original for lines 131-132: `.where('ms.meeting_id = ?', @meeting.id)` and `.where('mrr.team_id = ?', @src_team.id)`
    end

    # Returns swimmers that have badges in BOTH teams for the same season (conflicts).
    def conflicting_badges
      @conflicting_badges ||= GogglesDb::Badge
                              .joins(<<~SQL.squish)
                                INNER JOIN badges b2 ON badges.swimmer_id = b2.swimmer_id
                                  AND b2.team_id = #{@dest_team.id}
                                  AND b2.season_id = #{@season.id}
                              SQL
                              .where(team_id: @src_team.id, season_id: @season.id)
                              .where(<<~SQL.squish, @meeting.id, @src_team.id)
                                badges.swimmer_id IN (
                                  SELECT DISTINCT mir.swimmer_id
                                  FROM meeting_individual_results mir
                                  INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
                                  INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
                                  INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
                                  WHERE ms.meeting_id = ? AND mir.team_id = ?
                                )
                              SQL
                              .distinct
    end

    # Returns duplicate laps that would exist after merge (to be deleted).
    def duplicate_laps
      @duplicate_laps ||= GogglesDb::Lap
                          .joins(<<~SQL.squish)
                            INNER JOIN meeting_individual_results mir ON laps.meeting_individual_result_id = mir.id
                            INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
                            INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
                            INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
                            INNER JOIN laps l2 ON
                              laps.meeting_individual_result_id = l2.meeting_individual_result_id
                              AND laps.swimmer_id = l2.swimmer_id
                              AND laps.length_in_meters = l2.length_in_meters
                              AND laps.id > l2.id
                          SQL
                          .where(ms: { meeting_id: @meeting.id })
                          .where('laps.team_id = ? OR l2.team_id = ?', @src_team.id, @dest_team.id)
      # Original for line 181: `.where('ms.meeting_id = ?', @meeting.id)` (not sure using SQL-bound aliases works from top-level AR statements)
    end

    # Returns duplicate relay_laps that would exist after merge (to be deleted).
    def duplicate_relay_laps
      @duplicate_relay_laps ||= GogglesDb::RelayLap
                                .joins(<<~SQL.squish)
                                  INNER JOIN meeting_relay_results mrr ON relay_laps.meeting_relay_result_id = mrr.id
                                  INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
                                  INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
                                  INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
                                  INNER JOIN relay_laps rl2 ON
                                    relay_laps.meeting_relay_result_id = rl2.meeting_relay_result_id
                                    AND relay_laps.swimmer_id = rl2.swimmer_id
                                    AND relay_laps.id > rl2.id
                                SQL
                                .where(ms: { meeting_id: @meeting.id })
                                .where('relay_laps.team_id = ? OR rl2.team_id = ?', @src_team.id, @dest_team.id)
      # Original for line 198: ``.where('ms.meeting_id = ?', @meeting.id)``
    end

    # Returns duplicate MRRs (same program, team, swimmer composition) - complex query.
    # Uses raw SQL due to GROUP_CONCAT requirement.
    def duplicate_mrrs # rubocop:disable Metrics/MethodLength
      return @duplicate_mrrs if defined?(@duplicate_mrrs)

      sql = <<~SQL.squish
        SELECT mrr_sigs1.id AS mrr_to_delete
        FROM (
          SELECT
            mrr.id,
            mrr.meeting_program_id,
            mrr.team_id,
            GROUP_CONCAT(mrs.swimmer_id ORDER BY mrs.swimmer_id) AS swimmer_signature
          FROM meeting_relay_results mrr
          INNER JOIN meeting_relay_swimmers mrs ON mrs.meeting_relay_result_id = mrr.id
          INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{@meeting.id}
          GROUP BY mrr.id
        ) AS mrr_sigs1
        INNER JOIN (
          SELECT
            mrr.id,
            mrr.meeting_program_id,
            mrr.team_id,
            GROUP_CONCAT(mrs.swimmer_id ORDER BY mrs.swimmer_id) AS swimmer_signature
          FROM meeting_relay_results mrr
          INNER JOIN meeting_relay_swimmers mrs ON mrs.meeting_relay_result_id = mrr.id
          INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{@meeting.id}
          GROUP BY mrr.id
        ) AS mrr_sigs2 ON
          mrr_sigs1.meeting_program_id = mrr_sigs2.meeting_program_id
          AND (mrr_sigs1.team_id = #{@src_team.id} OR mrr_sigs1.team_id = #{@dest_team.id})
          AND (mrr_sigs2.team_id = #{@src_team.id} OR mrr_sigs2.team_id = #{@dest_team.id})
          AND mrr_sigs1.swimmer_signature = mrr_sigs2.swimmer_signature
          AND mrr_sigs1.id > mrr_sigs2.id
      SQL

      @duplicate_mrrs = ActiveRecord::Base.connection.execute(sql).to_a.flatten
    end

    # Returns badge merge pairs for swimmers with badges in BOTH teams.
    # Each pair is [src_badge_id, dest_badge_id] grouped by swimmer_id.
    # These are badges that need to be merged AFTER running this script.
    def badge_merge_pairs
      return @badge_merge_pairs if defined?(@badge_merge_pairs)

      @badge_merge_pairs = conflicting_badges.map do |src_badge|
        dest_badge = GogglesDb::Badge.find_by(
          swimmer_id: src_badge.swimmer_id,
          team_id: @dest_team.id,
          season_id: @season.id
        )
        [src_badge.id, dest_badge&.id]
      end
      @badge_merge_pairs = @badge_merge_pairs.select { |pair| pair[1].present? }
    end
    #-- -----------------------------------------------------------------------
    #++

    # Outputs a detailed report of the merge preview to stdout.
    # rubocop:disable Rails/Output, Metrics/AbcSize
    def display_report # rubocop:disable Metrics/MethodLength,Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity
      puts "\r\n#{'=' * 60}"
      puts "Team Merge Preview: Meeting #{@meeting.id}"
      puts '=' * 60
      puts "Meeting: #{@meeting.decorate.display_label}"
      puts "Season: #{@season.id} - #{@season.description}"
      puts "\r\nSource team (WRONG): (#{@src_team.id}) \"#{@src_team.name}\""
      puts "  -> TeamAffiliation: #{@src_ta&.id || 'N/A'}"
      puts "Dest team (CORRECT): (#{@dest_team.id}) \"#{@dest_team.name}\""
      puts "  -> TeamAffiliation: #{@dest_ta&.id || 'N/A'}"

      puts "\r\n--- Individual Results ---"
      puts "- Source team laps: #{src_laps.count}"
      puts "  IDs: #{format_ids(src_laps)}" if src_laps.any?
      puts "- Dest team laps: #{dest_laps.count}"

      puts "\r\n- Source team MIRs: #{src_mirs.count}"
      puts "  IDs: #{format_ids(src_mirs)}" if src_mirs.any?
      puts "- Dest team MIRs: #{dest_mirs.count}"

      puts "\r\n--- Relay Results ---"
      puts "- Source team relay_laps: #{src_relay_laps.count}"
      puts "  IDs: #{format_ids(src_relay_laps)}" if src_relay_laps.any?
      puts "- Dest team relay_laps: #{dest_relay_laps.count}"

      puts "\r\n- Source team MRRs: #{src_mrrs.count}"
      puts "  IDs: #{format_ids(src_mrrs)}" if src_mrrs.any?
      puts "- Dest team MRRs: #{dest_mrrs.count}"

      puts "\r\n--- Badge Updates ---"
      puts "- MIR swimmer badges to update: #{mir_badges_to_update.count}"
      puts "  IDs: #{format_ids(mir_badges_to_update)}" if mir_badges_to_update.any?
      puts "- MRS swimmer badges to update: #{mrs_badges_to_update.count}"
      puts "  IDs: #{format_ids(mrs_badges_to_update)}" if mrs_badges_to_update.any?

      puts "\r\n--- Potential Issues ---"
      puts "- Swimmers with badges in BOTH teams: #{conflicting_badges.count}"
      puts "  Badge IDs: #{format_ids(conflicting_badges)}" if conflicting_badges.any?
      puts "- Duplicate laps after merge: #{duplicate_laps.count}"
      puts "- Duplicate relay_laps after merge: #{duplicate_relay_laps.count}"
      puts "- Duplicate MRRs after merge: #{duplicate_mrrs.count}"

      display_badge_merge_pairs if @full_report && badge_merge_pairs.any?

      puts "\r\n#{'=' * 60}\r\n"
    end
    # rubocop:enable Rails/Output, Metrics/AbcSize

    # Outputs badge merge pairs for post-merge badge consolidation.
    # rubocop:disable Rails/Output
    def display_badge_merge_pairs
      puts "\r\n--- Badge Merge Pairs (for post-merge consolidation) ---"
      puts 'These badge pairs share the same swimmer and need to be merged:'
      puts '(Format: src_badge_id => dest_badge_id)'
      puts ''
      badge_merge_pairs.each_slice(5) do |slice|
        puts slice.map { |pair| "#{pair[0]} => #{pair[1]}" }.join('  |  ')
      end
      puts "\r\n-- Suggested commands:"
      cmd_index = @index + 1
      badge_merge_pairs.each do |pair|
        puts "bundle exec rake merge:badge src=#{pair[0]} dest=#{pair[1]} index=#{cmd_index} simulate=0 force=1"
        cmd_index += 1
      end
    end
    # rubocop:enable Rails/Output
    #-- -----------------------------------------------------------------------
    #++

    # Generates the SQL statements for the merge and stores them in @sql_log.
    # This method should only be called once.
    #
    # rubocop:disable Metrics/AbcSize
    def prepare
      return if @sql_log.present?

      @sql_log << "-- Merge team in meeting: (#{@src_team.id}) #{@src_team.name} |=> (#{@dest_team.id}) #{@dest_team.name}"
      @sql_log << "-- Meeting: #{@meeting.id} - #{@meeting.decorate.display_label}"
      @sql_log << "-- Season: #{@season.id}"
      @sql_log << ''
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''

      # Restore wrong TA name (if exists)
      if @src_ta.present?
        @sql_log << '-- Restore overwritten TA name in wrong TeamAffiliation (if needed)'
        @sql_log << "UPDATE team_affiliations SET updated_at=NOW(), name=\"#{@src_team.name}\" WHERE id=#{@src_ta.id};"
        @sql_log << ''
      end

      prepare_badge_updates
      prepare_lap_and_mir_updates
      prepare_relay_updates
      prepare_duplicate_deletions

      @sql_log << ''
      @sql_log << 'COMMIT;'
    end
    # rubocop:enable Metrics/AbcSize
    #-- -----------------------------------------------------------------------
    #++

    private

    # Resolves TeamAffiliation IDs for both teams in this season.
    def resolve_team_affiliations
      @src_ta = GogglesDb::TeamAffiliation.find_by(team_id: @src_team.id, season_id: @season.id)
      @dest_ta = GogglesDb::TeamAffiliation.find_by(team_id: @dest_team.id, season_id: @season.id)

      return if @dest_ta.present?

      raise(ArgumentError, "Destination team #{@dest_team.id} has no TeamAffiliation for season #{@season.id}!")
    end

    # Returns Laps for a given team_id in this meeting.
    def laps_for_team(team_id)
      GogglesDb::Lap
        .joins(meeting_individual_result: { meeting_program: { meeting_event: :meeting_session } })
        .where(meeting_sessions: { meeting_id: @meeting.id })
        .where(team_id:)
    end

    # Returns MIRs for a given team_id in this meeting.
    def mirs_for_team(team_id)
      GogglesDb::MeetingIndividualResult
        .joins(meeting_program: { meeting_event: :meeting_session })
        .where(meeting_sessions: { meeting_id: @meeting.id })
        .where(team_id:)
    end

    # Returns RelayLaps for a given team_id in this meeting.
    def relay_laps_for_team(team_id)
      GogglesDb::RelayLap
        .joins(meeting_relay_result: { meeting_program: { meeting_event: :meeting_session } })
        .where(meeting_sessions: { meeting_id: @meeting.id })
        .where(team_id:)
    end

    # Returns MRRs for a given team_id in this meeting.
    def mrrs_for_team(team_id)
      GogglesDb::MeetingRelayResult
        .joins(meeting_program: { meeting_event: :meeting_session })
        .where(meeting_sessions: { meeting_id: @meeting.id })
        .where(team_id:)
    end

    # Formats IDs for display.
    # When full_report is true, shows all IDs (10 per row).
    # Otherwise, limits to 20 IDs with "..." if more.
    def format_ids(relation, limit: 20)
      if @full_report
        format_ids_full(relation.pluck(:id))
      else
        ids = relation.limit(limit + 1).pluck(:id)
        result = ids.first(limit).join(', ')
        result += ", ... (#{relation.count - limit} more)" if ids.size > limit
        result
      end
    end

    # Formats all IDs with 10 per row for full report mode.
    def format_ids_full(ids)
      return '' if ids.empty?

      ids.each_slice(10).map { |slice| slice.join(', ') }.join("\n          ")
    end

    # Generates SQL for badge updates (Step 0a, 0b).
    def prepare_badge_updates # rubocop:disable Metrics/MethodLength
      @sql_log << '-- Step 0a: Update badges for MIR swimmers that are in wrong team'
      @sql_log << <<~SQL.squish
        UPDATE badges b
        INNER JOIN meeting_individual_results mir ON b.swimmer_id = mir.swimmer_id
          AND b.season_id = #{@season.id}
          AND b.team_id = #{@src_team.id}
        INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        SET b.team_id = #{@dest_team.id},
            b.team_affiliation_id = #{@dest_ta.id}
        WHERE ms.meeting_id = #{@meeting.id}
          AND mir.team_id = #{@src_team.id}
          AND NOT EXISTS (
            SELECT 1 FROM badges b2
            WHERE b2.swimmer_id = b.swimmer_id
              AND b2.team_id = #{@dest_team.id}
              AND b2.season_id = #{@season.id}
          );
      SQL
      @sql_log << ''

      @sql_log << '-- Step 0b: Update badges for MRS swimmers that are in wrong team'
      @sql_log << <<~SQL.squish
        UPDATE badges b
        INNER JOIN meeting_relay_swimmers mrs ON b.swimmer_id = mrs.swimmer_id
          AND b.season_id = #{@season.id}
          AND b.team_id = #{@src_team.id}
        INNER JOIN meeting_relay_results mrr ON mrs.meeting_relay_result_id = mrr.id
        INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        SET b.team_id = #{@dest_team.id},
            b.team_affiliation_id = #{@dest_ta.id}
        WHERE ms.meeting_id = #{@meeting.id}
          AND mrr.team_id = #{@src_team.id}
          AND NOT EXISTS (
            SELECT 1 FROM badges b2
            WHERE b2.swimmer_id = b.swimmer_id
              AND b2.team_id = #{@dest_team.id}
              AND b2.season_id = #{@season.id}
          );
      SQL
      @sql_log << ''
    end

    # Generates SQL for lap and MIR updates (Steps 1a, 1b, 1c).
    def prepare_lap_and_mir_updates # rubocop:disable Metrics/MethodLength
      src_ta_id = @src_ta&.id || 0

      @sql_log << '-- Step 1a: Update laps team_id (move existing laps to CORRECT team)'
      @sql_log << <<~SQL.squish
        UPDATE laps l
        INNER JOIN meeting_individual_results mir ON l.meeting_individual_result_id = mir.id
        INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        SET l.team_id = #{@dest_team.id}
        WHERE ms.meeting_id = #{@meeting.id}
          AND l.team_id = #{@src_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 1b: Update MIR team_id and team_affiliation_id with CORRECT values'
      @sql_log << <<~SQL.squish
        UPDATE meeting_individual_results mir
        INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        SET mir.team_id = #{@dest_team.id},
            mir.team_affiliation_id = #{@dest_ta.id}
        WHERE ms.meeting_id = #{@meeting.id}
          AND mir.team_id = #{@src_team.id}
          AND mir.team_affiliation_id = #{src_ta_id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 1c: Update MIR badge_ids to match new CORRECT team'
      @sql_log << <<~SQL.squish
        UPDATE meeting_individual_results mir
        INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN badges b ON b.swimmer_id = mir.swimmer_id
          AND b.team_id = #{@dest_team.id}
          AND b.season_id = #{@season.id}
        SET mir.badge_id = b.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND mir.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''
    end

    # Generates SQL for relay updates (Steps 2a, 2b, 2c).
    def prepare_relay_updates # rubocop:disable Metrics/MethodLength
      src_ta_id = @src_ta&.id || 0

      @sql_log << '-- Step 2a: Update relay_laps with CORRECT team_id'
      @sql_log << <<~SQL.squish
        UPDATE relay_laps rl
        INNER JOIN meeting_relay_results mrr ON rl.meeting_relay_result_id = mrr.id
        INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        SET rl.team_id = #{@dest_team.id}
        WHERE ms.meeting_id = #{@meeting.id}
          AND rl.team_id = #{@src_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 2b: Update MRR with CORRECT team_id and team_affiliation_id'
      @sql_log << <<~SQL.squish
        UPDATE meeting_relay_results mrr
        INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        SET mrr.team_id = #{@dest_team.id},
            mrr.team_affiliation_id = #{@dest_ta.id}
        WHERE ms.meeting_id = #{@meeting.id}
          AND mrr.team_id = #{@src_team.id}
          AND mrr.team_affiliation_id = #{src_ta_id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 2c: Update MRS badge_ids to match new CORRECT team'
      @sql_log << <<~SQL.squish
        UPDATE meeting_relay_swimmers mrs
        INNER JOIN meeting_relay_results mrr ON mrs.meeting_relay_result_id = mrr.id
        INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN badges b ON b.swimmer_id = mrs.swimmer_id
          AND b.team_id = #{@dest_team.id}
          AND b.season_id = #{@season.id}
        SET mrs.badge_id = b.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND mrr.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''
    end

    # Generates SQL for duplicate deletions (Steps 3-7).
    def prepare_duplicate_deletions # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      @sql_log << '-- Step 3: Delete duplicate laps'
      @sql_log << <<~SQL.squish
        DELETE l1
        FROM laps l1
        INNER JOIN meeting_individual_results mir ON l1.meeting_individual_result_id = mir.id
        INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN laps l2 ON
          l1.meeting_individual_result_id = l2.meeting_individual_result_id
          AND l1.swimmer_id = l2.swimmer_id
          AND l1.team_id = l2.team_id
          AND l1.length_in_meters = l2.length_in_meters
          AND l1.id > l2.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND l1.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 3b: Delete laps belonging to duplicate MIRs (clear FK before MIR deletion)'
      @sql_log << <<~SQL.squish
        DELETE l1
        FROM laps l1
        INNER JOIN meeting_individual_results mir1 ON l1.meeting_individual_result_id = mir1.id
        INNER JOIN meeting_programs mp ON mir1.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN meeting_individual_results mir2 ON
          mir1.meeting_program_id = mir2.meeting_program_id
          AND mir1.swimmer_id = mir2.swimmer_id
          AND mir1.team_id = mir2.team_id
          AND mir1.id > mir2.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND mir1.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 4: Delete duplicate MIRs'
      @sql_log << <<~SQL.squish
        DELETE mir1
        FROM meeting_individual_results mir1
        INNER JOIN meeting_programs mp ON mir1.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN meeting_individual_results mir2 ON
          mir1.meeting_program_id = mir2.meeting_program_id
          AND mir1.swimmer_id = mir2.swimmer_id
          AND mir1.team_id = mir2.team_id
          AND mir1.id > mir2.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND mir1.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 5: Delete duplicate relay_laps'
      @sql_log << <<~SQL.squish
        DELETE rl1
        FROM relay_laps rl1
        INNER JOIN meeting_relay_results mrr ON rl1.meeting_relay_result_id = mrr.id
        INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN relay_laps rl2 ON
          rl1.meeting_relay_result_id = rl2.meeting_relay_result_id
          AND rl1.swimmer_id = rl2.swimmer_id
          AND rl1.team_id = rl2.team_id
          AND rl1.id > rl2.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND rl1.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 6: Delete duplicate MRSs'
      @sql_log << <<~SQL.squish
        DELETE mrs1
        FROM meeting_relay_swimmers mrs1
        INNER JOIN meeting_relay_results mrr ON mrs1.meeting_relay_result_id = mrr.id
        INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN meeting_relay_swimmers mrs2 ON
          mrs1.meeting_relay_result_id = mrs2.meeting_relay_result_id
          AND mrs1.swimmer_id = mrs2.swimmer_id
          AND mrs1.id > mrs2.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND mrr.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 6b: Delete relay_laps belonging to duplicate MRRs (clear FK before MRR deletion)'
      @sql_log << <<~SQL.squish
        DELETE rl1
        FROM relay_laps rl1
        INNER JOIN meeting_relay_results mrr1 ON rl1.meeting_relay_result_id = mrr1.id
        INNER JOIN meeting_programs mp ON mrr1.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN (
          SELECT
            mrr_inner.id,
            mrr_inner.meeting_program_id,
            mrr_inner.team_id,
            GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_signature
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{@meeting.id}
            AND mrr_inner.team_id = #{@dest_team.id}
          GROUP BY mrr_inner.id
        ) AS mrr_sigs1 ON mrr1.id = mrr_sigs1.id
        INNER JOIN (
          SELECT
            mrr_inner.id,
            mrr_inner.meeting_program_id,
            mrr_inner.team_id,
            GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_signature
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{@meeting.id}
            AND mrr_inner.team_id = #{@dest_team.id}
          GROUP BY mrr_inner.id
        ) AS mrr_sigs2 ON
          mrr_sigs1.meeting_program_id = mrr_sigs2.meeting_program_id
          AND mrr_sigs1.team_id = mrr_sigs2.team_id
          AND mrr_sigs1.swimmer_signature = mrr_sigs2.swimmer_signature
          AND mrr_sigs1.id > mrr_sigs2.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND mrr1.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 6c: Delete MRS belonging to duplicate MRRs (clear FK before MRR deletion)'
      @sql_log << <<~SQL.squish
        DELETE mrs1
        FROM meeting_relay_swimmers mrs1
        INNER JOIN meeting_relay_results mrr1 ON mrs1.meeting_relay_result_id = mrr1.id
        INNER JOIN meeting_programs mp ON mrr1.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN (
          SELECT
            mrr_inner.id,
            mrr_inner.meeting_program_id,
            mrr_inner.team_id,
            GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_signature
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{@meeting.id}
            AND mrr_inner.team_id = #{@dest_team.id}
          GROUP BY mrr_inner.id
        ) AS mrr_sigs1 ON mrr1.id = mrr_sigs1.id
        INNER JOIN (
          SELECT
            mrr_inner.id,
            mrr_inner.meeting_program_id,
            mrr_inner.team_id,
            GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_signature
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{@meeting.id}
            AND mrr_inner.team_id = #{@dest_team.id}
          GROUP BY mrr_inner.id
        ) AS mrr_sigs2 ON
          mrr_sigs1.meeting_program_id = mrr_sigs2.meeting_program_id
          AND mrr_sigs1.team_id = mrr_sigs2.team_id
          AND mrr_sigs1.swimmer_signature = mrr_sigs2.swimmer_signature
          AND mrr_sigs1.id > mrr_sigs2.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND mrr1.team_id = #{@dest_team.id};
      SQL
      @sql_log << ''

      @sql_log << '-- Step 7: Delete duplicate MRRs (same program, team, swimmer composition)'
      @sql_log << <<~SQL.squish
        DELETE mrr1
        FROM meeting_relay_results mrr1
        INNER JOIN meeting_programs mp ON mrr1.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN (
          SELECT
            mrr_inner.id,
            mrr_inner.meeting_program_id,
            mrr_inner.team_id,
            GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_signature
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{@meeting.id}
            AND mrr_inner.team_id = #{@dest_team.id}
          GROUP BY mrr_inner.id
        ) AS mrr_sigs1 ON mrr1.id = mrr_sigs1.id
        INNER JOIN (
          SELECT
            mrr_inner.id,
            mrr_inner.meeting_program_id,
            mrr_inner.team_id,
            GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_signature
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{@meeting.id}
            AND mrr_inner.team_id = #{@dest_team.id}
          GROUP BY mrr_inner.id
        ) AS mrr_sigs2 ON
          mrr_sigs1.meeting_program_id = mrr_sigs2.meeting_program_id
          AND mrr_sigs1.team_id = mrr_sigs2.team_id
          AND mrr_sigs1.swimmer_signature = mrr_sigs2.swimmer_signature
          AND mrr_sigs1.id > mrr_sigs2.id
        WHERE ms.meeting_id = #{@meeting.id}
          AND mrr1.team_id = #{@dest_team.id};
      SQL
    end
  end
end
