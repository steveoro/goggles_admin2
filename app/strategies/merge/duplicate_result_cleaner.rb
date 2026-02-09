# frozen_string_literal: true

module Merge
  # = Merge::DuplicateResultCleaner
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #   - build:    20260201
  #
  # Detects and removes duplicate swimmer results within a meeting or across all meetings in a season.
  #
  # This strategy handles duplicates that may remain after badge merges or data imports,
  # where multiple MIRs/MRSs exist for the same swimmer in the same program.
  #
  # == Detection Rules:
  # - **Duplicate MIRs**: Same swimmer_id + meeting_program_id + matching timing
  # - **Duplicate Laps**: Same swimmer_id + meeting_individual_result_id + length_in_meters
  # - **Duplicate MRSs**: Same swimmer_id + meeting_relay_result_id
  # - **Duplicate RelayLaps**: Same swimmer_id + meeting_relay_swimmer_id + length_in_meters
  # - **Duplicate MRRs**: Same team_id + meeting_program_id + same swimmer composition (GROUP_CONCAT pattern)
  #
  # == Deletion Rules (when autofix=true):
  # - Keep the row with the lowest ID (oldest)
  # - If one row links to a non-existing badge, prefer deleting that one (after timing verification)
  # - Delete associated laps/relay_laps first (FK constraint)
  #
  # == Usage:
  #   cleaner = Merge::DuplicateResultCleaner.new(meeting: meeting, autofix: true)
  #   cleaner.display_report  # Preview duplicates found
  #   cleaner.prepare         # Generate SQL statements
  #   cleaner.single_transaction_sql_log  # Get wrapped SQL
  #
  class DuplicateResultCleaner # rubocop:disable Metrics/ClassLength
    attr_reader :meeting, :season, :autofix, :sql_log, :duplicates_report

    # == Params:
    # - <tt>:meeting</tt> => Meeting instance (optional, but one of meeting or season required)
    # - <tt>:season</tt> => Season instance (optional, processes all meetings in season)
    # - <tt>:autofix</tt> => when true, generates DELETE statements (default: false)
    #
    def initialize(meeting: nil, season: nil, autofix: false)
      raise(ArgumentError, 'Either meeting or season must be provided!') if meeting.nil? && season.nil?
      raise(ArgumentError, 'meeting must be a Meeting!') if meeting.present? && !meeting.is_a?(GogglesDb::Meeting)
      raise(ArgumentError, 'season must be a Season!') if season.present? && !season.is_a?(GogglesDb::Season)

      @meeting = meeting
      @season = season || meeting&.season
      @autofix = autofix
      @sql_log = []
      @duplicates_report = {}
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the list of meetings to process.
    def meetings_to_process
      @meetings_to_process ||= if @meeting.present?
                                 [@meeting]
                               else
                                 GogglesDb::Meeting.where(season_id: @season.id).order(:id)
                               end
    end

    # Finds duplicate MIRs for a specific meeting.
    # Returns an array of hashes with swimmer info and duplicate MIR details.
    def find_duplicate_mirs(meeting_id)
      # Find swimmers with > 1 MIR in the same MeetingProgram
      swimmer_ids = GogglesDb::MeetingIndividualResult
                    .joins(meeting_program: { meeting_event: { meeting_session: :meeting } })
                    .where(meetings: { id: meeting_id })
                    .group(:swimmer_id, 'meeting_programs.id')
                    .having('COUNT(meeting_individual_results.id) > 1')
                    .pluck(:swimmer_id)
                    .uniq

      return [] if swimmer_ids.empty?

      # Get detailed info for each duplicate group
      duplicates = []
      swimmer_ids.each do |swimmer_id|
        swimmer = GogglesDb::Swimmer.find_by(id: swimmer_id)
        next unless swimmer

        mirs = GogglesDb::MeetingIndividualResult
               .joins(meeting_program: { meeting_event: { meeting_session: :meeting } })
               .includes(:team, :badge, :meeting_event)
               .where(meetings: { id: meeting_id }, swimmer_id: swimmer_id)
               .order('meeting_programs.id', :id)

        # Group by meeting_program_id to find actual duplicates
        mirs.group_by(&:meeting_program_id).each do |mprg_id, mir_group|
          next if mir_group.size <= 1

          duplicates << {
            swimmer: swimmer,
            meeting_program_id: mprg_id,
            mirs: mir_group,
            timing_match: mir_group.map { |mir| mir.to_timing.to_hundredths }.uniq.size == 1
          }
        end
      end
      duplicates
    end

    # Finds duplicate laps for a specific meeting.
    def find_duplicate_laps(meeting_id)
      GogglesDb::Lap
        .joins(meeting_individual_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } })
        .where(meetings: { id: meeting_id })
        .group(:swimmer_id, :meeting_individual_result_id, :length_in_meters)
        .having('COUNT(laps.id) > 1')
        .count
        .keys
    end

    # Finds duplicate MRSs for a specific meeting.
    def find_duplicate_mrss(meeting_id)
      GogglesDb::MeetingRelaySwimmer
        .joins(meeting_relay_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } })
        .where(meetings: { id: meeting_id })
        .group(:swimmer_id, :meeting_relay_result_id)
        .having('COUNT(meeting_relay_swimmers.id) > 1')
        .count
        .keys
    end

    # Finds duplicate relay_laps for a specific meeting.
    def find_duplicate_relay_laps(meeting_id)
      GogglesDb::RelayLap
        .joins(meeting_relay_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } })
        .where(meetings: { id: meeting_id })
        .group(:swimmer_id, :meeting_relay_swimmer_id, :length_in_meters)
        .having('COUNT(relay_laps.id) > 1')
        .count
        .keys
    end

    # Finds duplicate MRRs (same team + program + swimmer composition) for a specific meeting.
    # Uses GROUP_CONCAT pattern similar to TeamInMeeting.
    def find_duplicate_mrrs(meeting_id)
      # This requires raw SQL due to GROUP_CONCAT complexity
      sql = <<~SQL.squish
        SELECT sig1.id AS dup_id, sig2.id AS keep_id
        FROM meeting_relay_results mrr1
        INNER JOIN meeting_programs mp ON mrr1.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN (
          SELECT mrr_inner.id, mrr_inner.meeting_program_id, mrr_inner.team_id,
                 GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_sig
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{meeting_id}
          GROUP BY mrr_inner.id
        ) AS sig1 ON mrr1.id = sig1.id
        INNER JOIN (
          SELECT mrr_inner.id, mrr_inner.meeting_program_id, mrr_inner.team_id,
                 GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_sig
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{meeting_id}
          GROUP BY mrr_inner.id
        ) AS sig2 ON sig1.meeting_program_id = sig2.meeting_program_id
                  AND sig1.team_id = sig2.team_id
                  AND sig1.swimmer_sig = sig2.swimmer_sig
                  AND sig1.id > sig2.id
        WHERE ms.meeting_id = #{meeting_id}
      SQL
      ActiveRecord::Base.connection.execute(sql).to_a
    end
    #-- -----------------------------------------------------------------------
    #++

    # Displays a report of all duplicates found.
    # rubocop:disable Rails/Output, Metrics/AbcSize, Metrics/MethodLength
    def display_report
      puts "\r\n#{'=' * 60}"
      puts 'Duplicate Result Cleaner Report'
      puts "Season: #{@season.id} - #{@season.description}" if @season
      puts "Meeting: #{@meeting.id} - #{@meeting.description}" if @meeting
      puts "Autofix: #{@autofix ? 'ENABLED' : 'disabled'}"
      puts "#{'=' * 60}\r\n"

      total_dup_mirs = 0
      total_dup_laps = 0
      total_dup_mrss = 0
      total_dup_relay_laps = 0
      total_dup_mrrs = 0

      meetings_to_process.each do |mtg|
        dup_mirs = find_duplicate_mirs(mtg.id)
        dup_laps = find_duplicate_laps(mtg.id)
        dup_mrss = find_duplicate_mrss(mtg.id)
        dup_relay_laps = find_duplicate_relay_laps(mtg.id)
        dup_mrrs = find_duplicate_mrrs(mtg.id)

        next if dup_mirs.empty? && dup_laps.empty? && dup_mrss.empty? &&
                dup_relay_laps.empty? && dup_mrrs.empty?

        puts "\r\n--- Meeting #{mtg.id}: #{mtg.description} ---"

        if dup_mirs.any?
          puts "\r\nDuplicate MIRs found: #{dup_mirs.size} groups"
          dup_mirs.each do |dup|
            puts "  Swimmer #{dup[:swimmer].id}: #{dup[:swimmer].complete_name} (#{dup[:swimmer].year_of_birth})"
            puts "    Program ID: #{dup[:meeting_program_id]}, Timing match: #{dup[:timing_match]}"
            dup[:mirs].each do |mir|
              badge_exists = GogglesDb::Badge.exists?(id: mir.badge_id)
              badge_status = badge_exists ? '' : ' [BADGE MISSING!]'
              puts "    - MIR #{mir.id}: #{mir.to_timing} => team #{mir.team_id} (#{mir.team&.editable_name}), badge #{mir.badge_id}#{badge_status} #{mir.badge&.decorate&.short_label}"
            end
          end
          total_dup_mirs += dup_mirs.size
        end

        puts "  Duplicate laps: #{dup_laps.size} groups" if dup_laps.any?
        puts "  Duplicate MRSs: #{dup_mrss.size} groups" if dup_mrss.any?
        puts "  Duplicate relay_laps: #{dup_relay_laps.size} groups" if dup_relay_laps.any?
        puts "  Duplicate MRRs: #{dup_mrrs.size} pairs" if dup_mrrs.any?

        total_dup_laps += dup_laps.size
        total_dup_mrss += dup_mrss.size
        total_dup_relay_laps += dup_relay_laps.size
        total_dup_mrrs += dup_mrrs.size

        @duplicates_report[mtg.id] = {
          mirs: dup_mirs, laps: dup_laps, mrss: dup_mrss,
          relay_laps: dup_relay_laps, mrrs: dup_mrrs
        }
      end

      puts "\r\n#{'=' * 60}"
      puts 'TOTALS:'
      puts "  Duplicate MIR groups: #{total_dup_mirs}"
      puts "  Duplicate lap groups: #{total_dup_laps}"
      puts "  Duplicate MRS groups: #{total_dup_mrss}"
      puts "  Duplicate relay_lap groups: #{total_dup_relay_laps}"
      puts "  Duplicate MRR pairs: #{total_dup_mrrs}"
      puts "#{'=' * 60}\r\n"
    end
    # rubocop:enable Rails/Output, Metrics/AbcSize, Metrics/MethodLength
    #-- -----------------------------------------------------------------------
    #++

    # Prepares the SQL script for duplicate deletions.
    # Only generates statements when @autofix is true.
    def prepare
      return unless @autofix

      @sql_log = []
      add_script_header

      meetings_to_process.each do |mtg|
        prepare_deletions_for_meeting(mtg)
      end

      @sql_log
    end

    # Returns the SQL log wrapped in a transaction.
    def single_transaction_sql_log
      return [] if @sql_log.empty?

      wrapped = []
      wrapped << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      wrapped << 'SET AUTOCOMMIT = 0;'
      wrapped << 'START TRANSACTION;'
      wrapped << ''
      wrapped.concat(@sql_log)
      wrapped << ''
      wrapped << '-- --------------------------------------------------------------------------'
      wrapped << ''
      wrapped << 'COMMIT;'
      wrapped
    end

    private

    def add_script_header
      @sql_log << "-- Duplicate Result Cleaner - Generated #{Time.zone.now}"
      @sql_log << "-- Season: #{@season.id}" if @season
      @sql_log << "-- Meeting: #{@meeting.id}" if @meeting
      @sql_log << ''
    end

    # Generates deletion SQL for a specific meeting.
    # rubocop:disable Metrics/AbcSize
    def prepare_deletions_for_meeting(mtg)
      dup_mirs = find_duplicate_mirs(mtg.id)
      dup_laps = find_duplicate_laps(mtg.id)
      dup_mrss = find_duplicate_mrss(mtg.id)
      dup_relay_laps = find_duplicate_relay_laps(mtg.id)
      dup_mrrs = find_duplicate_mrrs(mtg.id)

      return if dup_mirs.empty? && dup_laps.empty? && dup_mrss.empty? &&
                dup_relay_laps.empty? && dup_mrrs.empty?

      @sql_log << "-- Meeting #{mtg.id}: #{mtg.description}"
      @sql_log << ''

      # Step 1: Delete duplicate laps (FK constraint - must delete before MIRs)
      prepare_lap_deletions(mtg.id)

      # Step 2: Delete duplicate MIRs
      prepare_mir_deletions(mtg.id, dup_mirs)

      # Step 3: Delete duplicate relay_laps (FK constraint - must delete before MRSs)
      prepare_relay_lap_deletions(mtg.id)

      # Step 4: Delete duplicate MRSs
      prepare_mrs_deletions(mtg.id)

      # Step 5: Delete duplicate MRRs
      prepare_mrr_deletions(mtg.id)

      @sql_log << ''
    end
    # rubocop:enable Metrics/AbcSize

    def prepare_lap_deletions(meeting_id)
      @sql_log << '-- Delete duplicate laps (same swimmer + MIR + length_in_meters, keep lowest ID)'
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
          AND l1.length_in_meters = l2.length_in_meters
          AND l1.id > l2.id
        WHERE ms.meeting_id = #{meeting_id};
      SQL
      @sql_log << ''
    end

    def prepare_mir_deletions(_meeting_id, dup_mirs)
      return if dup_mirs.empty?

      @sql_log << '-- Delete duplicate MIRs'

      dup_mirs.each do |dup|
        # Prefer deleting MIRs with missing badges, otherwise delete higher IDs
        mirs_to_delete = dup[:mirs].sort_by do |mir|
          badge_exists = GogglesDb::Badge.exists?(id: mir.badge_id)
          # Sort: missing badge first (0), then by ID descending
          [badge_exists ? 1 : 0, -mir.id]
        end

        # Keep the last one (lowest ID with existing badge), delete the rest
        keep_mir = mirs_to_delete.pop
        mirs_to_delete.each do |mir|
          # First delete associated laps
          @sql_log << "DELETE FROM laps WHERE meeting_individual_result_id = #{mir.id};"
          @sql_log << "DELETE FROM meeting_individual_results WHERE id = #{mir.id}; -- keeping #{keep_mir.id}"
        end
      end
      @sql_log << ''
    end

    def prepare_relay_lap_deletions(meeting_id)
      @sql_log << '-- Delete duplicate relay_laps (same swimmer + MRS + length_in_meters, keep lowest ID)'
      @sql_log << <<~SQL.squish
        DELETE rl1
        FROM relay_laps rl1
        INNER JOIN meeting_relay_swimmers mrs ON rl1.meeting_relay_swimmer_id = mrs.id
        INNER JOIN meeting_relay_results mrr ON mrs.meeting_relay_result_id = mrr.id
        INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN relay_laps rl2 ON
          rl1.meeting_relay_swimmer_id = rl2.meeting_relay_swimmer_id
          AND rl1.swimmer_id = rl2.swimmer_id
          AND rl1.length_in_meters = rl2.length_in_meters
          AND rl1.id > rl2.id
        WHERE ms.meeting_id = #{meeting_id};
      SQL
      @sql_log << ''
    end

    def prepare_mrs_deletions(meeting_id)
      @sql_log << '-- Delete duplicate MRSs (same swimmer + MRR, keep lowest ID)'
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
        WHERE ms.meeting_id = #{meeting_id};
      SQL
      @sql_log << ''
    end

    def prepare_mrr_deletions(meeting_id)
      @sql_log << '-- Delete duplicate MRRs (same program + team + swimmer composition, keep lowest ID)'
      @sql_log << <<~SQL.squish
        DELETE mrr1
        FROM meeting_relay_results mrr1
        INNER JOIN meeting_programs mp ON mrr1.meeting_program_id = mp.id
        INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
        INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
        INNER JOIN (
          SELECT mrr_inner.id, mrr_inner.meeting_program_id, mrr_inner.team_id,
                 GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_sig
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{meeting_id}
          GROUP BY mrr_inner.id
        ) AS sig1 ON mrr1.id = sig1.id
        INNER JOIN (
          SELECT mrr_inner.id, mrr_inner.meeting_program_id, mrr_inner.team_id,
                 GROUP_CONCAT(mrs_inner.swimmer_id ORDER BY mrs_inner.swimmer_id) AS swimmer_sig
          FROM meeting_relay_results mrr_inner
          INNER JOIN meeting_relay_swimmers mrs_inner ON mrs_inner.meeting_relay_result_id = mrr_inner.id
          INNER JOIN meeting_programs mp_inner ON mrr_inner.meeting_program_id = mp_inner.id
          INNER JOIN meeting_events me_inner ON mp_inner.meeting_event_id = me_inner.id
          INNER JOIN meeting_sessions ms_inner ON me_inner.meeting_session_id = ms_inner.id
          WHERE ms_inner.meeting_id = #{meeting_id}
          GROUP BY mrr_inner.id
        ) AS sig2 ON sig1.meeting_program_id = sig2.meeting_program_id
                  AND sig1.team_id = sig2.team_id
                  AND sig1.swimmer_sig = sig2.swimmer_sig
                  AND sig1.id > sig2.id
        WHERE ms.meeting_id = #{meeting_id};
      SQL
      @sql_log << ''
    end
  end
end
