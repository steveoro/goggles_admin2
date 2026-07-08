# frozen_string_literal: true

module Purge
  # = Purge::Meeting
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #   - build:    20260708
  #
  # Generates a replayable SQL script that purges all data associated to a
  # specific Meeting, respecting the FK hierarchy bottom-up.
  #
  # The script is wrapped in a single transaction for atomicity and can be
  # tested on database dumps before being pushed to the production server.
  #
  # When +stop_at_events+ is +true+, the purge stops at +meeting_programs+,
  # leaving events, sessions, reservations, team scores, calendar, and the
  # meeting row itself untouched.
  #
  # == Usage:
  #   purger = Purge::Meeting.new(meeting: meeting)
  #   purger.prepare
  #   purger.single_transaction_sql_log  # Get wrapped SQL
  #
  class Meeting # rubocop:disable Metrics/ClassLength
    attr_reader :meeting, :stop_at_events, :sql_log, :row_counts

    # == Params:
    # - <tt>:meeting</tt> => Meeting instance (*required*)
    # - <tt>:stop_at_events</tt> => when +true+, stops after deleting meeting_programs (default: +false+)
    #
    def initialize(meeting:, stop_at_events: false)
      raise(ArgumentError, 'Invalid meeting: must be a GogglesDb::Meeting instance') unless meeting.is_a?(GogglesDb::Meeting)

      @meeting = meeting
      @stop_at_events = stop_at_events
      @sql_log = []
      @row_counts = {}
    end
    #-- -----------------------------------------------------------------------
    #++

    # Builds the SQL log with all DELETE statements in hierarchical order.
    def prepare
      @sql_log = []
      @row_counts = {}
      add_script_header
      collect_row_counts
      add_deletion_statements
      @sql_log
    end

    # Returns the SQL log wrapped in a single transaction.
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

    # Displays a summary of row counts that will be purged.
    def display_report
      puts "\r\n#{'=' * 60}"
      puts 'Purge Meeting Report'
      puts "Meeting: #{@meeting.id} - #{@meeting.description}"
      puts "Stop at events: #{@stop_at_events ? 'YES' : 'no (full purge)'}"
      puts "#{'=' * 60}\r\n"

      collect_row_counts if @row_counts.empty?

      @row_counts.each do |table, count|
        puts "  #{table.ljust(35)} : #{count} rows"
      end

      total = @row_counts.values.sum
      puts "\r\n  #{'TOTAL'.ljust(35)} : #{total} rows"
      puts "#{'=' * 60}\r\n"
    end

    private

    def add_script_header
      @sql_log << "-- Purge Meeting #{@meeting.id}: #{@meeting.description}"
      @sql_log << "-- Generated: #{Time.zone.now}"
      @sql_log << "-- Mode: #{@stop_at_events ? 'STOP AT EVENTS (meeting_programs)' : 'FULL PURGE'}"
      @sql_log << ''
    end

    def collect_row_counts # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      meeting_id = @meeting.id

      @row_counts['laps'] = GogglesDb::Lap
                            .joins(meeting_individual_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } })
                            .where(meetings: { id: meeting_id }).count

      @row_counts['relay_laps'] = GogglesDb::RelayLap
                                  .joins(meeting_relay_swimmer: { meeting_relay_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } } })
                                  .where(meetings: { id: meeting_id }).count

      @row_counts['individual_records'] = GogglesDb::IndividualRecord
                                          .joins(:meeting_individual_result)
                                          .joins('INNER JOIN meeting_programs mp ON meeting_individual_results.meeting_program_id = mp.id')
                                          .joins('INNER JOIN meeting_events me ON mp.meeting_event_id = me.id')
                                          .joins('INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id')
                                          .where(ms: { meeting_id: meeting_id }).count

      @row_counts['meeting_relay_swimmers'] = GogglesDb::MeetingRelaySwimmer
                                              .joins(meeting_relay_result: { meeting_program: { meeting_event: { meeting_session: :meeting } } })
                                              .where(meetings: { id: meeting_id }).count

      @row_counts['meeting_individual_results'] = GogglesDb::MeetingIndividualResult
                                                  .joins(meeting_program: { meeting_event: { meeting_session: :meeting } })
                                                  .where(meetings: { id: meeting_id }).count

      @row_counts['meeting_relay_results'] = GogglesDb::MeetingRelayResult
                                             .joins(meeting_program: { meeting_event: { meeting_session: :meeting } })
                                             .where(meetings: { id: meeting_id }).count

      @row_counts['meeting_entries'] = GogglesDb::MeetingEntry
                                       .joins(meeting_program: { meeting_event: { meeting_session: :meeting } })
                                       .where(meetings: { id: meeting_id }).count

      @row_counts['meeting_programs'] = GogglesDb::MeetingProgram
                                        .joins(meeting_event: { meeting_session: :meeting })
                                        .where(meetings: { id: meeting_id }).count

      return if @stop_at_events

      @row_counts['meeting_event_reservations'] = GogglesDb::MeetingEventReservation.where(meeting_id:).count
      @row_counts['meeting_relay_reservations'] = GogglesDb::MeetingRelayReservation.where(meeting_id:).count
      @row_counts['meeting_events'] = GogglesDb::MeetingEvent.joins(meeting_session: :meeting).where(meetings: { id: meeting_id }).count
      @row_counts['meeting_sessions'] = GogglesDb::MeetingSession.where(meeting_id:).count
      @row_counts['meeting_reservations'] = GogglesDb::MeetingReservation.where(meeting_id:).count
      @row_counts['meeting_team_scores'] = GogglesDb::MeetingTeamScore.where(meeting_id:).count
      @row_counts['calendars'] = GogglesDb::Calendar.where(meeting_id:).count
      @row_counts['meetings'] = 1
    end

    def add_deletion_statements # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
      meeting_id = @meeting.id

      # Step 1: laps
      add_join_delete(
        'laps', 'l',
        <<~SQL.squish
          DELETE l
          FROM laps l
          INNER JOIN meeting_individual_results mir ON l.meeting_individual_result_id = mir.id
          INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      # Step 2: relay_laps
      add_join_delete(
        'relay_laps', 'rl',
        <<~SQL.squish
          DELETE rl
          FROM relay_laps rl
          INNER JOIN meeting_relay_swimmers mrs ON rl.meeting_relay_swimmer_id = mrs.id
          INNER JOIN meeting_relay_results mrr ON mrs.meeting_relay_result_id = mrr.id
          INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      # Step 3: individual_records
      add_join_delete(
        'individual_records', 'ir',
        <<~SQL.squish
          DELETE ir
          FROM individual_records ir
          INNER JOIN meeting_individual_results mir ON ir.meeting_individual_result_id = mir.id
          INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      # Step 4: meeting_relay_swimmers
      add_join_delete(
        'meeting_relay_swimmers', 'mrs',
        <<~SQL.squish
          DELETE mrs
          FROM meeting_relay_swimmers mrs
          INNER JOIN meeting_relay_results mrr ON mrs.meeting_relay_result_id = mrr.id
          INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      # Step 5: meeting_individual_results
      add_join_delete(
        'meeting_individual_results', 'mir',
        <<~SQL.squish
          DELETE mir
          FROM meeting_individual_results mir
          INNER JOIN meeting_programs mp ON mir.meeting_program_id = mp.id
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      # Step 6: meeting_relay_results
      add_join_delete(
        'meeting_relay_results', 'mrr',
        <<~SQL.squish
          DELETE mrr
          FROM meeting_relay_results mrr
          INNER JOIN meeting_programs mp ON mrr.meeting_program_id = mp.id
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      # Step 7: meeting_entries
      add_join_delete(
        'meeting_entries', 'me',
        <<~SQL.squish
          DELETE me
          FROM meeting_entries me
          INNER JOIN meeting_programs mp ON me.meeting_program_id = mp.id
          INNER JOIN meeting_events mev ON mp.meeting_event_id = mev.id
          INNER JOIN meeting_sessions ms ON mev.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      # Step 8: meeting_programs
      add_join_delete(
        'meeting_programs', 'mp',
        <<~SQL.squish
          DELETE mp
          FROM meeting_programs mp
          INNER JOIN meeting_events me ON mp.meeting_event_id = me.id
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      return if @stop_at_events

      # Step 9: meeting_event_reservations
      add_direct_delete('meeting_event_reservations', meeting_id)

      # Step 10: meeting_relay_reservations
      add_direct_delete('meeting_relay_reservations', meeting_id)

      # Step 11: meeting_events
      add_join_delete(
        'meeting_events', 'me',
        <<~SQL.squish
          DELETE me
          FROM meeting_events me
          INNER JOIN meeting_sessions ms ON me.meeting_session_id = ms.id
          WHERE ms.meeting_id = #{meeting_id};
        SQL
      )

      # Step 12: meeting_sessions
      add_direct_delete('meeting_sessions', meeting_id)

      # Step 13: meeting_reservations
      add_direct_delete('meeting_reservations', meeting_id)

      # Step 14: meeting_team_scores
      add_direct_delete('meeting_team_scores', meeting_id)

      # Step 15: calendars
      add_direct_delete('calendars', meeting_id)

      # Step 16: meetings (the row itself)
      @sql_log << "DELETE FROM meetings WHERE id = #{meeting_id}; -- purge meeting row"
      @sql_log << ''
    end

    def add_join_delete(table_name, _alias, sql)
      count = @row_counts[table_name]
      @sql_log << "-- Step: #{table_name} (#{count} rows)"
      @sql_log << sql
      @sql_log << ''
    end

    def add_direct_delete(table_name, meeting_id)
      count = @row_counts[table_name]
      @sql_log << "-- Step: #{table_name} (#{count} rows)"
      @sql_log << "DELETE FROM #{table_name} WHERE meeting_id = #{meeting_id};"
      @sql_log << ''
    end
  end
end
