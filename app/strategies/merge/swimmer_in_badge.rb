# frozen_string_literal: true

module Merge
  # = Merge::SwimmerInBadge
  #
  #   - version:  7-0.8.40
  #   - author:   Steve A.
  #   - build:    20260406
  #
  # Fixes a wrongly-assigned swimmer_id on one or more badges,
  # updating all related badge-linked entities.
  #
  # Before processing, it checks for duplicate badges (destination swimmer already
  # having a badge for the same season/team tuple). If duplicates are found, the task halts
  # so that a badge merge can be evaluated instead.
  #
  # == Usage:
  #   fixer = Merge::SwimmerInBadge.new(
  #     badges: [wrong_badge1, wrong_badge2],
  #     new_swimmer: correct_swimmer
  #   )
  #   fixer.display_report  # Preview what will be changed
  #   fixer.prepare         # Generate SQL statements
  #   # Then use the rake task helper to save/execute the SQL
  #
  class SwimmerInBadge # rubocop:disable Metrics/ClassLength
    attr_reader :badges, :new_swimmer, :seasons, :badge_batch, :errors, :sql_log

    # == Params:
    # - <tt>:badges</tt> => array of Badge instances to fix, *required*
    # - <tt>:new_swimmer</tt> => destination (correct) Swimmer instance, *required*
    #
    def initialize(badges:, new_swimmer:)
      raise(ArgumentError, 'badges must be a non-empty Array of Badges!') unless valid_badges?(badges)
      raise(ArgumentError, 'new_swimmer must be a Swimmer!') unless new_swimmer.is_a?(GogglesDb::Swimmer)
      raise(ArgumentError, 'Some badges already belong to the destination swimmer!') if badges.any? { |b| b.swimmer_id == new_swimmer.id }

      @badges = badges
      @new_swimmer = new_swimmer
      @sql_log = []
      @errors = []

      @badge_batch = collect_badge_batch
      @seasons = collect_seasons
      check_for_duplicates
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the MIRs linked to badge_batch badges.
    def affected_mirs
      @affected_mirs ||= GogglesDb::MeetingIndividualResult
                         .where(badge_id: badge_batch_ids)
    end

    # Returns the laps linked to affected MIRs.
    def affected_laps
      @affected_laps ||= GogglesDb::Lap
                         .joins(:meeting_individual_result)
                         .where(meeting_individual_results: { badge_id: badge_batch_ids })
    end

    # Returns the MRSs linked to badge_batch badges.
    def affected_mrss
      @affected_mrss ||= GogglesDb::MeetingRelaySwimmer
                         .where(badge_id: badge_batch_ids)
    end

    # Returns the relay_laps linked to affected MRS rows.
    def affected_relay_laps
      @affected_relay_laps ||= GogglesDb::RelayLap
                               .where(meeting_relay_swimmer_id: affected_mrs_ids)
    end

    # Returns the MeetingEntries linked to badge_batch badges.
    def affected_meeting_entries
      @affected_meeting_entries ||= GogglesDb::MeetingEntry
                                    .where(badge_id: badge_batch_ids)
    end

    # Returns the MeetingReservations linked to badge_batch badges.
    def affected_meeting_reservations
      @affected_meeting_reservations ||= GogglesDb::MeetingReservation
                                         .where(badge_id: badge_batch_ids)
    end

    # Returns the MeetingEventReservations linked to badge_batch badges.
    def affected_meeting_event_reservations
      @affected_meeting_event_reservations ||= GogglesDb::MeetingEventReservation
                                               .where(badge_id: badge_batch_ids)
    end

    # Returns the MeetingRelayReservations linked to badge_batch badges.
    def affected_meeting_relay_reservations
      @affected_meeting_relay_reservations ||= GogglesDb::MeetingRelayReservation
                                               .where(badge_id: badge_batch_ids)
    end
    #-- -----------------------------------------------------------------------
    #++

    # Outputs a detailed report of the fix preview to stdout.
    # rubocop:disable Rails/Output, Metrics/AbcSize
    def display_report
      puts "\r\n#{'=' * 60}"
      puts 'Badge Swimmer Fix Preview'
      puts '=' * 60
      puts "Seasons: #{season_labels.join(', ')}"
      puts "New (correct) swimmer: (#{@new_swimmer.id}) \"#{@new_swimmer.complete_name}\""

      puts "\r\n--- Badges to update (#{badge_batch.size}) ---"
      badge_batch.each do |badge|
        decorated = badge.respond_to?(:display_label) ? badge : badge.decorate
        puts "  Badge #{badge.id}: swimmer #{badge.swimmer_id} (#{decorated.display_label}) " \
             "| team: #{badge.team_id}"
      end

      puts "\r\n--- Affected rows ---"
      puts "- MIRs: #{affected_mirs.count}"
      puts "- Laps: #{affected_laps.count}"
      puts "- MRSs: #{affected_mrss.count}"
      puts "- Relay laps: #{affected_relay_laps.count}"
      puts "- Meeting entries: #{affected_meeting_entries.count}"
      puts "- Meeting reservations: #{affected_meeting_reservations.count}"
      puts "- Meeting event reservations: #{affected_meeting_event_reservations.count}"
      puts "- Meeting relay reservations: #{affected_meeting_relay_reservations.count}"

      if @errors.any?
        puts "\r\n--- ERRORS (processing will halt) ---"
        @errors.each { |e| puts "  ⚠ #{e}" }
      end

      puts "\r\n#{'=' * 60}\r\n"
    end
    # rubocop:enable Rails/Output, Metrics/AbcSize

    # Generates the SQL statements for the fix and stores them in @sql_log.
    # This method should only be called once.
    # Raises if duplicate badges were detected during initialization.
    #
    # rubocop:disable Metrics/AbcSize
    def prepare
      return if @sql_log.present?

      if @errors.any?
        display_report
        raise("Duplicate badges detected! Use badge merge instead. Errors: #{@errors.join('; ')}")
      end

      ids_list = badge_batch_ids.join(', ')
      @sql_log << "-- Fix swimmer_id in badges: [#{ids_list}]"
      @sql_log << "-- New swimmer: (#{@new_swimmer.id}) #{@new_swimmer.complete_name}"
      @sql_log << "-- Seasons: #{season_labels.join(', ')}"
      @sql_log << ''
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''

      prepare_badge_updates(ids_list)
      prepare_mir_updates(ids_list)
      prepare_lap_updates(ids_list)
      prepare_mrs_updates(ids_list)
      prepare_relay_lap_updates
      prepare_entry_updates(ids_list)
      prepare_reservation_updates(ids_list)

      @sql_log << ''
      @sql_log << 'COMMIT;'
    end
    # rubocop:enable Metrics/AbcSize
    #-- -----------------------------------------------------------------------
    #++

    private

    # Validates badges argument.
    def valid_badges?(badges)
      badges.is_a?(Array) && badges.any? && badges.all?(GogglesDb::Badge)
    end

    # Returns the array of badge IDs in the batch.
    def badge_batch_ids
      @badge_batch_ids ||= @badge_batch.map(&:id)
    end

    # Returns all involved seasons from the badge batch.
    def collect_seasons
      GogglesDb::Season.where(id: @badge_batch.map(&:season_id).uniq).index_by(&:id).values
    end

    # Returns all season labels for display/reporting.
    def season_labels
      @season_labels ||= @seasons.sort_by(&:id).map { |season| "#{season.id} - #{season.description}" }
    end

    # Returns the array of MRS IDs linked to the badge batch.
    def affected_mrs_ids
      @affected_mrs_ids ||= affected_mrss.pluck(:id)
    end

    # Returns the selected badges as an AR relation.
    def collect_badge_batch
      GogglesDb::Badge.where(id: @badges.map(&:id))
    end

    # Checks for duplicate badges: same season + same team already enrolled for destination swimmer.
    # Those are merge candidates, not fix candidates.
    def check_for_duplicates
      @badge_batch.each do |badge|
        dup = GogglesDb::Badge.find_by(
          swimmer_id: @new_swimmer.id,
          season_id: badge.season_id,
          team_id: badge.team_id
        )
        next unless dup && dup.id != badge.id

        @errors << "Swimmer #{@new_swimmer.id} already has badge #{dup.id} for team #{badge.team_id} " \
                   "in season #{badge.season_id} (conflicting with badge #{badge.id})"
      end
    end
    #-- -----------------------------------------------------------------------
    #   SQL generation helpers
    #-- -----------------------------------------------------------------------

    # Step 1: Update badges with correct swimmer_id.
    def prepare_badge_updates(ids_list)
      @sql_log << '-- Step 1: Update badges with correct swimmer_id'
      @sql_log << "UPDATE badges SET swimmer_id = #{@new_swimmer.id}, " \
                  'updated_at = NOW() ' \
                  "WHERE id IN (#{ids_list});"
      @sql_log << ''
    end

    # Step 2: Update MIRs with correct swimmer_id.
    def prepare_mir_updates(ids_list)
      @sql_log << '-- Step 2: Update MIRs with correct swimmer_id'
      @sql_log << "UPDATE meeting_individual_results SET swimmer_id = #{@new_swimmer.id}, " \
                  'updated_at = NOW() ' \
                  "WHERE badge_id IN (#{ids_list});"
      @sql_log << ''
    end

    # Step 3: Update laps with correct swimmer_id (via MIR join).
    def prepare_lap_updates(ids_list)
      @sql_log << '-- Step 3: Update laps with correct swimmer_id'
      @sql_log << <<~SQL.squish
        UPDATE laps l
        INNER JOIN meeting_individual_results mir ON l.meeting_individual_result_id = mir.id
        SET l.swimmer_id = #{@new_swimmer.id}
        WHERE mir.badge_id IN (#{ids_list});
      SQL
      @sql_log << ''
    end

    # Step 4: Update MRSs with correct swimmer_id.
    def prepare_mrs_updates(ids_list)
      @sql_log << '-- Step 4: Update MRSs with correct swimmer_id'
      @sql_log << "UPDATE meeting_relay_swimmers SET swimmer_id = #{@new_swimmer.id}, " \
                  'updated_at = NOW() ' \
                  "WHERE badge_id IN (#{ids_list});"
      @sql_log << ''
    end

    # Step 5: Update relay_laps with correct swimmer_id.
    def prepare_relay_lap_updates
      return if affected_mrs_ids.empty?

      mrs_ids_list = affected_mrs_ids.join(', ')
      @sql_log << '-- Step 5: Update relay_laps with correct swimmer_id'
      @sql_log << "UPDATE relay_laps SET swimmer_id = #{@new_swimmer.id} " \
                  "WHERE meeting_relay_swimmer_id IN (#{mrs_ids_list});"
      @sql_log << ''
    end

    # Step 6: Update meeting_entries for affected badges.
    def prepare_entry_updates(ids_list)
      @sql_log << '-- Step 6: Update meeting entries with correct swimmer_id'
      @sql_log << "UPDATE meeting_entries SET swimmer_id = #{@new_swimmer.id}, " \
                  'updated_at = NOW() ' \
                  "WHERE badge_id IN (#{ids_list});"
      @sql_log << ''
    end

    # Steps 7-9: Update all reservation types for affected badges.
    def prepare_reservation_updates(ids_list)
      @sql_log << '-- Step 7: Update meeting event reservations with correct swimmer_id'
      @sql_log << "UPDATE meeting_event_reservations SET swimmer_id = #{@new_swimmer.id}, " \
                  'updated_at = NOW() ' \
                  "WHERE badge_id IN (#{ids_list});"
      @sql_log << ''
      @sql_log << '-- Step 8: Update meeting relay reservations with correct swimmer_id'
      @sql_log << "UPDATE meeting_relay_reservations SET swimmer_id = #{@new_swimmer.id}, " \
                  'updated_at = NOW() ' \
                  "WHERE badge_id IN (#{ids_list});"
      @sql_log << ''
      @sql_log << '-- Step 9: Update meeting reservations with correct swimmer_id'
      @sql_log << "UPDATE meeting_reservations SET swimmer_id = #{@new_swimmer.id}, " \
                  'updated_at = NOW() ' \
                  "WHERE badge_id IN (#{ids_list});"
    end
  end
end
