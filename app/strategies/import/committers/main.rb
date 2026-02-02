# frozen_string_literal: true

require 'bigdecimal'

module Import
  module Committers
    #
    # = Main
    #
    # Commits all entities from phase files (1-4) and data_import tables (phase 5)
    # to the production database in correct dependency order.
    #
    # == Usage:
    #   committer = Import::Committers::Main.new(
    #     phase1_path: '/path/to/phase1.json',
    #     phase2_path: '/path/to/phase2.json',
    #     phase3_path: '/path/to/phase3.json',
    #     phase4_path: '/path/to/phase4.json',
    #     source_path: '/path/to/source.json'
    #   )
    #   committer.commit_all
    #
    # @author Steve A.
    #
    class Main # rubocop:disable Metrics/ClassLength
      BOOLEAN_TYPE = ActiveModel::Type::Boolean.new

      attr_reader :phase1_path, :phase2_path, :phase3_path, :phase4_path, :phase5_path, :source_path,
                  :phase1_data, :phase2_data, :phase3_data, :phase4_data, :phase5_data,
                  :sql_log, :stats, :logger

      def initialize(phase1_path:, phase2_path:, phase3_path:, phase4_path:, phase5_path:, source_path:, log_path: nil)
        @phase1_path = phase1_path
        @phase2_path = phase2_path
        @phase3_path = phase3_path
        @phase4_path = phase4_path
        @phase5_path = phase5_path
        @source_path = source_path
        @sql_log = []
        @stats = {
          cities_created: 0, cities_updated: 0,
          pools_created: 0, pools_updated: 0,
          meetings_created: 0, meetings_updated: 0,
          calendars_created: 0, calendars_updated: 0,
          sessions_created: 0, sessions_updated: 0,
          teams_created: 0, teams_updated: 0,
          affiliations_created: 0, affiliations_updated: 0,
          swimmers_created: 0, swimmers_updated: 0,
          badges_created: 0, badges_updated: 0,
          events_created: 0, events_updated: 0,
          programs_created: 0, programs_updated: 0,
          mirs_created: 0, mirs_updated: 0,
          laps_created: 0, laps_updated: 0,
          mrrs_created: 0, mrrs_updated: 0,
          mrss_created: 0, mrss_updated: 0,
          relay_laps_created: 0, relay_laps_updated: 0,
          errors: []
        }
        # Initialize logger
        @log_path = log_path || source_path.to_s.gsub('.json', '.log')
        @logger = Import::PhaseCommitLogger.new(log_path: @log_path)
        @transaction_rolled_back = false
        @top_level_error = nil

        # Session order → meeting_session_id mapping (populated in Phase 1, used in Phase 4)
        @session_id_by_order = {}
        # Event key → meeting_event_id mapping (populated in Phase 4, used in Phase 5)
        @event_id_by_key = {}
        # Meeting and season IDs (populated in Phase 1, passed to child committers)
        @meeting = nil
        @season_id = nil
        # Categories cache (populated after season is known, passed to Badge committer)
        @categories_cache = nil
      end
      # -----------------------------------------------------------------------

      # Main entry point: commits all entities in dependency order within a transaction
      def commit_all # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
        load_phase_files!
        broadcast_progress('Loading phase files', 0, 6)

        # Add SQL transaction wrapper
        meeting_name = phase1_data&.dig('data', 'name') || 'Unknown Meeting'
        meeting_date = phase1_data&.dig('data', 'header_date') || Time.current.to_date
        @sql_log << "-- #{meeting_name}"
        @sql_log << "-- #{meeting_date}\r\n"
        @sql_log << 'SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
        @sql_log << 'SET AUTOCOMMIT = 0;'
        @sql_log << 'START TRANSACTION;'
        @sql_log << "--\r\n"

        # Reset outcome flags for this run
        @transaction_rolled_back = false
        @top_level_error = nil

        begin
          ActiveRecord::Base.transaction do
            broadcast_progress('Committing Phase 1', 1, 6)
            commit_phase1_entities  # Meeting, Sessions, Pools, Cities

            broadcast_progress('Committing Phase 2', 2, 6)
            commit_phase2_entities  # Teams, TeamAffiliations

            broadcast_progress('Committing Phase 3', 3, 6)
            commit_phase3_entities  # Swimmers, Badges

            broadcast_progress('Committing Phase 4', 4, 6)
            commit_phase4_entities  # MeetingEvents

            broadcast_progress('Committing Phase 5', 5, 6)
            commit_phase5_entities  # MeetingPrograms, MIRs, Laps (from DB tables)

            # CRITICAL: Check for any errors collected during commit phases.
            # If any errors occurred, raise an exception to trigger transaction rollback.
            # This ensures ALL changes are rolled back when ANY error occurs, maintaining
            # DB consistency for the final SQL script that will run on the target server.
            # NOTE: We use RuntimeError (not ActiveRecord::Rollback) because Rollback is
            # silently swallowed by Rails and won't propagate to our rescue block.
            if @stats[:errors].any?
              error_summary = @stats[:errors].first(5).join('; ')
              error_summary += " (and #{@stats[:errors].size - 5} more)" if @stats[:errors].size > 5
              raise "Commit halted due to #{@stats[:errors].size} error(s): #{error_summary}"
            end
          end

          # Close SQL transaction with COMMIT
          @sql_log << "\r\n--\r\n"
          @sql_log << 'COMMIT;'
        rescue StandardError => e
          # Mark transaction as rolled back in SQL log, record error for logging, and re-raise
          @sql_log << "\r\n--\r\n"
          @sql_log << 'ROLLBACK;'
          @transaction_rolled_back = true
          @top_level_error = e.message
          @stats[:errors] << e.message
          @logger.log_error(message: e.message)
          raise
        ensure
          # Always write log file so Phase 6 report can reference it
          broadcast_progress('Writing log file', 6, 6)
          @logger.write_log_file(
            stats: @stats,
            rolled_back: @transaction_rolled_back,
            top_level_error: @top_level_error
          )
        end

        stats
      end
      # -----------------------------------------------------------------------

      # Returns the SQL log as a formatted string
      def sql_log_content
        sql_log.join("\n")
      end
      # -----------------------------------------------------------------------

      private

      # Load all phase JSON files
      def load_phase_files! # rubocop:disable Metrics/AbcSize
        @phase1_data = JSON.parse(File.read(phase1_path)) if File.exist?(phase1_path)
        @phase2_data = JSON.parse(File.read(phase2_path)) if File.exist?(phase2_path)
        @phase3_data = JSON.parse(File.read(phase3_path)) if File.exist?(phase3_path)
        @phase4_data = JSON.parse(File.read(phase4_path)) if File.exist?(phase4_path)
        @phase5_data = JSON.parse(File.read(phase5_path)) if File.exist?(phase5_path)

        Rails.logger.info('[Main] Loaded phase files (including phase5 with programs)')
      end
      # -----------------------------------------------------------------------

      # Phase 1: Cities, SwimmingPools, Meetings, MeetingSessions
      # Dependency order: City → SwimmingPool → Meeting → MeetingSession
      def commit_phase1_entities # rubocop:disable Metrics/AbcSize
        raise StandardError, 'Null phase 1 data object!' if phase1_data.blank?

        Rails.logger.info('[Main] Committing Phase 1: Meeting, SwimmingPools, Cities & Sessions')
        # Meeting data is directly under 'data', not 'data.meeting'
        meeting_data = phase1_data['data'] || {}

        sessions_data = Array(meeting_data.delete('meeting_session')).map.with_index do |session_hash, index|
          normalize_session_attributes(session_hash, meeting_data['id'], index: index)
        end

        # Commit meeting (returns resulting meeting_id or raises an error)
        meeting_id = meeting_committer.commit(meeting_data)
        @meeting = GogglesDb::Meeting.find(meeting_id)
        @season_id = @meeting.season_id # Link to the actual season ID from the committed meeting

        # Initialize categories cache for efficient category lookups
        @categories_cache = PdfResults::CategoriesCache.new(@meeting.season)

        calendar_committer.commit(meeting_data.merge('meeting_id' => @meeting.id))

        # Update sessions with the resulting meeting id so they can be persisted
        sessions_data.each_with_index do |session_hash, index|
          session_hash['meeting_id'] = @meeting.id
          session_hash['session_order'] ||= index + 1
          # Commit bindings for sessions and capture IDs for Phase 4 lookup
          session_id = commit_bindings_for_meeting_session(session_hash) # TODO: move this into MeetingSession committer, passing also SwimmingPool committer in init
          session_order = session_hash['session_order']
          @session_id_by_order[session_order] = session_id if session_id && session_order
        end
      end
      # -----------------------------------------------------------------------

      # Commit bindings for MeetingSession (SwimmingPool, City)
      def commit_bindings_for_meeting_session(session_hash)
        meeting_id = session_hash['meeting_id'] || @meeting.id
        raise StandardError, 'Null meeting_id in meeting session hash!' if meeting_id.to_i.zero?

        # Commit nested city first (if new)
        city_hash = session_hash.dig('swimming_pool', 'city')
        city_id = city_committer.commit(city_hash)

        # Commit nested swimming pool (may reference city)
        pool_hash = session_hash['swimming_pool']
        pool_hash = pool_hash.merge('city_id' => city_id) if pool_hash && city_id
        swimming_pool_id = swimming_pool_committer.commit(pool_hash)

        normalized_session = session_hash.merge('swimming_pool_id' => swimming_pool_id)
        meeting_session_committer.commit(normalized_session)
      end
      # -----------------------------------------------------------------------

      # Phase 2: Teams, TeamAffiliations
      # Dependency order: Team → TeamAffiliation
      def commit_phase2_entities
        Rails.logger.info('[Main] Committing Phase 2: Teams & Affiliations')
        return unless phase2_data

        teams_data = Array(phase2_data.dig('data', 'teams'))
        affiliations_data = Array(phase2_data.dig('data', 'team_affiliations'))

        # Commit all teams first (Team committer handles ID mapping internally)
        total = teams_data.size
        teams_data.each_with_index do |team_hash, idx|
          team_committer.commit(team_hash)
          broadcast_progress('Committing Teams...', idx + 1, total)
        end
        broadcast_progress('Committing Teams done.', total, total)

        # Then commit affiliations (TeamAffiliation committer handles ID mapping internally)
        affiliations_total = affiliations_data.size
        affiliations_data.each_with_index do |affiliation_hash, idx|
          team_affiliation_committer.commit(affiliation_hash)
          broadcast_progress('Committing Team Affiliations...', idx + 1, affiliations_total)
        end
        broadcast_progress('Committing Team Affiliations done.', affiliations_total, affiliations_total)
      end
      # -----------------------------------------------------------------------

      # Phase 3: Swimmers, Badges
      # Dependency order: Swimmer → Badge (requires Swimmer + Team + Season + Category)
      def commit_phase3_entities
        Rails.logger.info('[Main] Committing Phase 3: Swimmers & Badges')
        return unless phase3_data

        swimmers_data = Array(phase3_data.dig('data', 'swimmers'))
        badges_data = Array(phase3_data.dig('data', 'badges'))

        # Commit all swimmers first (Swimmer committer handles ID mapping internally)
        total = swimmers_data.size
        swimmers_data.each_with_index do |swimmer_hash, idx|
          swimmer_committer.commit(swimmer_hash)
          broadcast_progress('Committing Swimmers...', idx + 1, total)
        end
        broadcast_progress('Committing Swimmers done.', total, total)

        # Then commit badges (Badge committer handles ID mapping internally)
        badges_total = badges_data.size
        badges_data.each_with_index do |badge_hash, idx|
          badge_committer.commit(badge_hash)
          broadcast_progress('Committing Badges...', idx + 1, badges_total)
        end
        broadcast_progress('Committing Badges done.', badges_total, badges_total)
      end
      # -----------------------------------------------------------------------

      # Phase 4: MeetingEvents
      # MeetingPrograms deferred to Phase 5 (created when committing results)
      def commit_phase4_entities # rubocop:disable Metrics/AbcSize
        Rails.logger.info('[Main] Committing Phase 4: Events')
        return unless phase4_data

        # Phase 4 data is structured as { "data": { "sessions": [ { "session_order": 1, "events": [...] }, ... ] } }
        sessions = Array(phase4_data.dig('data', 'sessions'))
        sessions.each_with_index do |session_hash, sess_idx|
          session_order = session_hash['session_order']
          meeting_session_id = @session_id_by_order[session_order]

          unless meeting_session_id
            Rails.logger.warn("[Main] No meeting_session_id found for session_order=#{session_order}")
            next
          end

          events = Array(session_hash['events'])
          session_total = events.size
          events.each_with_index do |event_hash, evt_idx|
            # Inject the resolved meeting_session_id into the event hash
            event_hash_with_session = event_hash.merge('meeting_session_id' => meeting_session_id)

            # Resolve event_type_id if missing (common for relay events)
            event_hash_with_session['event_type_id'] ||= resolve_event_type_id(event_hash)

            event_id = meeting_event_committer.commit(event_hash_with_session)

            # Store event_id for Phase 5 program creation
            # Use event's internal session_order (should match parent after proper editing)
            if event_id
              event_key = event_hash['key'] # e.g., "50SL", "4x50MI"
              event_session_order = event_hash['session_order'] || session_order
              lookup_key = "#{event_session_order}-#{event_key}"
              @event_id_by_key[lookup_key] = event_id
              Rails.logger.debug { "[Main] Phase4 stored: @event_id_by_key['#{lookup_key}'] = #{event_id}" }
            end

            broadcast_progress("Committing Events for session #{sess_idx + 1}", evt_idx + 1, session_total)
          end
          broadcast_progress("Committing Events for session #{sess_idx + 1} done.", session_total, session_total)
        end
      end
      # -----------------------------------------------------------------------

      # Phase 5: MeetingPrograms, MeetingIndividualResults, Laps, MeetingRelayResults, etc.
      # Iterates over programs from phase5 JSON, then queries data_import_* tables for results
      # Dependency order: MeetingProgram → (MIR → Lap) or (MRR → MRS → RelayLap)
      # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
      def commit_phase5_entities
        Rails.logger.info('[Main] Committing Phase 5: Programs and Results')
        return unless phase5_data

        programs = Array(phase5_data['programs'])
        Rails.logger.info("[Main] Processing #{programs.size} programs from phase5 data")

        programs.each_with_index do |program, prog_idx|
          session_order = program['session_order']
          event_key = program['event_key']     # e.g., "50SL", "S4X50MI"
          event_code = program['event_code']   # Same, for display
          category_code = program['category_code']
          gender_code = program['gender_code']
          is_relay = program['relay'] == true

          # Build program key for querying data_import tables
          program_key = "#{session_order}-#{event_code}-#{category_code}-#{gender_code}"

          # Find meeting_event_id from Phase 4 mapping
          event_lookup_key = "#{session_order}-#{event_key}"
          meeting_event_id = @event_id_by_key[event_lookup_key]

          unless meeting_event_id
            @stats[:errors] << "MeetingProgram error: meeting_event_id not found for #{event_lookup_key}"
            Rails.logger.error("[Main] No meeting_event_id for event_lookup_key=#{event_lookup_key}")
            next # Skip this program but continue with others
          end

          # Create or find MeetingProgram
          program_id = commit_meeting_program(
            meeting_event_id: meeting_event_id,
            category_code: category_code,
            gender_code: gender_code,
            is_relay: is_relay,
            program_key: program_key
          )

          unless program_id
            Rails.logger.error("[Main] Failed to create MeetingProgram for #{program_key}")
            next
          end

          broadcast_progress("Committing Program #{event_code} #{category_code}-#{gender_code}", prog_idx + 1, programs.size)

          if is_relay
            # Commit relay results for this program
            commit_relay_results_for_program(program_key, program_id)
          else
            # Commit individual results for this program
            commit_individual_results_for_program(program_key, program_id)
          end
        end
      end
      # rubocop:enable Metrics/AbcSize
      # -----------------------------------------------------------------------

      # Commit MeetingProgram and return its ID
      # For relays with unknown category/gender, attempts auto-computation from swimmer data.
      def commit_meeting_program(meeting_event_id:, category_code:, gender_code:, is_relay: false, program_key: nil) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        category_type = resolve_category_type(category_code, is_relay: is_relay)
        gender_type = gender_type_instance_from_code(gender_code)

        # For relays with unknown category/gender, try auto-computation from swimmer data
        if is_relay && program_key.present?
          # Auto-compute category if resolution failed (e.g., 'N/A' or unrecognized code)
          if category_type.nil?
            computed_category = compute_relay_category_from_swimmers(program_key)
            if computed_category
              Rails.logger.info("[Main] Auto-computed relay category: #{computed_category.code} (was: #{category_code})")
              category_type = computed_category
            end
          end

          # Auto-compute gender if resolution failed
          if gender_type.nil?
            computed_gender_code = compute_relay_gender_from_swimmers(program_key)
            if computed_gender_code
              Rails.logger.info("[Main] Auto-computed relay gender: #{computed_gender_code} (was: #{gender_code})")
              gender_type = gender_type_instance_from_code(computed_gender_code)
            end
          end
        end

        # rubocop:disable Layout/LineLength
        unless category_type && gender_type
          @stats[:errors] << "MeetingProgram error: category=#{category_code} or gender=#{gender_code} not found (season=#{@season_id}, relay=#{is_relay}, meeting_event_id=#{meeting_event_id})"
          Rails.logger.warn("[Main] MeetingProgram lookup failed: category=#{category_code}, gender=#{gender_code}, season=#{@season_id}, relay=#{is_relay}, meeting_event_id=#{meeting_event_id}")
          return nil
        end
        # rubocop:enable Layout/LineLength

        program_hash = {
          'meeting_event_id' => meeting_event_id,
          'category_type_id' => category_type.id,
          'gender_type_id' => gender_type.id,
          'event_order' => 0
        }

        meeting_program_committer.commit(program_hash)
      end
      # -----------------------------------------------------------------------

      # Resolve CategoryType from code, handling relay categories specially.
      # Relay categories in source data use simplified codes like "M100", "M120",
      # but DB stores them as age ranges like "100-119", "120-159".
      # For relays, we extract the age from the code and use find_category_for_age.
      def resolve_category_type(category_code, is_relay: false) # rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        return nil if category_code.blank?

        if is_relay
          # For relays: extract age from code (e.g., "M100" → 100) and find by age range
          age = extract_relay_age_from_code(category_code)
          if age && @categories_cache
            _category_code, category_type = @categories_cache.find_category_for_age(age, relay: true)
            return category_type
          end

          # Fallback: try direct DB lookup with age-range pattern
          if age
            category = GogglesDb::CategoryType.where(season_id: @season_id, relay: true)
                                              .where('age_begin <= ? AND age_end >= ?', age, age)
                                              .first
            return category if category
          end
        else
          # For individual categories: direct code lookup
          category_type = @categories_cache&.[](category_code)
          return category_type if category_type

          # Fallback to DB query
          return GogglesDb::CategoryType.find_by(code: category_code, season_id: @season_id)
        end

        nil
      end
      # -----------------------------------------------------------------------

      # Extract age from relay category code (e.g., "M100" → 100, "M80" → 80)
      def extract_relay_age_from_code(category_code)
        return nil if category_code.blank?

        # Match codes like "M100", "M80", "M120", etc.
        match = category_code.match(/^M?(\d+)$/i)
        match ? match[1].to_i : nil
      end
      # -----------------------------------------------------------------------

      # Commit individual results (MIR + Laps) for a given program
      def commit_individual_results_for_program(program_key, program_id) # rubocop:disable Metrics/AbcSize
        # Retrieve MIRs bound to the program's key
        mirs = GogglesDb::DataImportMeetingIndividualResult.where(meeting_program_key: program_key)
                                                           .includes(:data_import_laps)
                                                           .order(:import_key)
        mirs.each do |data_import_mir|
          # Resolve all bindings:
          data_import_mir.meeting_program_id ||= program_id
          data_import_mir.swimmer_id ||= swimmer_committer.resolve_id(data_import_mir.swimmer_key)
          data_import_mir.team_id ||= team_committer.resolve_id(data_import_mir.team_key)
          data_import_mir.badge_id ||= badge_committer.resolve_id(data_import_mir.swimmer_key, data_import_mir.team_key)

          # Pass resolved IDs explicitly to committer
          mir_id = mir_committer.commit(data_import_mir, season_id: @season_id)
          data_import_mir.meeting_individual_result_id = mir_id

          # Retrieve laps bound to the parent MIR
          data_import_laps = GogglesDb::DataImportLap.where(parent_import_key: data_import_mir.import_key)
                                                     .order(:import_key)
          # Commit laps
          data_import_laps.each do |data_import_lap|
            lap_committer.commit(data_import_lap, data_import_mir:)
          end
        end
      end
      # -----------------------------------------------------------------------

      # Commit relay results (MRR + MRS + RelayLaps) for a given program
      def commit_relay_results_for_program(program_key, program_id) # rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
        # Retrieve MRRs bound to the program's key
        mrrs = GogglesDb::DataImportMeetingRelayResult.where(meeting_program_key: program_key)
                                                      .includes(data_import_meeting_relay_swimmers: :data_import_relay_laps)
                                                      .order(:import_key)
        mrrs.each do |data_import_mrr|
          # Resolve all bindings:
          data_import_mrr.team_id ||= team_committer.resolve_id(data_import_mrr.team_key)
          data_import_mrr.team_affiliation_id ||= team_affiliation_committer.resolve_id(data_import_mrr.team_key)

          # Pass resolved IDs explicitly to committer
          mrr_id = mrr_committer.commit(data_import_mrr, program_id: program_id, season_id: @season_id)

          # Commit relay swimmers and their laps
          data_import_mrr.data_import_meeting_relay_swimmers.each do |data_import_mrs|
            # Resolve all bindings:
            data_import_mrs.meeting_relay_result_id ||= mrr_id
            data_import_mrs.swimmer_id ||= swimmer_committer.resolve_id(data_import_mrs.swimmer_key)
            # NOTE: team_id comes from parent MRR for relays
            data_import_mrs.badge_id ||= badge_committer.resolve_id(data_import_mrs.swimmer_key, data_import_mrr.team_key)

            # Fail fast if commit fails:
            mrs_id = mrs_committer.commit(data_import_mrs)

            data_import_mrs.data_import_relay_laps.each do |data_import_relay_lap|
              relay_lap_committer.commit(
                data_import_relay_lap,
                mrs_id: mrs_id,
                mrr_id: mrr_id,
                swimmer_id: data_import_mrs.swimmer_id,
                team_id: data_import_mrr.team_id,
                mrs_length: data_import_mrs.length_in_meters
              )
            end
          end
        end
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Phase 1 Commit Methods
      # =========================================================================

      def meeting_committer
        @meeting_committer ||= Import::Committers::Meeting.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def calendar_committer
        @calendar_committer ||= Import::Committers::Calendar.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def city_committer
        @city_committer ||= Import::Committers::City.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def swimming_pool_committer
        @swimming_pool_committer ||= Import::Committers::SwimmingPool.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def meeting_session_committer
        @meeting_session_committer ||= Import::Committers::MeetingSession.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def team_committer
        @team_committer ||= Import::Committers::Team.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def swimmer_committer
        @swimmer_committer ||= Import::Committers::Swimmer.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def team_affiliation_committer
        @team_affiliation_committer ||= Import::Committers::TeamAffiliation.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log,
          team_committer: team_committer,
          season_id: @season_id
        )
      end
      # -----------------------------------------------------------------------

      def badge_committer
        @badge_committer ||= Import::Committers::Badge.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log,
          swimmer_committer: swimmer_committer,
          team_committer: team_committer,
          team_affiliation_committer: team_affiliation_committer,
          categories_cache: @categories_cache,
          season_id: @season_id,
          meeting: @meeting
        )
      end
      # -----------------------------------------------------------------------

      def meeting_event_committer
        @meeting_event_committer ||= Import::Committers::MeetingEvent.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def meeting_program_committer
        @meeting_program_committer ||= Import::Committers::MeetingProgram.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def mir_committer
        @mir_committer ||= Import::Committers::MeetingIndividualResult.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def lap_committer
        @lap_committer ||= Import::Committers::Lap.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def mrr_committer
        @mrr_committer ||= Import::Committers::MeetingRelayResult.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def mrs_committer
        @mrs_committer ||= Import::Committers::MeetingRelaySwimmer.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      def relay_lap_committer
        @relay_lap_committer ||= Import::Committers::RelayLap.new(
          stats: @stats,
          logger: @logger,
          sql_log: @sql_log
        )
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Helper Methods
      # =========================================================================

      # Resolve event_type_id from event hash attributes (fallback for relay events)
      # Uses key, distance, stroke to find the correct EventType
      def resolve_event_type_id(event_hash)
        # First try using the 'key' field (most reliable for relays)
        # Key format: "4x50MI", "50SL", "100DO", etc.
        event_key = event_hash['key']
        if event_key.present?
          # Normalize: 4x50MI -> 4X50MI
          normalized_key = event_key.to_s.gsub(/(\d)x(\d)/i, '\1X\2').upcase
          event_type = GogglesDb::EventType.find_by(code: normalized_key)
          return event_type.id if event_type
        end

        # Fallback: build from distance + stroke
        distance = event_hash['distance']
        stroke = event_hash['stroke']

        return nil unless distance.to_i.positive? && stroke.present?

        event_code = "#{distance}#{stroke}".upcase
        event_type = GogglesDb::EventType.find_by(code: event_code)
        return event_type.id if event_type

        Rails.logger.warn("[Main] Could not resolve event_type_id for event: #{event_hash.inspect}")
        nil
      end
      # -----------------------------------------------------------------------

      # Find meeting_session_id from phase 1 data by session key/order
      def find_meeting_session_id_by_key(session_key)
        return nil unless phase1_data && session_key

        sessions = Array(phase1_data.dig('data', 'sessions'))
        session = sessions.find { |s| s['key'] == session_key || s['session_order'].to_s == session_key.to_s }
        session&.dig('meeting_session_id')
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Phase 5 Commit Methods (legacy helper, kept for reference)
      # =========================================================================

      # Find meeting_event_id from import_key using the mappings populated during Phase 4 commit
      def find_meeting_event_id_from_import_key(import_key)
        # Extract program key: "1-100SL-M45-M" from "1-100SL-M45-M/ROSSI|MARIO|1978"
        # Or for relays: "1-4x50MI-M120-X/TEAM NAME-1'23.45"
        program_key = import_key.split('/').first
        key_parts = program_key.split('-')

        session_order = key_parts[0].to_i # "1" -> 1
        event_code = key_parts[1]         # "100SL" or "4x50MI"

        # Use the mapping populated during Phase 4 commit
        event_key = "#{session_order}-#{event_code}"
        meeting_event_id = @event_id_by_key[event_key]

        Rails.logger.warn("[Main] No meeting_event_id found for event_key=#{event_key} (import_key=#{import_key})") unless meeting_event_id

        meeting_event_id
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Helper Methods
      # =========================================================================

      # Build normalized meeting attributes matching DB schema
      def normalize_meeting_attributes(raw_meeting)
        meeting_hash = raw_meeting.deep_dup

        meeting_hash['description'] = meeting_hash['name']
        meeting_hash['autofilled'] = true if meeting_hash['autofilled'].nil?
        meeting_hash['allows_under25'] = meeting_hash.fetch('allows_under25', true)
        meeting_hash['cancelled'] = meeting_hash.fetch('cancelled', false)
        meeting_hash['confirmed'] = meeting_hash.fetch('confirmed', false)
        meeting_hash['max_individual_events'] ||= GogglesDb::Meeting.columns_hash['max_individual_events'].default
        meeting_hash['max_individual_events_per_session'] ||= GogglesDb::Meeting.columns_hash['max_individual_events_per_session'].default
        meeting_hash['notes'] = build_meeting_notes(meeting_hash)
        meeting_hash['notes']

        meeting_hash['header_date'] = "#{meeting_hash['header_date']}-#{meeting_hash['header_date']}-#{meeting_hash['header_date']}"
      end
      # -----------------------------------------------------------------------

      def build_meeting_notes(meeting_hash)
        meeting_url = meeting_hash['meetingURL'] || meeting_hash['meeting_url']
        return meeting_hash['notes'] if meeting_url.blank?

        note_line = "meetingURL: #{meeting_url}"
        existing_notes = meeting_hash['notes']
        return note_line if existing_notes.blank?

        notes = existing_notes.split("\n")
        notes.prepend(note_line) unless notes.include?(note_line)
        notes.join("\n")
      end
      # -----------------------------------------------------------------------

      def normalize_session_attributes(session_hash, meeting_id, index: 0)
        normalized = session_hash.deep_dup
        normalized['meeting_id'] ||= meeting_id
        normalized['session_order'] ||= index + 1
        normalized['autofilled'] = normalized.fetch('autofilled', true)
        normalized['description'] ||= "Session #{normalized['session_order']}"
        normalized
      end
      # -----------------------------------------------------------------------

      def normalize_swimming_pool_attributes(pool_hash, city_id:)
        normalized = pool_hash.deep_dup.with_indifferent_access
        normalized['city_id'] ||= city_id if city_id

        pool_type_code = normalized.delete('pool_type_code')
        normalized['pool_type_id'] = GogglesDb::PoolType.find_by(code: pool_type_code)&.id if normalized['pool_type_id'].blank? && pool_type_code.present?

        %w[multiple_pools garden bar restaurant gym child_area read_only].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        sanitize_attributes(normalized, GogglesDb::SwimmingPool)
      end
      # -----------------------------------------------------------------------

      def normalize_meeting_event_attributes(event_hash, meeting_session_id:, event_type_id:)
        normalized = event_hash.deep_dup.with_indifferent_access
        normalized['meeting_session_id'] = meeting_session_id
        normalized['event_type_id'] ||= event_type_id

        heat_type_code = normalized.delete('heat_type') || normalized.delete(:heat_type)
        normalized['heat_type_id'] = GogglesDb::HeatType.find_by(code: heat_type_code)&.id if normalized['heat_type_id'].blank? && heat_type_code.present?

        %w[out_of_race autofilled split_gender_start_list split_category_start_list].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        normalized['event_order'] ||= normalized['event_order'] || 0

        sanitize_attributes(normalized, GogglesDb::MeetingEvent)
      end
      # -----------------------------------------------------------------------

      def normalize_meeting_program_attributes(program_hash, meeting_event_id:, category_type_id:, gender_type_id:)
        normalized = program_hash.deep_dup.with_indifferent_access
        normalized['meeting_event_id'] ||= meeting_event_id
        normalized['category_type_id'] ||= category_type_id
        normalized['gender_type_id'] ||= gender_type_id

        %w[out_of_race autofilled].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        sanitize_attributes(normalized, GogglesDb::MeetingProgram)
      end
      # -----------------------------------------------------------------------

      def integer_or_nil(value)
        return nil if value.nil? || (value.respond_to?(:blank?) && value.blank?)

        value.to_i
      end
      # -----------------------------------------------------------------------

      def decimal_or_nil(value)
        return nil if value.nil? || (value.respond_to?(:blank?) && value.blank?)

        return value if value.is_a?(BigDecimal)

        BigDecimal(value.to_s)
      rescue ArgumentError
        nil
      end
      # -----------------------------------------------------------------------

      # Returns the prefixed gender_types.id value for the specified code.
      # @see app/models/goggles_db/gender_type.rb
      def gender_type_id_from_code(gender_code)
        case gender_code
        when 'M'
          GogglesDb::GenderType::MALE_ID
        when 'F'
          GogglesDb::GenderType::FEMALE_ID
        when 'X'
          GogglesDb::GenderType::INTERMIXED_ID
        end
      end

      # Returns the cached gender_types row instance for the specified code.
      # @see app/models/goggles_db/gender_type.rb
      def gender_type_instance_from_code(gender_code)
        case gender_code
        when 'M'
          GogglesDb::GenderType.male
        when 'F'
          GogglesDb::GenderType.female
        when 'X'
          GogglesDb::GenderType.intermixed
        end
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Relay Category/Gender Auto-Computation
      # =========================================================================

      # (Post-)Computes relay category from swimmer ages when category_code is unknown ('N/A' or nil).
      # Queries data_import_meeting_relay_swimmers for the program's relay results,
      # extracts YOBs from swimmer_keys, sums ages, and finds matching relay category.
      #
      # Note that data_import_* tables won't be updated with the new correct key, code and ID:
      # only the SQL script will contain the proper values.
      #
      # == Params:
      # - program_key: program key pattern (e.g., "1-M4X50SL-N/A-X")
      #
      # == Returns:
      # GogglesDb::CategoryType instance or nil if computation fails
      #
      def compute_relay_category_from_swimmers(program_key)
        return nil unless @meeting && @categories_cache

        # Query MRRs for this program pattern (may have 'N/A' or other unknown category)
        mrrs = GogglesDb::DataImportMeetingRelayResult.where('meeting_program_key LIKE ?', "#{program_key.split('-')[0..1].join('-')}-%")
        return nil if mrrs.empty?

        meeting_year = @meeting.header_date&.year || Date.current.year

        # Collect all swimmer ages from all MRS records
        swimmer_ages = []
        mrrs.each do |mrr|
          mrr.data_import_meeting_relay_swimmers.order(:relay_order).each do |mrs|
            yob = extract_yob_from_swimmer_key(mrs.swimmer_key)
            next unless yob&.positive?

            age = meeting_year - yob
            swimmer_ages << age
          end
        end

        return nil if swimmer_ages.empty?

        # For relay category, sum ages of first complete relay team (4 swimmers)
        # If we have multiple relays, use the first one as reference
        relay_size = 4 # Standard relay team size
        return nil if swimmer_ages.size < relay_size

        overall_age = swimmer_ages.first(relay_size).sum
        Rails.logger.info("[Main] Computed relay overall_age=#{overall_age} from #{relay_size} swimmers")

        # Find matching relay category by age
        _code, category_type = @categories_cache.find_category_for_age(overall_age, relay: true)
        category_type
      end
      # -----------------------------------------------------------------------

      # (Post-)Computes relay gender from swimmer genders when gender_code is unknown.
      # Queries data_import_meeting_relay_swimmers for the program's relay results,
      # extracts gender codes from swimmer_keys or phase3 data.
      #
      # Note that data_import_* tables won't be updated with the new correct key, code and ID:
      # only the SQL script will contain the proper values.
      #
      # == Params:
      # - program_key: program key pattern (e.g., "1-4X50SL-M120-X")
      #
      # == Returns:
      # 'M', 'F', or 'X' based on swimmer composition, or nil if computation fails
      #
      def compute_relay_gender_from_swimmers(program_key)
        # Query MRRs for this program pattern
        mrrs = GogglesDb::DataImportMeetingRelayResult.where('meeting_program_key LIKE ?', "#{program_key.split('-')[0..1].join('-')}-%")
        return nil if mrrs.empty?

        # Collect all swimmer genders from MRS records
        gender_codes = []
        mrrs.each do |mrr|
          mrr.data_import_meeting_relay_swimmers.each do |mrs|
            gender = extract_gender_from_swimmer_key(mrs.swimmer_key)
            gender ||= lookup_swimmer_gender_from_phase3(mrs.swimmer_key)
            gender_codes << gender if gender.present?
          end
        end

        return nil if gender_codes.empty?

        unique_genders = gender_codes.compact.uniq
        return 'F' if unique_genders == ['F']
        return 'M' if unique_genders == ['M']

        'X' # Mixed or indeterminate
      end
      # -----------------------------------------------------------------------

      # Extracts year of birth from swimmer_key.
      # Handles any composition of tokens for the key ("LAST|FIRST|YEAR" or "GENDER|LAST|FIRST|YEAR"),
      # as long as the last token field in the key is the year of birth (YoB).
      #
      # == Returns:
      # Integer year of birth or nil
      #
      def extract_yob_from_swimmer_key(swimmer_key)
        return nil if swimmer_key.blank?

        tokens = swimmer_key.split('|')
        return nil if tokens.size < 3

        yob = tokens.last.to_i
        yob.positive? && yob > 1900 && yob < 2100 ? yob : nil
      end
      # -----------------------------------------------------------------------

      # Extracts gender code from swimmer_key if present in a 4+ token format.
      # Assumes the gender code is the first token only if there are at least 4 tokens.
      # ("GENDER|LAST|FIRST|YEAR")
      #
      # == Returns:
      # 'M' or 'F' if found, nil otherwise
      #
      def extract_gender_from_swimmer_key(swimmer_key)
        return nil if swimmer_key.blank?

        tokens = swimmer_key.split('|')
        return nil unless tokens.size >= 4

        gender_code = tokens[0].to_s.strip.upcase
        %w[M F].include?(gender_code) ? gender_code : nil
      end
      # -----------------------------------------------------------------------

      # Looks up swimmer gender from phase3 data using swimmer_key.
      # Handles partial key matching (ignoring gender prefix).
      #
      # == Returns:
      # 'M' or 'F' if found, nil otherwise
      #
      def lookup_swimmer_gender_from_phase3(swimmer_key)
        return nil unless phase3_data && swimmer_key.present?

        swimmers = phase3_data.dig('data', 'swimmers') || []

        # Try exact match first
        swimmer = swimmers.find { |s| s['key'] == swimmer_key }
        return normalize_gender_code(swimmer['gender_type_code']) if swimmer&.dig('gender_type_code')

        # Build partial key for matching (|LAST|FIRST|YOB or LAST|FIRST|YOB)
        partial_key = normalize_to_partial_key(swimmer_key)
        return nil if partial_key.blank?

        # Find swimmers with matching partial key
        matching = swimmers.select do |s|
          s_partial = normalize_to_partial_key(s['key'])
          s_partial == partial_key
        end

        matching.find { |s| s['gender_type_code'].present? }&.dig('gender_type_code')&.then { |g| normalize_gender_code(g) }
      end
      # -----------------------------------------------------------------------

      # Normalizes swimmer_key to partial key format (|LAST|FIRST|YOB) for matching.
      # Strips gender prefix if present.
      # Swimmer keys are either 3-token (LAST|FIRST|YEAR) or 4-token (GENDER|LAST|FIRST|YEAR).
      # Team is never included in swimmer keys (stored as separate field in phase3 data).
      #
      def normalize_to_partial_key(swimmer_key)
        return nil if swimmer_key.blank?

        tokens = swimmer_key.split('|')
        if tokens.size >= 4
          # 4-token: "GENDER|LAST|FIRST|YEAR" -> "|LAST|FIRST|YEAR"
          "|#{tokens[1]}|#{tokens[2]}|#{tokens[3]}"
        elsif tokens.size == 3
          # 3-token: "LAST|FIRST|YEAR" -> "|LAST|FIRST|YEAR"
          "|#{tokens[0]}|#{tokens[1]}|#{tokens[2]}"
        end
      end
      # -----------------------------------------------------------------------

      # Normalizes gender code to M/F
      def normalize_gender_code(gender_code)
        return nil if gender_code.blank?

        code = gender_code.to_s.strip.upcase
        return 'M' if code.start_with?('M')
        return 'F' if code.start_with?('F')

        nil
      end
      # -----------------------------------------------------------------------

      # Broadcasts progress updates via ActionCable for real-time UI feedback
      def broadcast_progress(message, current, total)
        ActionCable.server.broadcast(
          'ImportStatusChannel',
          { msg: message, progress: current, total: total }
        )
      rescue StandardError => e
        Rails.logger.warn("[Main] Failed to broadcast progress: #{e.message}")
      end
      # -----------------------------------------------------------------------

      # Check if any attributes have changed (for UPDATE detection)
      def attributes_changed?(model, new_attributes)
        new_attributes.except('id', :id).any? do |key, value|
          model_value = begin
            model.send(key.to_sym)
          rescue StandardError
            nil
          end
          model_value != value
        end
      end
      # -----------------------------------------------------------------------

      # Remove attributes not in the model's column list
      def sanitize_attributes(attributes, model_class)
        column_names = model_class.column_names.map(&:to_s)
        attributes.slice(*column_names).except('id').stringify_keys
      end
      # -----------------------------------------------------------------------
    end
  end
end
