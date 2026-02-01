# frozen_string_literal: true

module Merge
  # = Merge::Meeting
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #   - build:    20260104
  #
  # Merges two Meeting entities belonging to the same Season.
  # All sub-entities from the source meeting will be moved to the destination,
  # creating missing rows or updating existing ones, ensuring no duplicates.
  #
  # This class generates an SQL script that can be replayed on any database replica.
  # The script is wrapped in a single transaction for atomicity.
  #
  # See docs/merge_meeting_task_plan.md for full specification.
  #
  class Meeting # rubocop:disable Metrics/ClassLength
    attr_reader :sql_log, :warning_log, :checker, :source, :dest

    # Returns a "START TRANSACTION" header as an array of SQL string statements.
    def self.start_transaction_log
      [
        "\r\n-- SET SQL_MODE = \"NO_AUTO_VALUE_ON_ZERO\";",
        'SET AUTOCOMMIT = 0;',
        "START TRANSACTION;\r\n"
      ]
    end

    # Returns a "COMMIT" footer as an array of SQL string statements.
    def self.end_transaction_log
      ["\r\nCOMMIT;"]
    end

    # Initializes the Meeting merger.
    #
    # == Params:
    # - <tt>:source</tt> => source Meeting row, *required*
    # - <tt>:dest</tt> => destination Meeting row, *required*
    # - <tt>:skip_columns</tt> => when true, don't overwrite destination meeting columns with source values
    # - <tt>:console_output</tt> => when +true+ (default) a simple progress status will be printed on stdout
    #
    def initialize(source:, dest:, skip_columns: false, console_output: true)
      raise(ArgumentError, 'Both source and destination must be Meetings!') unless source.is_a?(GogglesDb::Meeting) && dest.is_a?(GogglesDb::Meeting)
      raise(ArgumentError, 'Identical source and destination!') if source.id == dest.id

      @skip_columns = skip_columns
      @console_output = console_output
      @checker = MeetingChecker.new(source:, dest:)
      @source = @checker.source
      @dest = @checker.dest
      @sql_log = []
      @warning_log = []
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the merge script inside a single transaction.
    # Runs the checker first, then generates SQL for each hierarchy level.
    #
    # Returns true if preparation was successful, false otherwise.
    def prepare
      return false if @sql_log.present? # Don't allow a second run

      result_ok = @checker.run
      unless result_ok
        @checker.display_report
        return false
      end

      @checker.log << "\r\n\r\n- #{'Checker'.ljust(44, '.')}: ✅ OK"
      prepare_script_header

      # Phase 2: Hierarchy (Sessions, Events, Programs)
      prepare_script_for_sessions
      prepare_script_for_events
      prepare_script_for_programs

      # Phase 3: Results (MIRs, Laps, MRRs, MRS, RelayLaps)
      prepare_script_for_individual_results
      prepare_script_for_relay_results

      # Phase 4: Auxiliary entities
      prepare_script_for_team_scores
      prepare_script_for_deprecated_entities
      prepare_script_for_calendar

      # Update destination meeting columns if needed
      prepare_script_for_meeting_columns unless @skip_columns

      # Delete source meeting (bottom-up deletion already done for sub-entities)
      prepare_script_for_source_deletion

      @sql_log << ''
      @sql_log << 'COMMIT;'

      # Cache expected counts NOW, while DB still has original state
      # (verify_merge_result is called AFTER SQL execution)
      @expected_counts = calculate_expected_counts

      true
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the <tt>#log</tt> array from the internal MeetingChecker instance.
    delegate :log, to: :@checker

    # Returns the <tt>#errors</tt> array from the internal MeetingChecker instance.
    delegate :errors, to: :@checker

    # Returns the <tt>#warnings</tt> array from the internal MeetingChecker instance.
    delegate :warnings, to: :@checker

    # Returns the SQL log wrapped in a single transaction, as an array of SQL string statements.
    def single_transaction_sql_log
      Merge::Meeting.start_transaction_log + @sql_log + Merge::Meeting.end_transaction_log
    end

    # Creates and outputs to stdout a detailed report of the merge operation.
    # rubocop:disable Rails/Output
    def display_report
      @checker.display_report
      puts("\r\n*** WARNING LOG: ***\r\n#{@warning_log.join("\r\n")}") if @warning_log.present?
    end
    # rubocop:enable Rails/Output

    # Returns a Hash with the expected final counts for the destination meeting
    # after the merge operation has completed.
    def expected_counts
      @expected_counts ||= calculate_expected_counts
    end

    # Verifies the actual counts against expected counts after merge execution.
    # Returns true if all counts match, false otherwise.
    # rubocop:disable Rails/Output
    def verify_merge_result
      puts("\r\n=== POST-MERGE VERIFICATION ===")

      actual = actual_counts
      expected = expected_counts
      all_ok = true

      [
        [:events, 'Tot. events'],
        [:programs, 'Tot. programs'],
        [:mirs, 'Tot. MIRs'],
        [:laps, 'Tot. laps'],
        [:mrrs, 'Tot. MRRs'],
        [:mrs, 'Tot. MRS'],
        [:relay_laps, 'Tot. relay_laps'],
        [:team_scores, 'Tot. team_scores']
      ].each do |(key, label)|
        exp = expected[key]
        act = actual[key]
        ok = exp == act
        all_ok = false unless ok
        status = ok ? '✅' : '❌'
        puts("- #{label.ljust(18, '.')}: expected #{exp.to_s.rjust(5)} - final #{act.to_s.rjust(5)} #{status}")
      end

      puts
      if all_ok
        puts('=> MERGE SUCCESSFUL! ✅')
      else
        puts('=> MERGE FAILED! Please check the warning log file. ❌')
      end

      all_ok
    end
    # rubocop:enable Rails/Output

    private

    # Adds a descriptive header to the @sql_log member.
    def prepare_script_header
      @sql_log << "-- Merge Meeting (#{@source.id}) #{@source.display_label}"
      @sql_log << "--   |=> (#{@dest.id}) #{@dest.display_label}"
      @sql_log << "--   Season: #{@source.season_id} (#{@source.season.description})"
      @sql_log << ''
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''
    end

    #-- ------------------------------------------------------------------------
    #   Phase 2: Hierarchy (Sessions, Events, Programs)
    #-- ------------------------------------------------------------------------

    def prepare_script_for_sessions
      @sql_log << "\r\n-- === SESSIONS ==="
      src_only_keys = @checker.src_only_session_keys
      if src_only_keys.any?
        @sql_log << "-- Moving #{src_only_keys.count} source-only session(s) to destination meeting:"
        src_only_keys.each do |scheduled_date|
          src_session_id = @checker.session_map[scheduled_date][:src_id]
          @sql_log << "UPDATE meeting_sessions SET updated_at=NOW(), meeting_id=#{@dest.id} WHERE id=#{src_session_id};"
          log_progress('MeetingSession', src_session_id, "moved to meeting #{@dest.id}")
        end
      else
        @sql_log << '-- No source-only sessions to move.'
      end
    end

    def prepare_script_for_events
      @sql_log << "\r\n-- === EVENTS ==="
      src_only_keys = @checker.src_only_event_keys
      if src_only_keys.any?
        @sql_log << "-- Moving #{src_only_keys.count} source-only event(s) to destination session:"
        src_only_keys.each do |(scheduled_date, event_type_id)|
          src_event_id = @checker.event_map[[scheduled_date, event_type_id]][:src_id]
          dest_session_id = @checker.session_map[scheduled_date][:dest_id]
          if dest_session_id.present?
            @sql_log << "UPDATE meeting_events SET updated_at=NOW(), meeting_session_id=#{dest_session_id} WHERE id=#{src_event_id};"
            log_progress('MeetingEvent', src_event_id, "moved to session #{dest_session_id}")
          else
            @sql_log << "-- Event #{src_event_id} already moved with its session"
          end
        end
      else
        @sql_log << '-- No source-only events to move.'
      end
    end

    def prepare_script_for_programs
      @sql_log << "\r\n-- === PROGRAMS ==="
      src_only_keys = @checker.src_only_program_keys
      if src_only_keys.any?
        @sql_log << "-- Moving #{src_only_keys.count} source-only program(s) to destination event:"
        src_only_keys.each do |key|
          program_data = @checker.program_map[key]
          src_program_id = program_data[:src_id]
          dest_event_id = find_dest_event_for_program(key)
          if dest_event_id.present?
            @sql_log << "UPDATE meeting_programs SET updated_at=NOW(), meeting_event_id=#{dest_event_id} WHERE id=#{src_program_id};"
            log_progress('MeetingProgram', src_program_id, "moved to event #{dest_event_id}")
          else
            @sql_log << "-- Program #{src_program_id} already moved with its event"
          end
        end
      else
        @sql_log << '-- No source-only programs to move.'
      end
    end

    def find_dest_event_for_program(program_key)
      event_type_id, _category_type_id, _gender_type_id = program_key
      @checker.event_map.each do |(_scheduled_date, evt_id), event_data|
        return event_data[:dest_id] if evt_id == event_type_id && event_data[:dest_id].present?
      end
      nil
    end

    #-- ------------------------------------------------------------------------
    #   Phase 3: Results (MIRs, Laps, MRRs, MRS, RelayLaps)
    #-- ------------------------------------------------------------------------

    def prepare_script_for_individual_results
      @sql_log << "\r\n-- === INDIVIDUAL RESULTS (MIRs) ==="
      shared_keys = @checker.shared_program_keys
      @sql_log << "-- Processing #{shared_keys.count} shared program(s) for MIR merging..."
      shared_keys.each { |key| prepare_mirs_for_shared_program(key) }
      src_only_keys = @checker.src_only_program_keys
      @sql_log << "-- #{src_only_keys.count} source-only program(s): MIRs already moved with programs"
    end

    def prepare_mirs_for_shared_program(program_key)
      program_data = @checker.program_map[program_key]
      src_program_id = program_data[:src_id]
      dest_program_id = program_data[:dest_id]
      src_mirs = GogglesDb::MeetingIndividualResult.where(meeting_program_id: src_program_id)
      dest_mirs = GogglesDb::MeetingIndividualResult.where(meeting_program_id: dest_program_id)
      return if src_mirs.empty?

      src_mirs.each do |src_mir|
        dest_mir = dest_mirs.find_by(swimmer_id: src_mir.swimmer_id, team_id: src_mir.team_id)
        if dest_mir
          merge_mir_into_dest(src_mir, dest_mir)
        else
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), meeting_program_id=#{dest_program_id} WHERE id=#{src_mir.id};"
          @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{dest_program_id} WHERE meeting_individual_result_id=#{src_mir.id};"
        end
        Rails.logger.debug("\033[1;33;37m.\033[0m") if @console_output
      end
    end

    def merge_mir_into_dest(src_mir, dest_mir)
      set_clauses, = build_merge_set_clauses(src_mir, dest_mir, mir_merge_columns, 'MIR')
      @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), #{set_clauses.join(', ')} WHERE id=#{dest_mir.id};" if set_clauses.any?
      merge_laps_for_mir(src_mir, dest_mir)
      @sql_log << "DELETE FROM meeting_individual_results WHERE id=#{src_mir.id};"
    end

    def merge_laps_for_mir(src_mir, dest_mir)
      dest_laps = GogglesDb::Lap.where(meeting_individual_result_id: dest_mir.id).index_by(&:length_in_meters)
      src_laps = GogglesDb::Lap.where(meeting_individual_result_id: src_mir.id)
      return if src_laps.empty?

      if dest_laps.empty?
        @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{dest_mir.meeting_program_id}, meeting_individual_result_id=#{dest_mir.id} WHERE meeting_individual_result_id=#{src_mir.id};"
      else
        src_laps.each do |src_lap|
          dest_lap = dest_laps[src_lap.length_in_meters]
          if dest_lap
            set_clauses, = build_merge_set_clauses(src_lap, dest_lap, lap_merge_columns, 'Lap')
            @sql_log << "UPDATE laps SET updated_at=NOW(), #{set_clauses.join(', ')} WHERE id=#{dest_lap.id};" if set_clauses.any?
          else
            @sql_log << "UPDATE laps SET updated_at=NOW(), meeting_program_id=#{dest_mir.meeting_program_id}, meeting_individual_result_id=#{dest_mir.id} WHERE id=#{src_lap.id};"
          end
        end
        @sql_log << "DELETE FROM laps WHERE meeting_individual_result_id=#{src_mir.id};"
      end
    end

    def prepare_script_for_relay_results
      @sql_log << "\r\n-- === RELAY RESULTS (MRRs, MRS, RelayLaps) ==="
      shared_keys = @checker.shared_program_keys
      shared_keys.each { |key| prepare_mrrs_for_shared_program(key) }
      @sql_log << '-- Source-only program MRRs already moved with programs'
    end

    def prepare_mrrs_for_shared_program(program_key)
      program_data = @checker.program_map[program_key]
      src_program_id = program_data[:src_id]
      dest_program_id = program_data[:dest_id]
      src_mrrs = GogglesDb::MeetingRelayResult.where(meeting_program_id: src_program_id)
      dest_mrrs = GogglesDb::MeetingRelayResult.where(meeting_program_id: dest_program_id)
      return if src_mrrs.empty?

      src_mrrs.each do |src_mrr|
        dest_mrr = dest_mrrs.find_by(team_id: src_mrr.team_id)
        if dest_mrr
          merge_mrr_into_dest(src_mrr, dest_mrr)
        else
          @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), meeting_program_id=#{dest_program_id} WHERE id=#{src_mrr.id};"
        end
        Rails.logger.debug("\033[1;33;35m.\033[0m") if @console_output
      end
    end

    def merge_mrr_into_dest(src_mrr, dest_mrr)
      set_clauses, = build_merge_set_clauses(src_mrr, dest_mrr, mrr_merge_columns, 'MRR')
      @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), #{set_clauses.join(', ')} WHERE id=#{dest_mrr.id};" if set_clauses.any?
      merge_mrs_for_mrr(src_mrr, dest_mrr)
      @sql_log << "DELETE FROM meeting_relay_results WHERE id=#{src_mrr.id};"
    end

    def merge_mrs_for_mrr(src_mrr, dest_mrr)
      dest_mrs_list = GogglesDb::MeetingRelaySwimmer.where(meeting_relay_result_id: dest_mrr.id).index_by(&:relay_order)
      src_mrs_list = GogglesDb::MeetingRelaySwimmer.where(meeting_relay_result_id: src_mrr.id)
      return if src_mrs_list.empty?

      if dest_mrs_list.empty?
        @sql_log << "UPDATE meeting_relay_swimmers SET updated_at=NOW(), meeting_relay_result_id=#{dest_mrr.id} WHERE meeting_relay_result_id=#{src_mrr.id};"
        src_mrs_list.each do |mrs|
          @sql_log << "UPDATE relay_laps SET updated_at=NOW(), meeting_relay_result_id=#{dest_mrr.id} WHERE meeting_relay_swimmer_id=#{mrs.id};"
        end
      else
        src_mrs_list.each do |src_mrs|
          dest_mrs = dest_mrs_list[src_mrs.relay_order]
          next unless dest_mrs

          set_clauses, = build_merge_set_clauses(src_mrs, dest_mrs, mrs_merge_columns, 'MRS')
          @sql_log << "UPDATE meeting_relay_swimmers SET updated_at=NOW(), #{set_clauses.join(', ')} WHERE id=#{dest_mrs.id};" if set_clauses.any?
          merge_relay_laps_for_mrs(src_mrs, dest_mrs)
        end
        src_mrs_list.each { |mrs| @sql_log << "DELETE FROM relay_laps WHERE meeting_relay_swimmer_id=#{mrs.id};" }
        @sql_log << "DELETE FROM meeting_relay_swimmers WHERE meeting_relay_result_id=#{src_mrr.id};"
      end
    end

    def merge_relay_laps_for_mrs(src_mrs, dest_mrs)
      dest_relay_laps = GogglesDb::RelayLap.where(meeting_relay_swimmer_id: dest_mrs.id).index_by(&:length_in_meters)
      src_relay_laps = GogglesDb::RelayLap.where(meeting_relay_swimmer_id: src_mrs.id)
      return if src_relay_laps.empty? || dest_relay_laps.empty?

      src_relay_laps.each do |src_lap|
        dest_lap = dest_relay_laps[src_lap.length_in_meters]
        next unless dest_lap

        set_clauses, = build_merge_set_clauses(src_lap, dest_lap, relay_lap_merge_columns, 'RelayLap')
        @sql_log << "UPDATE relay_laps SET updated_at=NOW(), #{set_clauses.join(', ')} WHERE id=#{dest_lap.id};" if set_clauses.any?
      end
    end

    #-- ------------------------------------------------------------------------
    #   Generic Merge Helpers
    #-- ------------------------------------------------------------------------

    def build_merge_set_clauses(src, dest, columns_config, entity_label)
      clauses = []
      differences = []

      columns_config.each do |col, col_type|
        src_val = src.send(col)
        dest_val = dest.send(col)

        should_update = case col_type
                        when :integer then src_val.to_i.positive? && src_val.to_i != dest_val.to_i
                        when :float then src_val.to_f.positive? && (src_val.to_f - dest_val.to_f).abs > 0.001
                        when :boolean then src_val == true && src_val != dest_val
                        when :string then src_val.present? && src_val != dest_val
                        else false
                        end

        next unless should_update

        sql_val = case col_type
                  when :boolean then src_val ? 1 : 0
                  when :string then "'#{src_val.to_s.gsub("'", "''")}'"
                  else src_val
                  end

        clauses << "#{col}=#{sql_val}"
        differences << "#{entity_label} #{src.id}->#{dest.id}: #{col} #{dest_val} => #{src_val}"
      end

      differences.each { |diff| @warning_log << diff } if differences.any?
      [clauses, differences]
    end

    def mir_merge_columns
      { minutes: :integer, seconds: :integer, hundredths: :integer, rank: :integer,
        standard_points: :float, meeting_points: :float, goggle_cup_points: :float,
        team_points: :float, reaction_time: :float, disqualified: :boolean,
        out_of_race: :boolean, play_off: :boolean, personal_best: :boolean, season_type_best: :boolean }
    end

    def mrr_merge_columns
      { minutes: :integer, seconds: :integer, hundredths: :integer, rank: :integer,
        standard_points: :float, meeting_points: :float, reaction_time: :float,
        entry_minutes: :integer, entry_seconds: :integer, entry_hundredths: :integer,
        disqualified: :boolean, out_of_race: :boolean, play_off: :boolean, relay_code: :string }
    end

    def lap_merge_columns
      { minutes: :integer, seconds: :integer, hundredths: :integer,
        minutes_from_start: :integer, seconds_from_start: :integer, hundredths_from_start: :integer,
        reaction_time: :float, stroke_cycles: :integer, breath_cycles: :integer,
        underwater_seconds: :integer, underwater_hundredths: :integer, underwater_kicks: :integer, position: :integer }
    end

    def mrs_merge_columns
      { minutes: :integer, seconds: :integer, hundredths: :integer,
        minutes_from_start: :integer, seconds_from_start: :integer, hundredths_from_start: :integer, reaction_time: :float }
    end

    def relay_lap_merge_columns
      { minutes: :integer, seconds: :integer, hundredths: :integer,
        minutes_from_start: :integer, seconds_from_start: :integer, hundredths_from_start: :integer,
        reaction_time: :float, stroke_cycles: :integer, breath_cycles: :integer, position: :integer }
    end

    #-- ------------------------------------------------------------------------
    #   Phase 4: Auxiliary entities
    #-- ------------------------------------------------------------------------

    def prepare_script_for_team_scores
      @sql_log << "\r\n-- === TEAM SCORES ==="
      src_scores = @checker.src_team_scores
      dest_scores = @checker.dest_team_scores
      if src_scores.empty?
        @sql_log << '-- No source team scores to process.'
        return
      end

      src_scores.each do |src_score|
        dest_score = dest_scores.find_by(team_id: src_score.team_id)
        if dest_score
          set_clauses, = build_merge_set_clauses(src_score, dest_score, team_score_merge_columns, 'TeamScore')
          @sql_log << "UPDATE meeting_team_scores SET updated_at=NOW(), #{set_clauses.join(', ')} WHERE id=#{dest_score.id};" if set_clauses.any?
          @sql_log << "DELETE FROM meeting_team_scores WHERE id=#{src_score.id};"
        else
          @sql_log << "UPDATE meeting_team_scores SET updated_at=NOW(), meeting_id=#{@dest.id} WHERE id=#{src_score.id};"
        end
      end
    end

    def team_score_merge_columns
      { sum_individual_points: :float, sum_relay_points: :float, sum_team_points: :float,
        meeting_points: :float, meeting_relay_points: :float, meeting_team_points: :float,
        season_points: :float, season_relay_points: :float, season_team_points: :float, rank: :integer }
    end

    def prepare_script_for_deprecated_entities
      @sql_log << "\r\n-- === DEPRECATED ENTITIES (DELETE) ==="
      @sql_log << "DELETE FROM meeting_entries WHERE meeting_program_id IN (SELECT id FROM meeting_programs WHERE meeting_event_id IN (SELECT id FROM meeting_events WHERE meeting_session_id IN (SELECT id FROM meeting_sessions WHERE meeting_id=#{@source.id})));"
      @sql_log << "DELETE FROM meeting_event_reservations WHERE meeting_id=#{@source.id};"
      @sql_log << "DELETE FROM meeting_relay_reservations WHERE meeting_id=#{@source.id};"
      @sql_log << "DELETE FROM meeting_reservations WHERE meeting_id=#{@source.id};"
    end

    def prepare_script_for_calendar
      @sql_log << "\r\n-- === CALENDAR ==="
      src_calendar = GogglesDb::Calendar.find_by(meeting_id: @source.id)
      if src_calendar
        @sql_log << "DELETE FROM calendars WHERE meeting_id=#{@source.id};"
        log_progress('Calendar', src_calendar.id, 'deleted (source)')
      else
        @sql_log << '-- No source calendar to delete.'
      end
    end

    def prepare_script_for_meeting_columns
      @sql_log << "\r\n-- === UPDATE DESTINATION MEETING COLUMNS ==="
      set_clauses = []
      set_clauses << 'results_acquired=1' if @source.results_acquired && !@dest.results_acquired
      set_clauses << 'manifest=1' if @source.manifest && !@dest.manifest
      set_clauses << 'startlist=1' if @source.startlist && !@dest.startlist
      @sql_log << if set_clauses.any?
                    "UPDATE meetings SET updated_at=NOW(), #{set_clauses.join(', ')} WHERE id=#{@dest.id};"
                  else
                    '-- No meeting column updates needed.'
                  end
    end

    def prepare_script_for_source_deletion
      @sql_log << "\r\n-- === DELETE SOURCE MEETING (bottom-up) ==="
      @checker.shared_session_keys.each do |scheduled_date|
        src_session_id = @checker.session_map[scheduled_date][:src_id]
        next unless src_session_id

        @sql_log << "DELETE FROM meeting_events WHERE meeting_session_id=#{src_session_id};"
        @sql_log << "DELETE FROM meeting_sessions WHERE id=#{src_session_id};"
      end
      @sql_log << "DELETE FROM meetings WHERE id=#{@source.id};"
      log_progress('Meeting', @source.id, 'deleted (source)')
    end

    def log_progress(entity_name, entity_id, action)
      @warning_log << "[#{entity_name} ##{entity_id}] #{action}"
    end

    #-- ------------------------------------------------------------------------
    #   Expected Counts Calculation (for post-merge verification)
    #-- ------------------------------------------------------------------------

    def calculate_expected_counts
      src_only_mirs = count_source_only_mirs
      src_only_mrrs = count_source_only_mrrs
      src_only_mrs = count_source_only_mrs
      src_only_relay_laps = count_source_only_relay_laps
      src_only_team_scores = count_source_only_team_scores

      {
        events: @checker.event_map.size,
        programs: @checker.program_map.size,
        mirs: @checker.dest_mirs.count + src_only_mirs,
        laps: count_expected_laps,
        mrrs: @checker.dest_mrrs.count + src_only_mrrs,
        mrs: count_dest_mrs + src_only_mrs,
        relay_laps: count_dest_relay_laps + src_only_relay_laps,
        team_scores: @checker.dest_team_scores.count + src_only_team_scores
      }
    end

    def actual_counts
      dest_meeting = GogglesDb::Meeting.find(@dest.id)
      {
        events: dest_meeting.meeting_events.count,
        programs: dest_meeting.meeting_programs.count,
        mirs: dest_meeting.meeting_individual_results.count,
        laps: dest_meeting.laps.count,
        mrrs: dest_meeting.meeting_relay_results.count,
        mrs: dest_meeting.meeting_relay_swimmers.count,
        relay_laps: GogglesDb::RelayLap.joins(meeting_relay_swimmer: { meeting_relay_result: { meeting_program: { meeting_event: :meeting_session } } })
                                       .where(meeting_sessions: { meeting_id: @dest.id }).count,
        team_scores: dest_meeting.meeting_team_scores.count
      }
    end

    def count_source_only_mirs
      count = 0
      @checker.src_only_program_keys.each do |key|
        src_program_id = @checker.program_map[key][:src_id]
        count += GogglesDb::MeetingIndividualResult.where(meeting_program_id: src_program_id).count
      end
      @checker.shared_program_keys.each do |key|
        src_program_id = @checker.program_map[key][:src_id]
        dest_program_id = @checker.program_map[key][:dest_id]
        src_mirs = GogglesDb::MeetingIndividualResult.where(meeting_program_id: src_program_id)
        dest_mirs = GogglesDb::MeetingIndividualResult.where(meeting_program_id: dest_program_id)
        src_mirs.each do |src_mir|
          count += 1 unless dest_mirs.exists?(swimmer_id: src_mir.swimmer_id, team_id: src_mir.team_id)
        end
      end
      count
    end

    def count_expected_laps
      dest_laps = @checker.dest.laps.count
      return @checker.source.laps.count if dest_laps.zero?

      dest_laps
    end

    def count_source_only_mrrs
      count = 0
      @checker.src_only_program_keys.each do |key|
        src_program_id = @checker.program_map[key][:src_id]
        count += GogglesDb::MeetingRelayResult.where(meeting_program_id: src_program_id).count
      end
      @checker.shared_program_keys.each do |key|
        src_program_id = @checker.program_map[key][:src_id]
        dest_program_id = @checker.program_map[key][:dest_id]
        src_mrrs = GogglesDb::MeetingRelayResult.where(meeting_program_id: src_program_id)
        dest_mrrs = GogglesDb::MeetingRelayResult.where(meeting_program_id: dest_program_id)
        src_mrrs.each { |src_mrr| count += 1 unless dest_mrrs.exists?(team_id: src_mrr.team_id) }
      end
      count
    end

    def count_dest_mrs
      GogglesDb::MeetingRelaySwimmer.joins(meeting_relay_result: { meeting_program: { meeting_event: :meeting_session } })
                                    .where(meeting_sessions: { meeting_id: @dest.id }).count
    end

    def count_source_only_mrs
      dest_mrs_count = count_dest_mrs
      return @checker.source.meeting_relay_swimmers.count if dest_mrs_count.zero?

      0
    end

    def count_dest_relay_laps
      GogglesDb::RelayLap.joins(meeting_relay_swimmer: { meeting_relay_result: { meeting_program: { meeting_event: :meeting_session } } })
                         .where(meeting_sessions: { meeting_id: @dest.id }).count
    end

    def count_source_only_relay_laps
      dest_relay_laps_count = count_dest_relay_laps
      src_relay_laps = GogglesDb::RelayLap.joins(meeting_relay_swimmer: { meeting_relay_result: { meeting_program: { meeting_event: :meeting_session } } })
                                          .where(meeting_sessions: { meeting_id: @source.id }).count
      return src_relay_laps if dest_relay_laps_count.zero?

      0
    end

    def count_source_only_team_scores
      src_scores = @checker.src_team_scores
      dest_scores = @checker.dest_team_scores
      src_scores.count { |src| !dest_scores.exists?(team_id: src.team_id) }
    end
  end
end
