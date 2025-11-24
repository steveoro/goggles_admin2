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
        raw_meeting_data = phase1_data['data'] || {}
        meeting_data = meeting_committer.normalize_attributes(raw_meeting_data)

        sessions_data = Array(meeting_data.delete('meeting_session')).map.with_index do |session_hash, index|
          normalize_session_attributes(session_hash, meeting_data['id'], index: index)
        end

        # Commit meeting (returns resulting meeting_id)
        meeting_id = meeting_committer.commit(meeting_data)
        return unless meeting_id

        calendar_committer.commit(meeting_data.merge('meeting_id' => meeting_id))

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
        total = teams_data.size
        teams_data.each_with_index do |team_hash, idx|
          commit_team(team_hash)
          broadcast_progress('Committing Teams', idx + 1, total)
        end

        # Then commit affiliations (affiliations now have pre-matched team_affiliation_id from Phase 2)
        affiliations_total = affiliations_data.size
        affiliations_data.each_with_index do |affiliation_hash, idx|
          commit_team_affiliation(affiliation_hash: affiliation_hash)
          broadcast_progress('Committing Team Affiliations', idx + 1, affiliations_total)
        end
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
        total = swimmers_data.size
        swimmers_data.each_with_index do |swimmer_hash, idx|
          commit_swimmer(swimmer_hash)
          broadcast_progress('Committing Swimmers', idx + 1, total)
        end

        # Then commit badges (badges now have pre-calculated category_type_id from Phase 3)
        badges_total = badges_data.size
        badges_data.each_with_index do |badge_hash, idx|
          commit_badge(badge_hash: badge_hash)
          broadcast_progress('Committing Badges', idx + 1, badges_total)
        end
      end
      # -----------------------------------------------------------------------

      # Phase 4: MeetingEvents
      # MeetingPrograms deferred to Phase 5 (created when committing results)
      def commit_phase4_entities
        Rails.logger.info('[Main] Committing Phase 4: Events')
        return unless phase4_data

        # Phase 4 data is structured as { "sessions": [ { "session_order": 1, "events": [...] }, ... ] }
        sessions = Array(phase4_data['sessions'])
        sessions.each_with_index do |session_hash, sess_idx|
          events = Array(session_hash['events'])
          session_total = events.size
          events.each_with_index do |event_hash, evt_idx|
            commit_meeting_event(event_hash)
            broadcast_progress("Committing Events for session #{sess_idx}", evt_idx + 1, session_total)
          end
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

        mir_total = all_mirs.size
        all_mirs.each_with_index do |data_import_mir, mir_idx|
          # Ensure MeetingProgram exists (may need to create it)
          program_id = ensure_meeting_program(data_import_mir)
          next unless program_id

          # Commit MIR (INSERT or UPDATE)
          mir_id = commit_meeting_individual_result(data_import_mir, program_id)
          next unless mir_id

          broadcast_progress("Committing MIR for MPrg ID #{program_id}", mir_idx + 1, mir_total)
          # Commit laps (skipping broadcast for these)
          data_import_mir.data_import_laps.each do |data_import_lap|
            commit_lap(data_import_lap, mir_id)
          end
        end

        # Commit relay results (MRR), relay swimmers (MRS), and relay laps
        all_mrrs = GogglesDb::DataImportMeetingRelayResult
                   .where(phase_file_path: source_path)
                   .includes(:data_import_meeting_relay_swimmers)
                   .order(:import_key)

        mrr_total = all_mrrs.size
        all_mrrs.each_with_index do |data_import_mrr, mrr_idx|
          # Ensure MeetingProgram exists (may need to create it)
          program_id = ensure_meeting_program(data_import_mrr)
          next unless program_id

          # Commit MRR (INSERT or UPDATE)
          mrr_id = commit_meeting_relay_result(data_import_mrr, program_id)
          next unless mrr_id

          broadcast_progress("Committing MRR for MPrg ID #{program_id}", mrr_idx + 1, mrr_total)
          # Commit relay swimmers and their laps
          data_import_mrr.data_import_meeting_relay_swimmers.each do |data_import_mrs|
            mrs_id = commit_meeting_relay_swimmer(data_import_mrs, mrr_id)
            next unless mrs_id

            # Commit relay laps for this swimmer
            data_import_mrs.data_import_relay_laps.each do |data_import_relay_lap|
              commit_relay_lap(data_import_relay_lap, mrs_id)
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

      def commit_meeting_session(session_hash)
        meeting_id = session_hash['meeting_id']

        return unless meeting_id

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

        # Fallback: try to match an existing team by name when team_id is missing
        existing = nil
        team_name = normalized_attributes['name']
        existing = GogglesDb::Team.find_by(name: team_name) if team_name.present?

        if existing
          if attributes_changed?(existing, normalized_attributes)
            existing.update!(normalized_attributes)
            @sql_log << SqlMaker.new(row: existing).log_update
            @stats[:teams_updated] += 1
            Rails.logger.info("[Main] Updated Team ID=#{existing.id} (matched by name)")
          end
          return existing.id
        end

        # Create new team (team_id is nil or 0 and no existing match found)
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

        team = GogglesDb::Team.find_by(id: team_id)
        attributes = normalize_team_affiliation_attributes(
          affiliation_hash,
          team_id: team_id,
          season_id: season_id,
          team: team
        )

        # Fallback: reuse existing team affiliation when one already exists for the same team/season
        existing = GogglesDb::TeamAffiliation.find_by(team_id: team_id, season_id: season_id)
        if existing
          if attributes_changed?(existing, attributes)
            existing.update!(attributes)
            @sql_log << SqlMaker.new(row: existing).log_update
            Rails.logger.info("[Main] Updated TeamAffiliation ID=#{existing.id}, team_id=#{team_id}, season_id=#{season_id}")
          end
          return
        end

        # Create new affiliation (minimal data - just links team to season)
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

        # Fallback: try to match an existing swimmer by complete_name + year_of_birth
        existing = nil
        complete_name = normalized_attributes['complete_name']
        year_of_birth = normalized_attributes['year_of_birth']
        existing = GogglesDb::Swimmer.find_by(complete_name: complete_name, year_of_birth: year_of_birth) if complete_name.present? && year_of_birth.present?

        # Secondary fallback: match by last_name + first_name + year_of_birth
        if existing.nil? && normalized_attributes['last_name'].present? &&
           normalized_attributes['first_name'].present? && year_of_birth.present?
          existing = GogglesDb::Swimmer.find_by(
            last_name: normalized_attributes['last_name'],
            first_name: normalized_attributes['first_name'],
            year_of_birth: year_of_birth
          )
        end

        if existing
          if attributes_changed?(existing, normalized_attributes)
            existing.update!(normalized_attributes)
            @sql_log << SqlMaker.new(row: existing).log_update
            @stats[:swimmers_updated] += 1
            Rails.logger.info("[Main] Updated Swimmer ID=#{existing.id} (matched by name/year)")
          end
          return existing.id
        end

        # Create new swimmer (swimmer_id is nil or 0 and no existing match found)
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

        # Fallback: reuse existing badge when one already exists for the same swimmer/team/season
        existing_badge = GogglesDb::Badge.find_by(
          season_id: season_id,
          swimmer_id: swimmer_id,
          team_id: team_id
        )

        if existing_badge
          if attributes_changed?(existing_badge, attributes)
            existing_badge.update!(attributes)
            @sql_log << SqlMaker.new(row: existing_badge).log_update
            Rails.logger.info("[Main] Updated Badge ID=#{existing_badge.id}, swimmer_id=#{swimmer_id}, team_id=#{team_id}, category_id=#{category_type_id}")
          end
          return existing_badge.id
        end

        badge = GogglesDb::Badge.create!(attributes)
        @sql_log << SqlMaker.new(row: badge).log_insert
        @stats[:badges_created] += 1
        Rails.logger.info("[Main] Created Badge ID=#{badge.id}, swimmer_id=#{swimmer_id}, team_id=#{team_id}, category_id=#{category_type_id}")
      rescue ActiveRecord::RecordInvalid => e
        model_row = e.record
        begin
          model_row ||= GogglesDb::Badge.new(attributes) if defined?(attributes)
        rescue StandardError
          # Best-effort reconstruction only; ignore secondary failures
        end

        error_details = if model_row
                          GogglesDb::ValidationErrorTools.recursive_error_for(model_row)
                        else
                          e.message
                        end

        swimmer_key = badge_hash['swimmer_key'] || badge_hash[:swimmer_key]
        team_key = badge_hash['team_key'] || badge_hash[:team_key]
        @stats[:errors] << "Badge error (swimmer_key=#{swimmer_key}, swimmer_id=#{swimmer_id}, team_id=#{team_id}): #{error_details}"
        @logger.log_validation_error(
          entity_type: 'Badge',
          entity_key: "swimmer_key=#{swimmer_key},swimmer_id=#{swimmer_id},team_id=#{team_id},team_key=#{team_key},season_id=#{season_id}",
          entity_id: model_row&.id,
          model_row: model_row,
          error: e
        )
        Rails.logger.error("[Main] ERROR creating badge: #{error_details}")
      end
      # -----------------------------------------------------------------------

      def commit_meeting_event(event_hash)
        meeting_event_id = event_hash['meeting_event_id']
        meeting_session_id = event_hash['meeting_session_id']
        event_type_id = event_hash['event_type_id']

        # Guard clause: skip if missing required keys
        return unless meeting_session_id && event_type_id

        attributes = normalize_meeting_event_attributes(
          event_hash,
          meeting_session_id: meeting_session_id,
          event_type_id: event_type_id
        )

        if meeting_event_id.present?
          existing = GogglesDb::MeetingEvent.find_by(id: meeting_event_id)
          if existing && attributes_changed?(existing, attributes)
            existing.update!(attributes)
            @sql_log << SqlMaker.new(row: existing).log_update
            @stats[:events_updated] += 1
            Rails.logger.info("[Main] Updated MeetingEvent ID=#{existing.id}")
          end
          return existing&.id || meeting_event_id
        end

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
          program_attributes = normalize_meeting_program_attributes(
            { 'event_order' => 0 },
            meeting_event_id: meeting_event_id,
            category_type_id: category_type.id,
            gender_type_id: gender_type.id
          )

          program = GogglesDb::MeetingProgram.create!(program_attributes)
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
            normalized_attributes = normalize_meeting_individual_result_attributes(data_import_mir, program_id: program_id)
            # Check if timing or other attributes changed
            if mir_attributes_changed?(existing_mir, normalized_attributes)
              update_mir_attributes(existing_mir, normalized_attributes)
              @sql_log << SqlMaker.new(row: existing_mir).log_update
              @stats[:mirs_updated] += 1
              Rails.logger.info("[Main] Updated MIR ID=#{mir_id}")
            end
            return mir_id
          end
        end

        # Create new MIR
        attributes = normalize_meeting_individual_result_attributes(data_import_mir, program_id: program_id)

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
        attributes = normalize_meeting_lap_attributes(data_import_lap, mir_id: mir_id)

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

      def commit_meeting_relay_result(data_import_mrr, program_id)
        mrr_id = data_import_mrr.meeting_relay_result_id

        # If MRR already has a DB ID (matched), update if needed
        if mrr_id.present? && mrr_id.positive?
          existing_mrr = GogglesDb::MeetingRelayResult.find_by(id: mrr_id)
          if existing_mrr
            normalized_attributes = normalize_meeting_relay_result_attributes(data_import_mrr, program_id: program_id)
            # Check if timing or other attributes changed
            if mrr_attributes_changed?(existing_mrr, normalized_attributes)
              update_mrr_attributes(existing_mrr, normalized_attributes)
              @sql_log << SqlMaker.new(row: existing_mrr).log_update
              @stats[:mrrs_updated] += 1
              Rails.logger.info("[Main] Updated MRR ID=#{mrr_id}")
            end
            return mrr_id
          end
        end

        # Create new MRR
        attributes = normalize_meeting_relay_result_attributes(data_import_mrr, program_id: program_id)

        new_mrr = GogglesDb::MeetingRelayResult.create!(attributes)
        @sql_log << SqlMaker.new(row: new_mrr).log_insert
        @stats[:mrrs_created] += 1
        Rails.logger.info("[Main] Created MRR ID=#{new_mrr.id}, program=#{program_id}, rank=#{new_mrr.rank}")
        new_mrr.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "MRR error (#{data_import_mrr.import_key}): #{e.message}"
        Rails.logger.error("[Main] ERROR committing MRR: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      def commit_meeting_relay_swimmer(data_import_mrs, mrr_id)
        mrs_id = data_import_mrs.meeting_relay_swimmer_id

        # If MRS already has a DB ID (matched), update if needed
        if mrs_id.present? && mrs_id.positive?
          existing_mrs = GogglesDb::MeetingRelaySwimmer.find_by(id: mrs_id)
          if existing_mrs
            normalized_attributes = normalize_meeting_relay_swimmer_attributes(data_import_mrs, mrr_id: mrr_id)
            if mrs_attributes_changed?(existing_mrs, normalized_attributes)
              update_mrs_attributes(existing_mrs, normalized_attributes)
              @sql_log << SqlMaker.new(row: existing_mrs).log_update
              @stats[:mrss_updated] += 1
              Rails.logger.info("[Main] Updated MRS ID=#{mrs_id}")
            end
            return mrs_id
          end
        end

        # Create new MRS
        attributes = normalize_meeting_relay_swimmer_attributes(data_import_mrs, mrr_id: mrr_id)

        new_mrs = GogglesDb::MeetingRelaySwimmer.create!(attributes)
        @sql_log << SqlMaker.new(row: new_mrs).log_insert
        @stats[:mrss_created] += 1
        Rails.logger.info("[Main] Created MRS ID=#{new_mrs.id}, mrr=#{mrr_id}, order=#{new_mrs.relay_order}")
        new_mrs.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "MRS error (#{data_import_mrs.import_key}): #{e.message}"
        Rails.logger.error("[Main] ERROR committing MRS: #{e.message}")
        nil
      end
      # -----------------------------------------------------------------------

      def commit_relay_lap(data_import_relay_lap, mrs_id)
        # All relay laps are new (no matching logic for relay laps)
        attributes = normalize_relay_lap_attributes(data_import_relay_lap, mrs_id: mrs_id)

        new_relay_lap = GogglesDb::RelayLap.create!(attributes)
        @sql_log << SqlMaker.new(row: new_relay_lap).log_insert
        @stats[:relay_laps_created] += 1
        new_relay_lap.id
      rescue ActiveRecord::RecordInvalid => e
        @stats[:errors] << "RelayLap error (#{data_import_relay_lap.import_key}): #{e.message}"
        Rails.logger.error("[Main] ERROR committing relay lap: #{e.message}")
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
      def mir_attributes_changed?(existing_mir, normalized_attributes)
        normalized_attributes.any? do |key, value|
          begin
            existing_value = existing_mir.public_send(key.to_sym)
          rescue NoMethodError
            existing_value = nil
          end
          existing_value != value
        end
      end
      # -----------------------------------------------------------------------

      # Update MIR attributes from data_import_mir
      def update_mir_attributes(existing_mir, normalized_attributes)
        existing_mir.update!(normalized_attributes)
      end
      # -----------------------------------------------------------------------

      # Check if MRR attributes have changed
      def mrr_attributes_changed?(existing_mrr, normalized_attributes)
        normalized_attributes.any? do |key, value|
          begin
            existing_value = existing_mrr.public_send(key.to_sym)
          rescue NoMethodError
            existing_value = nil
          end
          existing_value != value
        end
      end
      # -----------------------------------------------------------------------

      # Update MRR attributes from data_import_mrr
      def update_mrr_attributes(existing_mrr, normalized_attributes)
        existing_mrr.update!(normalized_attributes)
      end
      # -----------------------------------------------------------------------

      # Check if MRS attributes have changed
      def mrs_attributes_changed?(existing_mrs, normalized_attributes)
        normalized_attributes.any? do |key, value|
          begin
            existing_value = existing_mrs.public_send(key.to_sym)
          rescue NoMethodError
            existing_value = nil
          end
          existing_value != value
        end
      end
      # -----------------------------------------------------------------------

      # Update MRS attributes from data_import_mrs
      def update_mrs_attributes(existing_mrs, normalized_attributes)
        existing_mrs.update!(normalized_attributes)
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
        # DEBUG -------------------------------------------------------------------------
        # binding.pry
        #--------------------------------------------------------------------------------

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

      def normalize_meeting_individual_result_attributes(data_import_mir, program_id:)
        normalized = {
          'meeting_program_id' => program_id,
          'swimmer_id' => data_import_mir.swimmer_id,
          'team_id' => data_import_mir.team_id,
          'rank' => integer_or_nil(data_import_mir.rank),
          'minutes' => integer_or_nil(data_import_mir.minutes),
          'seconds' => integer_or_nil(data_import_mir.seconds),
          'hundredths' => integer_or_nil(data_import_mir.hundredths),
          'disqualified' => BOOLEAN_TYPE.cast(data_import_mir.disqualified),
          'disqualification_code_type_id' => data_import_mir.disqualification_code_type_id,
          'standard_points' => decimal_or_nil(data_import_mir.standard_points),
          'meeting_points' => decimal_or_nil(data_import_mir.meeting_points),
          'reaction_time' => decimal_or_nil(data_import_mir.reaction_time),
          'out_of_race' => BOOLEAN_TYPE.cast(data_import_mir.out_of_race),
          'goggle_cup_points' => decimal_or_nil(data_import_mir.goggle_cup_points),
          'team_points' => decimal_or_nil(data_import_mir.team_points)
        }.compact

        sanitize_attributes(normalized, GogglesDb::MeetingIndividualResult)
      end
      # -----------------------------------------------------------------------

      def normalize_meeting_lap_attributes(data_import_lap, mir_id:)
        normalized = {
          'meeting_individual_result_id' => mir_id,
          'length_in_meters' => integer_or_nil(data_import_lap.length_in_meters),
          'minutes' => integer_or_nil(data_import_lap.minutes),
          'seconds' => integer_or_nil(data_import_lap.seconds),
          'hundredths' => integer_or_nil(data_import_lap.hundredths),
          'minutes_from_start' => integer_or_nil(data_import_lap.minutes_from_start),
          'seconds_from_start' => integer_or_nil(data_import_lap.seconds_from_start),
          'hundredths_from_start' => integer_or_nil(data_import_lap.hundredths_from_start),
          'reaction_time' => decimal_or_nil(data_import_lap.reaction_time),
          'breath_cycles' => integer_or_nil(data_import_lap.breath_number),
          'underwater_seconds' => integer_or_nil(data_import_lap.underwater_seconds),
          'underwater_hundredths' => integer_or_nil(data_import_lap.underwater_hundredths),
          'underwater_kicks' => integer_or_nil(data_import_lap.underwater_kicks),
          'position' => integer_or_nil(data_import_lap.position)
        }.compact

        sanitize_attributes(normalized, GogglesDb::Lap)
      end
      # -----------------------------------------------------------------------

      def normalize_meeting_relay_result_attributes(data_import_mrr, program_id:)
        normalized = {
          'meeting_program_id' => program_id,
          'team_id' => data_import_mrr.team_id,
          'rank' => integer_or_nil(data_import_mrr.rank),
          'minutes' => integer_or_nil(data_import_mrr.minutes),
          'seconds' => integer_or_nil(data_import_mrr.seconds),
          'hundredths' => integer_or_nil(data_import_mrr.hundredths),
          'disqualified' => BOOLEAN_TYPE.cast(data_import_mrr.disqualified),
          'disqualification_code_type_id' => data_import_mrr.disqualification_code_type_id,
          'standard_points' => decimal_or_nil(data_import_mrr.standard_points),
          'meeting_points' => decimal_or_nil(data_import_mrr.meeting_points),
          'reaction_time' => decimal_or_nil(data_import_mrr.reaction_time),
          'out_of_race' => BOOLEAN_TYPE.cast(data_import_mrr.out_of_race),
          'team_points' => decimal_or_nil(data_import_mrr.team_points)
        }.compact

        sanitize_attributes(normalized, GogglesDb::MeetingRelayResult)
      end
      # -----------------------------------------------------------------------

      def normalize_meeting_relay_swimmer_attributes(data_import_mrs, mrr_id:)
        normalized = {
          'meeting_relay_result_id' => mrr_id,
          'swimmer_id' => data_import_mrs.swimmer_id,
          'badge_id' => data_import_mrs.badge_id,
          'stroke_type_id' => data_import_mrs.stroke_type_id,
          'relay_order' => integer_or_nil(data_import_mrs.relay_order),
          'minutes' => integer_or_nil(data_import_mrs.minutes),
          'seconds' => integer_or_nil(data_import_mrs.seconds),
          'hundredths' => integer_or_nil(data_import_mrs.hundredths),
          'reaction_time' => decimal_or_nil(data_import_mrs.reaction_time)
        }.compact

        sanitize_attributes(normalized, GogglesDb::MeetingRelaySwimmer)
      end
      # -----------------------------------------------------------------------

      def normalize_relay_lap_attributes(data_import_relay_lap, mrs_id:)
        normalized = {
          'meeting_relay_swimmer_id' => mrs_id,
          'length_in_meters' => integer_or_nil(data_import_relay_lap.length_in_meters),
          'minutes' => integer_or_nil(data_import_relay_lap.minutes),
          'seconds' => integer_or_nil(data_import_relay_lap.seconds),
          'hundredths' => integer_or_nil(data_import_relay_lap.hundredths),
          'minutes_from_start' => integer_or_nil(data_import_relay_lap.minutes_from_start),
          'seconds_from_start' => integer_or_nil(data_import_relay_lap.seconds_from_start),
          'hundredths_from_start' => integer_or_nil(data_import_relay_lap.hundredths_from_start),
          'reaction_time' => decimal_or_nil(data_import_relay_lap.reaction_time),
          'breath_cycles' => integer_or_nil(data_import_relay_lap.breath_number),
          'underwater_seconds' => integer_or_nil(data_import_relay_lap.underwater_seconds),
          'underwater_hundredths' => integer_or_nil(data_import_relay_lap.underwater_hundredths),
          'underwater_kicks' => integer_or_nil(data_import_relay_lap.underwater_kicks),
          'position' => integer_or_nil(data_import_relay_lap.position)
        }.compact

        sanitize_attributes(normalized, GogglesDb::RelayLap)
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
        normalized['autofilled'] = BOOLEAN_TYPE.cast(normalized['autofilled']) if normalized.key?('autofilled') || normalized.key?(:autofilled)

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

      # (Calendar commit logic moved to Import::Committers::Calendar)
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
