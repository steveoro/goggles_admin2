# frozen_string_literal: true

module Merge
  # = Merge::MeetingChecker
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #   - build:    20260104
  #
  # Check the feasibility of merging two Meeting entities belonging to the same Season,
  # while gathering all sub-entities that need to be moved, updated, or purged.
  #
  # This checker builds mapping data structures for efficient lookup during the merge phase:
  # - Sessions: mapped by scheduled_date
  # - Events: mapped by event_type_id (within session context)
  # - Programs: mapped by (event_type_id, category_type_id, gender_type_id)
  # - MIRs: mapped by (program_key, team_id, swimmer_id)
  # - MRRs: mapped by (program_key, team_id)
  #
  # See docs/merge_meeting_task_plan.md for full specification.
  # rubocop:disable Rails/Output
  class MeetingChecker
    attr_reader :log, :errors, :warnings,
                :source, :dest,
                :session_map, :event_map, :program_map

    #-- -----------------------------------------------------------------------
    #++

    # Initializes the MeetingChecker.
    #
    # == Attributes:
    # - <tt>#log</tt> => analysis log (array of string lines)
    # - <tt>#errors</tt> => error messages (array of string messages)
    # - <tt>#warnings</tt> => warning messages (array of string messages)
    # - <tt>#session_map</tt> => Hash mapping scheduled_date to { src_id:, dest_id: }
    # - <tt>#event_map</tt> => Hash mapping [session_key, event_type_id] to { src_id:, dest_id: }
    # - <tt>#program_map</tt> => Hash mapping [event_type_id, category_type_id, gender_type_id] to { src_id:, dest_id: }
    #
    # == Params:
    # - <tt>:source</tt> => source Meeting row, *required*
    # - <tt>:dest</tt> => destination Meeting row, *required*
    # - <tt>:console_output</tt> => when +true+ (default) a simple progress status will be printed on stdout
    #
    def initialize(source:, dest:, console_output: true)
      raise(ArgumentError, 'Both source and destination must be Meetings!') unless source.is_a?(GogglesDb::Meeting) && dest.is_a?(GogglesDb::Meeting)
      raise(ArgumentError, 'Identical source and destination!') if source.id == dest.id

      @source = source.decorate
      @dest = dest.decorate
      @console_output = console_output
      initialize_data
    end
    #-- ------------------------------------------------------------------------
    #++

    # Launches the analysis process for merge feasibility while collecting
    # all data for the internal members. *This process DOES NOT alter the database.*
    #
    # Returns +true+ if the merge seems feasible, +false+ otherwise.
    # Check the #log & #errors members for details and error messages.
    def run
      initialize_data if @log.present?

      # Validate same season (critical requirement)
      if @source.season_id != @dest.season_id
        @errors << "Meetings belong to different Seasons! (source: #{@source.season_id}, dest: #{@dest.season_id})"
        return false
      end

      @log << "\r\n\t*** Meeting Merge Checker ***"
      @log << meeting_header

      # Build all mapping structures
      puts("\r\nMapping sessions, events and programs...") if @console_output
      build_session_map
      build_event_map
      build_program_map

      # Log analysis results
      @log += session_analysis
      @log += event_analysis
      @log += program_analysis
      @log += result_analysis

      @errors.blank?
    end
    #-- ------------------------------------------------------------------------
    #++

    # Creates and outputs to stdout a detailed report of the entities involved in merging
    # the source into the destination.
    def display_report
      puts(@log.join("\r\n"))
      display_short_summary
    end

    # Outputs the short summary of the checking to stdout.
    def display_short_summary
      puts("\r\n\r\n*** WARNINGS: ***\r\n#{@warnings.join("\r\n")}") if @warnings.present?
      puts("\r\n\r\n*** ERRORS: ***\r\n#{@errors.join("\r\n")}") if @errors.present?
      puts("\r\n")
      puts(@errors.blank? ? 'RESULT: ✅ Merge feasible' : 'RESULT: ❌ Merge NOT feasible')
      nil
    end
    # rubocop:enable Rails/Output

    #-- ------------------------------------------------------------------------
    #   Session Mapping Accessors
    #-- ------------------------------------------------------------------------

    # Returns an array of scheduled_date keys for sessions only in source meeting.
    def src_only_session_keys
      @session_map.select { |_k, v| v[:src_id].present? && v[:dest_id].blank? }.keys
    end

    # Returns an array of scheduled_date keys for sessions only in destination meeting.
    def dest_only_session_keys
      @session_map.select { |_k, v| v[:src_id].blank? && v[:dest_id].present? }.keys
    end

    # Returns an array of scheduled_date keys for sessions shared between source and destination.
    def shared_session_keys
      @session_map.select { |_k, v| v[:src_id].present? && v[:dest_id].present? }.keys
    end

    #-- ------------------------------------------------------------------------
    #   Event Mapping Accessors
    #-- ------------------------------------------------------------------------

    # Returns an array of [session_key, event_type_id] keys for events only in source meeting.
    def src_only_event_keys
      @event_map.select { |_k, v| v[:src_id].present? && v[:dest_id].blank? }.keys
    end

    # Returns an array of [session_key, event_type_id] keys for events only in destination meeting.
    def dest_only_event_keys
      @event_map.select { |_k, v| v[:src_id].blank? && v[:dest_id].present? }.keys
    end

    # Returns an array of [session_key, event_type_id] keys for events shared between source and destination.
    def shared_event_keys
      @event_map.select { |_k, v| v[:src_id].present? && v[:dest_id].present? }.keys
    end

    #-- ------------------------------------------------------------------------
    #   Program Mapping Accessors
    #-- ------------------------------------------------------------------------

    # Returns an array of [event_type_id, category_type_id, gender_type_id] keys for programs only in source.
    def src_only_program_keys
      @program_map.select { |_k, v| v[:src_id].present? && v[:dest_id].blank? }.keys
    end

    # Returns an array of [event_type_id, category_type_id, gender_type_id] keys for programs only in dest.
    def dest_only_program_keys
      @program_map.select { |_k, v| v[:src_id].blank? && v[:dest_id].present? }.keys
    end

    # Returns an array of [event_type_id, category_type_id, gender_type_id] keys for shared programs.
    def shared_program_keys
      @program_map.select { |_k, v| v[:src_id].present? && v[:dest_id].present? }.keys
    end

    #-- ------------------------------------------------------------------------
    #   Entity Retrieval Helpers
    #-- ------------------------------------------------------------------------

    # Returns source MeetingSessions ordered by session_order.
    def src_sessions
      @src_sessions ||= @source.meeting_sessions.order(:session_order)
    end

    # Returns destination MeetingSessions ordered by session_order.
    def dest_sessions
      @dest_sessions ||= @dest.meeting_sessions.order(:session_order)
    end

    # Returns source MeetingPrograms.
    def src_programs
      @src_programs ||= @source.meeting_programs
    end

    # Returns destination MeetingPrograms.
    def dest_programs
      @dest_programs ||= @dest.meeting_programs
    end

    # Returns source MeetingIndividualResults.
    def src_mirs
      @src_mirs ||= @source.meeting_individual_results
    end

    # Returns destination MeetingIndividualResults.
    def dest_mirs
      @dest_mirs ||= @dest.meeting_individual_results
    end

    # Returns source MeetingRelayResults.
    def src_mrrs
      @src_mrrs ||= @source.meeting_relay_results
    end

    # Returns destination MeetingRelayResults.
    def dest_mrrs
      @dest_mrrs ||= @dest.meeting_relay_results
    end

    # Returns source MeetingTeamScores.
    def src_team_scores
      @src_team_scores ||= @source.meeting_team_scores
    end

    # Returns destination MeetingTeamScores.
    def dest_team_scores
      @dest_team_scores ||= @dest.meeting_team_scores
    end

    private

    # Initializes/resets all internal state variables for the analysis.
    def initialize_data
      @log = []
      @errors = []
      @warnings = []
      @session_map = {}
      @event_map = {}
      @program_map = {}
    end

    # Returns a formatted header string describing source and destination meetings.
    def meeting_header
      "\r\n🔹[Src  MEETING: #{@source.id.to_s.rjust(6)}] #{@source.display_label}\r\n" \
        "🔹[Dest MEETING: #{@dest.id.to_s.rjust(6)}] #{@dest.display_label}\r\n   " \
        "Season: #{@source.season_id} (#{@source.season.description})\r\n"
    end

    #-- ------------------------------------------------------------------------
    #   Mapping Builders
    #-- ------------------------------------------------------------------------

    # Builds the session_map: { scheduled_date => { src_id:, dest_id:, src_session_order:, dest_session_order: } }
    def build_session_map
      # Add source sessions
      src_sessions.each do |session|
        key = session.scheduled_date
        @session_map[key] ||= { src_id: nil, dest_id: nil, src_session_order: nil, dest_session_order: nil }
        @session_map[key][:src_id] = session.id
        @session_map[key][:src_session_order] = session.session_order
      end

      # Add destination sessions
      dest_sessions.each do |session|
        key = session.scheduled_date
        @session_map[key] ||= { src_id: nil, dest_id: nil, src_session_order: nil, dest_session_order: nil }
        @session_map[key][:dest_id] = session.id
        @session_map[key][:dest_session_order] = session.session_order
      end
    end

    # Builds the event_map: { [scheduled_date, event_type_id] => { src_id:, dest_id: } }
    def build_event_map
      # Add source events
      @source.meeting_events.includes(:meeting_session).find_each do |event|
        session_key = event.meeting_session.scheduled_date
        key = [session_key, event.event_type_id]
        @event_map[key] ||= { src_id: nil, dest_id: nil }
        @event_map[key][:src_id] = event.id
      end

      # Add destination events
      @dest.meeting_events.includes(:meeting_session).find_each do |event|
        session_key = event.meeting_session.scheduled_date
        key = [session_key, event.event_type_id]
        @event_map[key] ||= { src_id: nil, dest_id: nil }
        @event_map[key][:dest_id] = event.id
      end
    end

    # Builds the program_map: { [event_type_id, category_type_id, gender_type_id] => { src_id:, dest_id:, src_event_id:, dest_event_id: } }
    def build_program_map
      # Add source programs
      src_programs.includes(:event_type).find_each do |program|
        key = [program.event_type.id, program.category_type_id, program.gender_type_id]
        @program_map[key] ||= { src_id: nil, dest_id: nil, src_event_id: nil, dest_event_id: nil }
        @program_map[key][:src_id] = program.id
        @program_map[key][:src_event_id] = program.meeting_event_id
      end

      # Add destination programs
      dest_programs.includes(:event_type).find_each do |program|
        key = [program.event_type.id, program.category_type_id, program.gender_type_id]
        @program_map[key] ||= { src_id: nil, dest_id: nil, src_event_id: nil, dest_event_id: nil }
        @program_map[key][:dest_id] = program.id
        @program_map[key][:dest_event_id] = program.meeting_event_id
      end
    end

    #-- ------------------------------------------------------------------------
    #   Analysis Methods
    #-- ------------------------------------------------------------------------

    # Returns an array of log strings analyzing the session distribution.
    def session_analysis
      Rails.logger.debug('- Sessions analysis...') if @console_output
      lines = ["\r\n--- Sessions Analysis ---"]
      lines << "Source sessions:      #{src_sessions.count}"
      lines << "Destination sessions: #{dest_sessions.count}"
      lines << "Shared (by date):     #{shared_session_keys.count}"
      lines << "Source-only:          #{src_only_session_keys.count}"
      lines << "Dest-only:            #{dest_only_session_keys.count}"

      if src_only_session_keys.any?
        lines << "\r\nSource-only sessions (will be moved to dest meeting):"
        src_only_session_keys.each do |date|
          session = GogglesDb::MeetingSession.find(@session_map[date][:src_id])
          lines << "  - #{date}: session_order=#{session.session_order}, #{session.description}"
        end
      end

      lines
    end

    # Returns an array of log strings analyzing the event distribution.
    def event_analysis
      Rails.logger.debug('- Event analysis...') if @console_output
      lines = ["\r\n--- Events Analysis ---"]
      lines << "Source events:      #{@source.meeting_events.count}"
      lines << "Destination events: #{@dest.meeting_events.count}"
      lines << "Shared:             #{shared_event_keys.count}"
      lines << "Source-only:        #{src_only_event_keys.count}"
      lines << "Dest-only:          #{dest_only_event_keys.count}"

      if src_only_event_keys.any?
        lines << "\r\nSource-only events (will be moved to dest session):"
        src_only_event_keys.each do |(date, event_type_id)|
          event_type = GogglesDb::EventType.find(event_type_id)
          lines << "  - #{date}: #{event_type.code} (#{event_type.label})"
        end
      end

      lines
    end

    # Returns an array of log strings analyzing the program distribution.
    def program_analysis
      Rails.logger.debug('- Program analysis...') if @console_output
      lines = ["\r\n--- Programs Analysis ---"]
      lines << "Source programs:      #{src_programs.count}"
      lines << "Destination programs: #{dest_programs.count}"
      lines << "Shared:               #{shared_program_keys.count}"
      lines << "Source-only:          #{src_only_program_keys.count}"
      lines << "Dest-only:            #{dest_only_program_keys.count}"

      if shared_program_keys.any? && shared_program_keys.count <= 20
        lines << "\r\nShared programs (dest will be updated with source data):"
        shared_program_keys.each do |(event_type_id, category_type_id, gender_type_id)|
          event_type = GogglesDb::EventType.find(event_type_id)
          category_type = GogglesDb::CategoryType.find(category_type_id)
          gender_type = GogglesDb::GenderType.find(gender_type_id)
          lines << "  - #{event_type.code} / #{category_type.code} / #{gender_type.code}"
        end
      end

      lines
    end

    # Returns an array of log strings analyzing the results distribution.
    def result_analysis
      Rails.logger.debug('- Results & details analysis...') if @console_output
      lines = ["\r\n--- Results Analysis ---"]

      # MIRs
      lines << "Source MIRs:      #{src_mirs.count}"
      lines << "Destination MIRs: #{dest_mirs.count}"

      # MRRs
      lines << "Source MRRs:      #{src_mrrs.count}"
      lines << "Destination MRRs: #{dest_mrrs.count}"

      # Laps
      src_laps = @source.laps.count
      dest_laps = @dest.laps.count
      lines << "Source Laps:      #{src_laps}"
      lines << "Destination Laps: #{dest_laps}"

      # MRS (MeetingRelaySwimmers)
      src_mrs = @source.meeting_relay_swimmers.count
      dest_mrs = @dest.meeting_relay_swimmers.count
      lines << "Source MRS:       #{src_mrs}"
      lines << "Destination MRS:  #{dest_mrs}"

      # Team Scores
      lines << "\r\n--- Team Scores ---"
      lines << "Source team scores:      #{src_team_scores.count}"
      lines << "Destination team scores: #{dest_team_scores.count}"

      # Detect potential timing conflicts in shared programs
      timing_conflicts = detect_timing_conflicts
      @warnings << "Found #{timing_conflicts.count} potential timing conflicts in shared programs (will be logged)" if timing_conflicts.any?

      lines
    end

    # Detects MIRs with different timings for the same swimmer in shared programs.
    # Returns an array of conflict descriptions.
    # rubocop:disable Rails/Output
    def detect_timing_conflicts
      conflicts = []

      shared_program_keys.each do |key|
        src_program_id = @program_map[key][:src_id]
        dest_program_id = @program_map[key][:dest_id]
        next if src_program_id.blank? || dest_program_id.blank?

        src_program_mirs = GogglesDb::MeetingIndividualResult.where(meeting_program_id: src_program_id)
        dest_program_mirs = GogglesDb::MeetingIndividualResult.where(meeting_program_id: dest_program_id)

        src_program_mirs.each do |src_mir|
          dest_mir = dest_program_mirs.find_by(swimmer_id: src_mir.swimmer_id, team_id: src_mir.team_id)
          # No target - GREY
          unless dest_mir
            $stdout.write("\033[1;33;30m.\033[0m") if @console_output
            next
          end

          # Compare timings (using timing object for proper comparison)
          src_timing = src_mir.to_timing
          dest_timing = dest_mir.to_timing
          # Timing equal or non-conflict (dest. is zero) - GREEN
          if src_timing == dest_timing || dest_timing.zero?
            $stdout.write("\033[1;33;32m.\033[0m") if @console_output
            next
          end

          # Timing slightly different (delta < 1"): considered for update - YELLOW
          if src_timing.minutes == dest_timing.minutes && src_timing.seconds == dest_timing.seconds
            $stdout.write("\033[1;33;33m.\033[0m") if @console_output
            next
          end

          # Conflict - RED
          $stdout.write("\033[1;33;31m.\033[0m") if @console_output
          conflicts << {
            program_key: key,
            swimmer_id: src_mir.swimmer_id,
            src_timing: src_timing.to_s,
            dest_timing: dest_timing.to_s
          }
        end
      end

      conflicts
    end
  end
end
