# frozen_string_literal: true

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

      attr_reader :phase1_path, :phase2_path, :phase3_path, :phase4_path, :source_path,
                  :phase1_data, :phase2_data, :phase3_data, :phase4_data,
                  :sql_log, :stats, :logger

      def initialize(phase1_path:, phase2_path:, phase3_path:, phase4_path:, source_path:, log_path: nil)
        @phase1_path = phase1_path
        @phase2_path = phase2_path
        @phase3_path = phase3_path
        @phase4_path = phase4_path
        @source_path = source_path
        @sql_log = []
        @stats = {
          cities_created: 0, cities_updated: 0,
          pools_created: 0, pools_updated: 0,
          meetings_created: 0, meetings_updated: 0,
          calendars_created: 0, calendars_updated: 0,
          sessions_created: 0, sessions_updated: 0,
          teams_created: 0, teams_updated: 0,
          affiliations_created: 0,
          swimmers_created: 0, swimmers_updated: 0,
          badges_created: 0,
          events_created: 0, events_updated: 0,
          programs_created: 0, programs_updated: 0,
          mirs_created: 0, mirs_updated: 0,
          laps_created: 0, laps_updated: 0,
          errors: []
        }
        # Initialize logger
        @log_path = log_path || source_path.to_s.gsub('.json', '.log')
        @logger = Import::PhaseCommitLogger.new(log_path: @log_path)
      end
      # -----------------------------------------------------------------------

      # Main entry point: commits all entities in dependency order within a transaction
      def commit_all
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
        end

        # Close SQL transaction
        @sql_log << "\r\n--\r\n"
        @sql_log << 'COMMIT;'

        # Write log file
        broadcast_progress('Writing log file', 6, 6)
        @logger.write_log_file(stats: @stats)

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
      def load_phase_files!
        @phase1_data = JSON.parse(File.read(phase1_path)) if File.exist?(phase1_path)
        @phase2_data = JSON.parse(File.read(phase2_path)) if File.exist?(phase2_path)
        @phase3_data = JSON.parse(File.read(phase3_path)) if File.exist?(phase3_path)
        @phase4_data = JSON.parse(File.read(phase4_path)) if File.exist?(phase4_path)

        Rails.logger.info('[Main] Loaded phase files')
      end
      # -----------------------------------------------------------------------

      # Phase 1: Cities, SwimmingPools, Meetings, MeetingSessions
      # Dependency order: City → SwimmingPool → Meeting → MeetingSession
      def commit_phase1_entities
        Rails.logger.info('[Main] Committing Phase 1: Meeting & Sessions')
        return unless phase1_data

        # Meeting data is directly under 'data', not 'data.meeting'
        meeting_data = normalize_meeting_attributes(phase1_data['data'] || {})
        sessions_data = Array(meeting_data.delete('meeting_session')).map.with_index do |session_hash, index|
          normalize_session_attributes(session_hash, meeting_data['id'], index: index)
        end

        # Commit meeting (returns resulting meeting_id)
        meeting_id = commit_meeting(meeting_data)
        return unless meeting_id

        commit_calendar(meeting_data.merge('meeting_id' => meeting_id))

        # Update sessions with the resulting meeting_id so they can be persisted
        sessions_data.each { |session_hash| session_hash['meeting_id'] = meeting_id }

        # Commit sessions (mutates hashes with resulting IDs)
        sessions_data.each { |session_hash| commit_meeting_session(session_hash) }
      end
      # -----------------------------------------------------------------------

      # Phase 2: Teams, TeamAffiliations
      # Dependency order: Team → TeamAffiliation
      def commit_phase2_entities
        Rails.logger.info('[Main] Committing Phase 2: Teams & Affiliations')
        return unless phase2_data

        teams_data = Array(phase2_data.dig('data', 'teams'))
        affiliations_data = Array(phase2_data.dig('data', 'team_affiliations'))

        # Commit all teams first
        teams_data.each { |team_hash| commit_team(team_hash) }

        # Then commit affiliations (affiliations now have pre-matched team_affiliation_id from Phase 2)
        affiliations_data.each { |affiliation_hash| commit_team_affiliation(affiliation_hash: affiliation_hash) }
      end
      # -----------------------------------------------------------------------

      # Phase 3: Swimmers, Badges
      # Dependency order: Swimmer → Badge (requires Swimmer + Team + Season + Category)
      def commit_phase3_entities
        Rails.logger.info('[Main] Committing Phase 3: Swimmers & Badges')
        return unless phase3_data

        swimmers_data = Array(phase3_data.dig('data', 'swimmers'))
        badges_data = Array(phase3_data.dig('data', 'badges'))

        # Commit all swimmers first
        swimmers_data.each { |swimmer_hash| commit_swimmer(swimmer_hash) }

        # Then commit badges (badges now have pre-calculated category_type_id from Phase 3)
        badges_data.each { |badge_hash| commit_badge(badge_hash: badge_hash) }
      end
      # -----------------------------------------------------------------------

      # Phase 4: MeetingEvents
      # MeetingPrograms deferred to Phase 5 (created when committing results)
      def commit_phase4_entities
        Rails.logger.info('[Main] Committing Phase 4: Events')
        return unless phase4_data

        # Phase 4 data is structured as { "sessions": [ { "session_order": 1, "events": [...] }, ... ] }
        sessions = Array(phase4_data['sessions'])
        sessions.each do |session_hash|
          events = Array(session_hash['events'])
          events.each { |event_hash| commit_meeting_event(event_hash) }
        end
      end
      # -----------------------------------------------------------------------

      # Phase 5: MeetingPrograms, MeetingIndividualResults, Laps
      # Reads from data_import_* tables (not JSON)
      # Dependency order: MeetingProgram → MIR → Lap
      def commit_phase5_entities
        Rails.logger.info('[Main] Committing Phase 5: Results from DB tables')

        # Query all results for this source file
        all_mirs = GogglesDb::DataImportMeetingIndividualResult
                   .where(phase_file_path: source_path)
                   .includes(:data_import_laps)
                   .order(:import_key)

        all_mirs.each do |data_import_mir|
          # Ensure MeetingProgram exists (may need to create it)
          program_id = ensure_meeting_program(data_import_mir)
          next unless program_id

          # Commit MIR (INSERT or UPDATE)
          mir_id = commit_meeting_individual_result(data_import_mir, program_id)
          next unless mir_id

          # Commit laps
          data_import_mir.data_import_laps.each do |data_import_lap|
            commit_lap(data_import_lap, mir_id)
          end
        end
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Phase 1 Commit Methods
      # =========================================================================

      def commit_meeting(meeting_hash)
        meeting_id = meeting_hash['meeting_id']

        # If meeting already has a DB ID, it's matched - update if needed
        if meeting_id.present? && meeting_id.positive?
          meeting = GogglesDb::Meeting.find_by(id: meeting_id)
          if meeting && attributes_changed?(meeting, meeting_hash)
            meeting.update!(sanitize_attributes(meeting_hash, GogglesDb::Meeting))
            @sql_log << SqlMaker.new(row: meeting).log_update
            @stats[:meetings_updated] += 1
            Rails.logger.info("[Main] Updated Meeting ID=#{meeting_id}")
          end
          return meeting_id
        end

        normalized_attributes = sanitize_attributes(meeting_hash, GogglesDb::Meeting)
        new_meeting = GogglesDb::Meeting.create!(normalized_attributes)
        @sql_log << SqlMaker.new(row: new_meeting).log_insert
        @stats[:meetings_created] += 1
        @logger.log_success(entity_type: 'Meeting', entity_id: new_meeting.id, action: 'created')
        Rails.logger.info("[Main] Created Meeting ID=#{new_meeting.id}, #{new_meeting.description}")
        new_meeting.id
      rescue ActiveRecord::RecordInvalid => e
        error_msg = "Meeting creation failed: #{e.message}"
        @stats[:errors] << error_msg
        @logger.log_validation_error(
          entity_type: 'Meeting',
          entity_key: meeting_hash['name'],
          model_row: GogglesDb::Meeting.new(attributes),
          error: e
        )
        Rails.logger.error("[Main] ERROR committing meeting: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      def commit_meeting_session(session_hash)
        session_id = session_hash['meeting_session_id'] || session_hash['id']
        meeting_id = session_hash['meeting_id']

        return unless meeting_id

        # Commit nested city first (if new)
        city_id = commit_city(session_hash.dig('swimming_pool', 'city'))

        # Commit nested swimming pool (may reference city)
        pool_hash = session_hash['swimming_pool']
        swimming_pool_id = if pool_hash
                             pool_hash['city_id'] ||= city_id if city_id
                             commit_swimming_pool(pool_hash)
                           end

        normalized_session = sanitize_attributes(session_hash.merge('swimming_pool_id' => swimming_pool_id), GogglesDb::MeetingSession)

        # If session already has a DB ID, update if needed
        if session_id.present? && session_id.positive?
          session = GogglesDb::MeetingSession.find_by(id: session_id)
          if session && attributes_changed?(session, normalized_session)
            session.update!(normalized_session)
            @sql_log << SqlMaker.new(row: session).log_update
            @stats[:sessions_updated] += 1
            Rails.logger.info("[Main] Updated MeetingSession ID=#{session_id}")
          end
          return session_id
        end

        new_session = GogglesDb::MeetingSession.create!(normalized_session)
        @sql_log << SqlMaker.new(row: new_session).log_insert
        @stats[:sessions_created] += 1
        Rails.logger.info("[Main] Created MeetingSession ID=#{new_session.id}, order=#{new_session.session_order}")
        new_session.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "MeetingSession error: #{e.message}"
        Rails.logger.error("[Main] ERROR committing session: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      # Commit a City entity (nested within swimming pool data)
      def commit_city(city_hash)
        return nil unless city_hash

        city_id = city_hash['city_id'] || city_hash['id']

        # If city already exists, return its ID
        return city_id if city_id.present? && city_id.positive?

        # Create new city
        normalized_city = sanitize_attributes(city_hash, GogglesDb::City)

        new_city = GogglesDb::City.create!(normalized_city)
        @sql_log << SqlMaker.new(row: new_city).log_insert
        @stats[:cities_created] += 1
        Rails.logger.info("[Main] Created City ID=#{new_city.id}, #{new_city.name}")
        new_city.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "City error: #{e.message}"
        Rails.logger.error("[Main] ERROR committing city: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      # Commit a SwimmingPool entity (nested within session data)
      def commit_swimming_pool(pool_hash)
        return nil unless pool_hash

        pool_id = pool_hash['swimming_pool_id'] || pool_hash['id']

        # If pool already exists, return its ID
        return pool_id if pool_id.present? && pool_id.positive?

        # Create new swimming pool

        # Retrieve PoolType only if not already set by ID:
        pool_type = GogglesDb::PoolType.find_by(code: pool_hash['pool_type_code']) if pool_hash['pool_type_code'].present? && pool_hash['pool_type_id'].blank?
        normalized_pool = sanitize_attributes(pool_hash.merge('pool_type_id' => pool_hash['pool_type_id'] || pool_type&.id), GogglesDb::SwimmingPool)

        new_pool = GogglesDb::SwimmingPool.create!(normalized_pool)
        @sql_log << SqlMaker.new(row: new_pool).log_insert
        @stats[:pools_created] += 1
        Rails.logger.info("[Main] Created SwimmingPool ID=#{new_pool.id}, #{new_pool.name}")
        new_pool.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "SwimmingPool error: #{e.message}"
        Rails.logger.error("[Main] ERROR committing pool: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Phase 2 Commit Methods
      # =========================================================================

      def commit_team(team_hash)
        team_id = team_hash['team_id']
        normalized_attributes = normalize_team_attributes(team_hash)

        # If team already has a DB ID, it's matched - just verify or update if needed
        if team_id.present? && team_id.positive?
          team = GogglesDb::Team.find_by(id: team_id)
          if team && attributes_changed?(team, normalized_attributes)
            # Update existing team if attributes changed
            team.update!(normalized_attributes)
            @sql_log << SqlMaker.new(row: team).log_update
            @stats[:teams_updated] += 1
            Rails.logger.info("[Main] Updated Team ID=#{team_id}")
          end
          return team_id
        end

        # Create new team (team_id is nil or 0)
        new_team = GogglesDb::Team.create!(normalized_attributes)
        @sql_log << SqlMaker.new(row: new_team).log_insert
        @stats[:teams_created] += 1
        Rails.logger.info("[Main] Created Team ID=#{new_team.id}, name=#{new_team.name}")
        new_team.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "Team error (#{team_hash['key']}): #{e.message}"
        Rails.logger.error("[Main] ERROR committing team: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      def commit_team_affiliation(affiliation_hash:)
        # Affiliation data comes from phase2 with pre-matched team_affiliation_id
        team_affiliation_id = affiliation_hash['team_affiliation_id'] || affiliation_hash[:team_affiliation_id]
        team_id = affiliation_hash['team_id'] || affiliation_hash[:team_id]
        season_id = affiliation_hash['season_id'] || affiliation_hash[:season_id]

        # Guard clause: skip if missing required keys
        return unless team_id && season_id

        # If team_affiliation_id exists, it's already in DB - skip
        if team_affiliation_id.present?
          Rails.logger.debug { "[Main] TeamAffiliation ID=#{team_affiliation_id} already exists, skipping" }
          return
        end

        # Create new affiliation (minimal data - just links team to season)
        team = GogglesDb::Team.find_by(id: team_id)
        attributes = normalize_team_affiliation_attributes(
          affiliation_hash,
          team_id: team_id,
          season_id: season_id,
          team: team
        )

        affiliation = GogglesDb::TeamAffiliation.create!(attributes)
        @sql_log << SqlMaker.new(row: affiliation).log_insert
        @stats[:affiliations_created] += 1
        Rails.logger.info("[Main] Created TeamAffiliation ID=#{affiliation.id}, team_id=#{team_id}, season_id=#{season_id}")
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "TeamAffiliation error (team_id=#{team_id}): #{e.message}"
        Rails.logger.error("[Main] ERROR creating affiliation: #{e.message}")
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Phase 3 Commit Methods
      # =========================================================================

      def commit_swimmer(swimmer_hash)
        swimmer_id = swimmer_hash['swimmer_id']
        normalized_attributes = normalize_swimmer_attributes(swimmer_hash)

        # If swimmer already has a DB ID, it's matched - just verify or update if needed
        if swimmer_id.present? && swimmer_id.positive?
          swimmer = GogglesDb::Swimmer.find_by(id: swimmer_id)
          if swimmer && attributes_changed?(swimmer, normalized_attributes)
            # Update existing swimmer if attributes changed
            swimmer.update!(normalized_attributes)
            @sql_log << SqlMaker.new(row: swimmer).log_update
            @stats[:swimmers_updated] += 1
            Rails.logger.info("[Main] Updated Swimmer ID=#{swimmer_id}")
          end
          return swimmer_id
        end

        # Create new swimmer (swimmer_id is nil or 0)
        new_swimmer = GogglesDb::Swimmer.create!(normalized_attributes)
        @sql_log << SqlMaker.new(row: new_swimmer).log_insert
        @stats[:swimmers_created] += 1
        Rails.logger.info("[Main] Created Swimmer ID=#{new_swimmer.id}, name=#{new_swimmer.complete_name}")
        new_swimmer.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "Swimmer error (#{swimmer_hash['key']}): #{e.message}"
        Rails.logger.error("[Main] ERROR committing swimmer: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      def commit_badge(badge_hash:)
        # Badge data comes from phase3 with pre-calculated category_type_id and pre-matched badge_id
        badge_id = badge_hash['badge_id']
        swimmer_id = badge_hash['swimmer_id']
        team_id = badge_hash['team_id']
        season_id = badge_hash['season_id']
        category_type_id = badge_hash['category_type_id']

        # Guard clause: skip if missing required keys
        return unless swimmer_id && team_id && season_id

        # If badge_id exists, it's already in DB - skip
        if badge_id.present?
          Rails.logger.debug { "[Main] Badge ID=#{badge_id} already exists, skipping" }
          return
        end

        # Find the team_affiliation (should have been created in Phase 2)
        team_affiliation = GogglesDb::TeamAffiliation.find_by(team_id: team_id, season_id: season_id)
        unless team_affiliation
          @stats[:errors] << "Badge error: TeamAffiliation not found for team_id=#{team_id}, season_id=#{season_id}"
          Rails.logger.error('[Main] ERROR: TeamAffiliation not found for badge creation')
          return
        end

        attributes = normalize_badge_attributes(
          badge_hash,
          swimmer_id: swimmer_id,
          team_id: team_id,
          season_id: season_id,
          category_type_id: category_type_id,
          team_affiliation_id: team_affiliation.id
        )

        badge = GogglesDb::Badge.create!(attributes)
        @sql_log << SqlMaker.new(row: badge).log_insert
        @stats[:badges_created] += 1
        Rails.logger.info("[Main] Created Badge ID=#{badge.id}, swimmer_id=#{swimmer_id}, team_id=#{team_id}, category_id=#{category_type_id}")
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "Badge error (swimmer_id=#{swimmer_id}, team_id=#{team_id}): #{e.message}"
        Rails.logger.error("[Main] ERROR creating badge: #{e.message}")
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Phase 4 Commit Methods
      # =========================================================================

      def commit_meeting_event(event_hash)
        # Event data comes from phase4 with pre-matched meeting_event_id and meeting_session_id
        meeting_event_id = event_hash['meeting_event_id']
        meeting_session_id = event_hash['meeting_session_id']
        event_type_id = event_hash['event_type_id']

        # Guard clause: skip if missing required keys
        return unless meeting_session_id && event_type_id

        # If meeting_event_id exists, it's already in DB - skip (could add update logic here if needed)
        if meeting_event_id.present?
          Rails.logger.debug { "[Main] MeetingEvent ID=#{meeting_event_id} already exists, skipping" }
          return meeting_event_id
        end

        # Create new meeting event

        # Retrieve HeatType only if not already set by ID:
        heat_type = GogglesDb::HeatType.find_by(code: event_hash['heat_type']) if event_hash['heat_type'].present? && event_hash['heat_type_id'].blank?
        attributes = {
          'meeting_session_id' => meeting_session_id,
          'event_order' => event_hash['event_order'] || 0,
          'event_type_id' => event_type_id,
          'heat_type_id' => event_hash['heat_type_id'] || heat_type&.id,
          'begin_time' => event_hash['begin_time']
        }.compact

        new_event = GogglesDb::MeetingEvent.create!(attributes)
        @sql_log << SqlMaker.new(row: new_event).log_insert
        @stats[:events_created] += 1
        Rails.logger.info("[Main] Created MeetingEvent ID=#{new_event.id}, session=#{meeting_session_id}, type=#{event_type_id}, order=#{new_event.event_order}")
        new_event.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "MeetingEvent error (session=#{meeting_session_id}, type=#{event_type_id}): #{e.message}"
        Rails.logger.error("[Main] ERROR committing event: #{e.message}")
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
      # Phase 5 Commit Methods
      # =========================================================================

      def ensure_meeting_program(data_import_mir)
        # If MeetingProgram ID already set, return it
        return data_import_mir.meeting_program_id if data_import_mir.meeting_program_id.present?

        # Otherwise, we need to find or create the program
        # Programs are identified by: meeting_event_id + category_type + gender_type
        meeting_event_id = find_meeting_event_id_from_import_key(data_import_mir.import_key)
        return nil unless meeting_event_id

        # Extract category and gender from import_key
        # Format: "session-event-category-gender/swimmer_key"
        # Example: "1-100SL-M45-M/ROSSI|MARIO|1978"
        key_parts = data_import_mir.import_key.split('/').first.split('-')
        category_code = key_parts[2] # "M45"
        gender_code = key_parts[3]   # "M"

        category_type = GogglesDb::CategoryType.find_by(code: category_code)
        gender_type = GogglesDb::GenderType.find_by(code: gender_code)

        return nil unless category_type && gender_type

        # Find existing program
        program = GogglesDb::MeetingProgram.find_by(
          meeting_event_id: meeting_event_id,
          category_type_id: category_type.id,
          gender_type_id: gender_type.id
        )

        # Create if not found
        unless program
          program = GogglesDb::MeetingProgram.create!(
            meeting_event_id: meeting_event_id,
            category_type_id: category_type.id,
            gender_type_id: gender_type.id,
            event_order: 0 # Default order
          )
          @sql_log << SqlMaker.new(row: program).log_insert
          @stats[:programs_created] += 1
          Rails.logger.info("[Main] Created MeetingProgram ID=#{program.id}, event=#{meeting_event_id}, #{category_code}-#{gender_code}")
        end

        program.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "MeetingProgram error: #{e.message}"
        Rails.logger.error("[Main] ERROR ensuring program: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      def commit_meeting_individual_result(data_import_mir, program_id)
        mir_id = data_import_mir.meeting_individual_result_id

        # If MIR already has a DB ID (matched), update if needed
        if mir_id.present? && mir_id.positive?
          existing_mir = GogglesDb::MeetingIndividualResult.find_by(id: mir_id)
          if existing_mir
            # Check if timing or other attributes changed
            if mir_attributes_changed?(existing_mir, data_import_mir)
              update_mir_attributes(existing_mir, data_import_mir, program_id)
              @sql_log << SqlMaker.new(row: existing_mir).log_update
              @stats[:mirs_updated] += 1
              Rails.logger.info("[Main] Updated MIR ID=#{mir_id}")
            end
            return mir_id
          end
        end

        # Create new MIR
        attributes = {
          'meeting_program_id' => program_id,
          'swimmer_id' => data_import_mir.swimmer_id,
          'team_id' => data_import_mir.team_id,
          'rank' => data_import_mir.rank,
          'minutes' => data_import_mir.minutes,
          'seconds' => data_import_mir.seconds,
          'hundredths' => data_import_mir.hundredths,
          'disqualified' => data_import_mir.disqualified || false,
          'disqualification_code_type_id' => data_import_mir.disqualification_code_type_id,
          'standard_points' => data_import_mir.standard_points,
          'meeting_points' => data_import_mir.meeting_points,
          'reaction_time' => data_import_mir.reaction_time
        }.compact

        new_mir = GogglesDb::MeetingIndividualResult.create!(attributes)
        @sql_log << SqlMaker.new(row: new_mir).log_insert
        @stats[:mirs_created] += 1
        Rails.logger.info("[Main] Created MIR ID=#{new_mir.id}, program=#{program_id}, rank=#{new_mir.rank}")
        new_mir.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "MIR error (#{data_import_mir.import_key}): #{e.message}"
        Rails.logger.error("[Main] ERROR committing MIR: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      def commit_lap(data_import_lap, mir_id)
        # All laps are new (no matching logic for laps)
        attributes = {
          'meeting_individual_result_id' => mir_id,
          'length_in_meters' => data_import_lap.length_in_meters,
          'minutes' => data_import_lap.minutes,
          'seconds' => data_import_lap.seconds,
          'hundredths' => data_import_lap.hundredths,
          'minutes_from_start' => data_import_lap.minutes_from_start,
          'seconds_from_start' => data_import_lap.seconds_from_start,
          'hundredths_from_start' => data_import_lap.hundredths_from_start,
          'reaction_time' => data_import_lap.reaction_time,
          'breath_number' => data_import_lap.breath_number,
          'underwater_seconds' => data_import_lap.underwater_seconds,
          'underwater_hundredths' => data_import_lap.underwater_hundredths,
          'position' => data_import_lap.position
        }.compact

        new_lap = GogglesDb::Lap.create!(attributes)
        @sql_log << SqlMaker.new(row: new_lap).log_insert
        @stats[:laps_created] += 1
        new_lap.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "Lap error (#{data_import_lap.import_key}): #{e.message}"
        Rails.logger.error("[Main] ERROR committing lap: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      # Find meeting_event_id from import_key by parsing program key and matching with phase 4 data
      def find_meeting_event_id_from_import_key(import_key)
        # Extract program key: "1-100SL-M45-M" from "1-100SL-M45-M/ROSSI|MARIO|1978"
        program_key = import_key.split('/').first
        key_parts = program_key.split('-')

        session_order = key_parts[0] # "1"
        event_code = key_parts[1] # "100SL"

        # Find meeting_session_id from phase 1
        sessions = Array(phase1_data&.dig('data', 'sessions'))
        session = sessions.find { |s| s['session_order'].to_s == session_order.to_s }
        meeting_session_id = session&.dig('meeting_session_id')
        return nil unless meeting_session_id

        # Find meeting_event_id from phase 4 by session + event_code
        events = Array(phase4_data&.dig('data', 'events'))
        event = events.find do |e|
          e['meeting_session_key'] == session_order && e['event_code'] == event_code
        end
        event&.dig('meeting_event_id')
      end
      # -----------------------------------------------------------------------

      # Check if MIR attributes have changed
      def mir_attributes_changed?(existing_mir, data_import_mir)
        [
          existing_mir.rank != data_import_mir.rank,
          existing_mir.minutes != data_import_mir.minutes,
          existing_mir.seconds != data_import_mir.seconds,
          existing_mir.hundredths != data_import_mir.hundredths,
          existing_mir.disqualified != data_import_mir.disqualified,
          existing_mir.standard_points != data_import_mir.standard_points,
          existing_mir.meeting_points != data_import_mir.meeting_points
        ].any?
      end
      # -----------------------------------------------------------------------

      # Update MIR attributes from data_import_mir
      def update_mir_attributes(existing_mir, data_import_mir, program_id)
        existing_mir.update!(
          meeting_program_id: program_id,
          rank: data_import_mir.rank,
          minutes: data_import_mir.minutes,
          seconds: data_import_mir.seconds,
          hundredths: data_import_mir.hundredths,
          disqualified: data_import_mir.disqualified,
          disqualification_code_type_id: data_import_mir.disqualification_code_type_id,
          standard_points: data_import_mir.standard_points,
          meeting_points: data_import_mir.meeting_points,
          reaction_time: data_import_mir.reaction_time
        )
      end
      # -----------------------------------------------------------------------

      # =========================================================================
      # Helper Methods
      # =========================================================================

      # Build normalized meeting attributes matching DB schema
      def normalize_meeting_attributes(raw_meeting)
        meeting_hash = raw_meeting.deep_dup

        meeting_hash['autofilled'] = true if meeting_hash['autofilled'].nil?
        meeting_hash['allows_under25'] = meeting_hash.fetch('allows_under25', true)
        meeting_hash['cancelled'] = meeting_hash.fetch('cancelled', false)
        meeting_hash['confirmed'] = meeting_hash.fetch('confirmed', false)
        meeting_hash['max_individual_events'] ||= GogglesDb::Meeting.columns_hash['max_individual_events'].default
        meeting_hash['max_individual_events_per_session'] ||= GogglesDb::Meeting.columns_hash['max_individual_events_per_session'].default
        meeting_hash['notes'] = build_meeting_notes(meeting_hash)

        meeting_hash
      end
      # -----------------------------------------------------------------------

      def build_meeting_notes(meeting_hash)
        meeting_url = meeting_hash['meetingURL'] || meeting_hash['meeting_url']
        return meeting_hash['notes'] if meeting_url.blank?

        note_line = "meetingURL: #{meeting_url}"
        existing_notes = meeting_hash['notes']
        return note_line unless existing_notes.present?

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

      def normalize_team_attributes(team_hash)
        normalized = team_hash.deep_dup.with_indifferent_access
        normalized['editable_name'] ||= normalized['name']
        sanitized = sanitize_attributes(normalized, GogglesDb::Team)
        sanitized['name'] ||= sanitized['editable_name']
        sanitized
      end
      # -----------------------------------------------------------------------

      def normalize_team_affiliation_attributes(affiliation_hash, team_id:, season_id:, team:)
        normalized = affiliation_hash.deep_dup.with_indifferent_access
        normalized['team_id'] = team_id
        normalized['season_id'] = season_id
        normalized['name'] = normalized['name'].presence || team&.name
        if normalized.key?('compute_gogglecup') || normalized.key?(:compute_gogglecup)
          normalized['compute_gogglecup'] = BOOLEAN_TYPE.cast(normalized['compute_gogglecup'])
        end
        if normalized.key?('autofilled') || normalized.key?(:autofilled)
          normalized['autofilled'] = BOOLEAN_TYPE.cast(normalized['autofilled'])
        end

        sanitized = sanitize_attributes(normalized, GogglesDb::TeamAffiliation)
        sanitized['name'] ||= team&.name || ''
        sanitized
      end
      # -----------------------------------------------------------------------

      def normalize_swimmer_attributes(swimmer_hash)
        normalized = swimmer_hash.deep_dup.with_indifferent_access
        gender_code = normalized.delete('gender_type_code') || normalized.delete(:gender_type_code)
        normalized['gender_type_id'] ||= GogglesDb::GenderType.find_by(code: gender_code)&.id if gender_code.present?
        normalized['complete_name'] ||= build_complete_name(normalized)
        normalized['year_guessed'] = BOOLEAN_TYPE.cast(normalized['year_guessed']) if normalized.key?('year_guessed')

        sanitize_attributes(normalized, GogglesDb::Swimmer)
      end
      # -----------------------------------------------------------------------

      def normalize_badge_attributes(badge_hash, swimmer_id:, team_id:, season_id:, category_type_id:, team_affiliation_id:)
        normalized = badge_hash.deep_dup.with_indifferent_access
        normalized['swimmer_id'] = swimmer_id
        normalized['team_id'] = team_id
        normalized['season_id'] = season_id
        normalized['category_type_id'] ||= category_type_id
        normalized['team_affiliation_id'] = team_affiliation_id

        default_entry_time = GogglesDb::EntryTimeType.manual
        normalized['entry_time_type_id'] ||= default_entry_time&.id

        %w[off_gogglecup fees_due badge_due relays_due].each do |flag|
          next unless normalized.key?(flag)

          normalized[flag] = BOOLEAN_TYPE.cast(normalized[flag])
        end

        sanitize_attributes(normalized, GogglesDb::Badge)
      end
      # -----------------------------------------------------------------------

      def build_complete_name(swimmer_hash)
        swimmer_hash['complete_name'].presence || [swimmer_hash['last_name'], swimmer_hash['first_name']].compact_blank.join(' ')
      end
      # -----------------------------------------------------------------------

      def commit_calendar(meeting_hash)
        meeting_id = meeting_hash['meeting_id']
        meeting = GogglesDb::Meeting.find_by(id: meeting_id)
        return unless meeting

        calendar_attributes = build_calendar_attributes(meeting_hash, meeting)
        calendar_id = calendar_attributes['id']

        begin
          if calendar_id.present?
            existing = GogglesDb::Calendar.find_by(id: calendar_id)
            if existing && attributes_changed?(existing, calendar_attributes)
              existing.update!(calendar_attributes)
              @sql_log << SqlMaker.new(row: existing).log_update
              @stats[:calendars_updated] += 1
              Rails.logger.info("[Main] Updated Calendar ID=#{existing.id}")
            end
            return existing&.id
          end

          calendar = GogglesDb::Calendar.create!(calendar_attributes)
          @sql_log << SqlMaker.new(row: calendar).log_insert
          @stats[:calendars_created] += 1
          Rails.logger.info("[Main] Created Calendar ID=#{calendar.id}, meeting_id=#{meeting_id}")
          calendar.id
        rescue ActiveRecord::RecordInvalid => e
          error_details = GogglesDb::ValidationErrorTools.recursive_error_for(e.record)
          @stats[:errors] << "Calendar error: #{e.message} -- #{error_details}"
          Rails.logger.error("[Main] ERROR committing calendar: #{e.message}")
          nil
        end
      end
      # -----------------------------------------------------------------------

      def build_calendar_attributes(meeting_hash, meeting)
        existing = find_existing_calendar(meeting)
        scheduled_date = meeting.header_date || meeting_hash['scheduled_date']

        {
          'id' => existing&.id,
          'meeting_id' => meeting.id,
          'meeting_code' => meeting.code || meeting_hash['meeting_code'],
          'meeting_name' => meeting.description || meeting_hash['meeting_name'],
          'scheduled_date' => scheduled_date,
          'meeting_place' => build_meeting_place(meeting_hash),
          'season_id' => meeting.season_id || meeting_hash['season_id'],
          'year' => meeting_hash['dateYear1'] || scheduled_date&.year&.to_s,
          'month' => meeting_hash['dateMonth1'] || scheduled_date&.strftime('%m'),
          'results_link' => meeting_hash['meetingURL'] || meeting_hash['results_link'],
          'manifest_link' => meeting_hash['manifestURL'] || meeting_hash['manifest_link'],
          'organization_import_text' => meeting_hash['organization'],
          'cancelled' => meeting_hash.key?('cancelled') ? BOOLEAN_TYPE.cast(meeting_hash['cancelled']) : meeting.cancelled,
          'updated_at' => Time.zone.now
        }.compact
      end
      # -----------------------------------------------------------------------

      def find_existing_calendar(meeting)
        season = meeting.season || GogglesDb::Season.find_by(id: meeting.season_id)
        scopes = if season
                   GogglesDb::Calendar.for_season(season)
                 else
                   GogglesDb::Calendar.where(season_id: meeting.season_id)
                 end
        scopes.for_code(meeting.code).first || scopes.where(meeting_id: meeting.id).first
      end
      # -----------------------------------------------------------------------

      def build_meeting_place(meeting_hash)
        [meeting_hash['venue1'], meeting_hash['address1']].compact_blank.join(', ')
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
