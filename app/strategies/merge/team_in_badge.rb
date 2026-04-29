# frozen_string_literal: true

module Merge
  # = Merge::TeamInBadge
  #
  #   - version:  7-0.7.25
  #   - author:   Steve A.
  #   - build:    20260308
  #
  # Fixes a wrongly-assigned team_id on one or more badges, including
  # mixed-season batches,
  # updating all related results (MIRs, laps, MRRs, relay_laps) and deleting
  # meeting entries and reservations.
  #
  # The strategy discovers additional badges linked via MRS → MRR cascade
  # (relay teammates) and includes them in the batch for data coherence.
  #
  # Before processing, it checks for duplicate badges (same swimmer + team + season
  # tuple already existing on destination). If duplicates are found,
  # the task halts — those are candidates for badge merge, not badge fix.
  #
  # == Usage:
  #   fixer = Merge::TeamInBadge.new(
  #     badges: [wrong_badge1, wrong_badge2],
  #     new_team: correct_team
  #   )
  #   fixer.display_report  # Preview what will be changed
  #   fixer.prepare         # Generate SQL statements
  #   # Then use the rake task helper to save/execute the SQL
  #
  class TeamInBadge # rubocop:disable Metrics/ClassLength
    attr_reader :badges, :new_team, :seasons, :dest_tas_by_season,
                :badge_batch, :errors, :sql_log

    # == Params:
    # - <tt>:badges</tt> => array of Badge instances to fix, *required*
    # - <tt>:new_team</tt> => destination (correct) Team instance, *required*
    #
    def initialize(badges:, new_team:)
      raise(ArgumentError, 'badges must be a non-empty Array of Badges!') unless valid_badges?(badges)
      raise(ArgumentError, 'new_team must be a Team!') unless new_team.is_a?(GogglesDb::Team)
      raise(ArgumentError, 'Some badges already belong to the destination team!') if badges.any? { |b| b.team_id == new_team.id }

      @badges = badges
      @new_team = new_team
      @sql_log = []
      @errors = []

      @badge_batch = collect_badge_batch
      @seasons = collect_seasons
      resolve_team_affiliations
      check_for_duplicates
    end
    #-- -----------------------------------------------------------------------
    #++

    # Returns the MIRs linked to badge_batch badges.
    def dest_ta
      @dest_tas_by_season.values.first if @dest_tas_by_season&.size == 1
    end

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

    # Returns the MRR IDs discovered via MRS cascade.
    def affected_mrr_ids
      @affected_mrr_ids ||= GogglesDb::MeetingRelaySwimmer
                            .where(badge_id: badge_batch_ids)
                            .distinct
                            .pluck(:meeting_relay_result_id)
    end

    # Returns the MRRs linked via MRS cascade.
    def affected_mrrs
      @affected_mrrs ||= GogglesDb::MeetingRelayResult
                         .where(id: affected_mrr_ids)
    end

    # Returns the relay_laps linked to affected MRRs.
    def affected_relay_laps
      @affected_relay_laps ||= GogglesDb::RelayLap
                               .where(meeting_relay_result_id: affected_mrr_ids)
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
      puts 'Badge Team Fix Preview'
      puts '=' * 60
      puts "Seasons: #{season_labels.join(', ')}"
      puts "New (correct) team: (#{@new_team.id}) \"#{@new_team.name}\""
      puts "  -> TeamAffiliations by season: #{team_affiliation_labels.join(', ')}"

      puts "\r\n--- Badges to update (#{badge_batch.size}) ---"
      badge_batch.each do |badge|
        decorated = badge.respond_to?(:display_label) ? badge : badge.decorate
        puts "  Badge #{badge.id}: swimmer #{badge.swimmer_id} (#{decorated.display_label}) " \
             "| current team: #{badge.team_id}"
      end

      puts "\r\n--- Affected results ---"
      puts "- MIRs: #{affected_mirs.count}"
      puts "- Laps: #{affected_laps.count}"
      puts "- MRRs: #{affected_mrrs.count}"
      puts "- Relay laps: #{affected_relay_laps.count}"

      puts "\r\n--- Rows to delete ---"
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
      @sql_log << "-- Fix team_id in badges: [#{ids_list}]"
      @sql_log << "-- New team: (#{@new_team.id}) #{@new_team.name}"
      @sql_log << "-- Seasons: #{season_labels.join(', ')}"
      @sql_log << ''
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''

      prepare_badge_updates
      prepare_mir_updates
      prepare_lap_updates(ids_list)
      prepare_mrr_updates
      prepare_relay_lap_updates
      prepare_entry_deletions(ids_list)
      prepare_reservation_deletions(ids_list)

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

    # Resolves TeamAffiliation for the destination team in each involved season.
    def resolve_team_affiliations
      @dest_tas_by_season = @seasons.each_with_object({}) do |season, memo|
        memo[season.id] = GogglesDb::TeamAffiliation.find_by(team_id: @new_team.id, season_id: season.id)
      end
      missing = @dest_tas_by_season.select { |_season_id, ta| ta.blank? }.keys
      return if missing.empty?

      raise(ArgumentError, "Destination team #{@new_team.id} has no TeamAffiliation for season(s): #{missing.join(', ')}!")
    end

    # Returns the array of badge IDs in the batch.
    def badge_batch_ids
      @badge_batch_ids ||= @badge_batch.map(&:id)
    end

    # Returns all involved seasons from the badge batch.
    def collect_seasons
      GogglesDb::Season.where(id: @badge_batch.map(&:season_id).uniq).index_by(&:id).values
    end

    # Returns badge IDs grouped by season.
    def badge_ids_by_season
      @badge_ids_by_season ||= @badge_batch.group_by(&:season_id).transform_values { |rows| rows.map(&:id) }
    end

    # Returns all season labels for display/reporting.
    def season_labels
      @season_labels ||= @seasons.sort_by(&:id).map { |season| "#{season.id} - #{season.description}" }
    end

    # Returns destination TeamAffiliation labels grouped by season.
    def team_affiliation_labels
      @team_affiliation_labels ||= @dest_tas_by_season.sort_by { |season_id, _| season_id }
                                                      .map { |season_id, ta| "#{season_id}:#{ta.id}" }
    end

    # Discovers the full batch of badges to fix via MRS → MRR cascade.
    # Starting from the input badges, finds relay teammates whose badges
    # also need updating.
    def collect_badge_batch
      batch_ids = Set.new(@badges.map(&:id))
      processed_ids = Set.new

      # Iteratively discover related badges via MRS → MRR links
      loop do
        new_ids = batch_ids - processed_ids
        break if new_ids.empty?

        processed_ids.merge(new_ids)

        # Find MRR IDs for current batch of badge IDs
        mrr_ids = GogglesDb::MeetingRelaySwimmer
                  .where(badge_id: new_ids.to_a)
                  .distinct
                  .pluck(:meeting_relay_result_id)
        next if mrr_ids.empty?

        # Find all MRS rows for those MRRs → collect their badge_ids
        related_badge_ids = GogglesDb::MeetingRelaySwimmer
                            .where(meeting_relay_result_id: mrr_ids)
                            .distinct
                            .pluck(:badge_id)

        # Only add badges with the wrong team (season can differ).
        related_badges = GogglesDb::Badge
                         .where(id: related_badge_ids)
                         .where.not(team_id: @new_team.id)
        related_badges.each { |b| batch_ids.add(b.id) }
      end

      GogglesDb::Badge.where(id: batch_ids.to_a)
    end

    # Checks for duplicate badges: same swimmer + destination team + same season already has a badge
    # on the destination team. Those are merge candidates, not fix candidates.
    def check_for_duplicates
      @badge_batch.each do |badge|
        dup = GogglesDb::Badge.find_by(
          swimmer_id: badge.swimmer_id,
          season_id: badge.season_id,
          team_id: @new_team.id
        )
        next unless dup

        @errors << "Swimmer #{badge.swimmer_id} already has badge #{dup.id} for team #{@new_team.id} " \
                   "in season #{badge.season_id} (conflicting with badge #{badge.id})"
      end
    end
    #-- -----------------------------------------------------------------------
    #   SQL generation helpers
    #-- -----------------------------------------------------------------------

    # Step 1: Update badges with correct team_id and team_affiliation_id.
    def prepare_badge_updates
      @sql_log << '-- Step 1: Update badges with correct team_id and season-specific team_affiliation_id'
      badge_ids_by_season.sort.each do |season_id, ids|
        @sql_log << "UPDATE badges SET team_id = #{@new_team.id}, " \
                    "team_affiliation_id = #{@dest_tas_by_season[season_id].id}, " \
                    'updated_at = NOW() ' \
                    "WHERE id IN (#{ids.join(', ')});"
      end
      @sql_log << ''
    end

    # Step 2: Update MIRs with correct team_id and team_affiliation_id.
    def prepare_mir_updates
      @sql_log << '-- Step 2: Update MIRs with correct team_id and season-specific team_affiliation_id'
      badge_ids_by_season.sort.each do |season_id, ids|
        @sql_log << "UPDATE meeting_individual_results SET team_id = #{@new_team.id}, " \
                    "team_affiliation_id = #{@dest_tas_by_season[season_id].id}, " \
                    'updated_at = NOW() ' \
                    "WHERE badge_id IN (#{ids.join(', ')});"
      end
      @sql_log << ''
    end

    # Step 3: Update laps with correct team_id (via MIR join).
    def prepare_lap_updates(ids_list)
      @sql_log << '-- Step 3: Update laps with correct team_id'
      @sql_log << <<~SQL.squish
        UPDATE laps l
        INNER JOIN meeting_individual_results mir ON l.meeting_individual_result_id = mir.id
        SET l.team_id = #{@new_team.id}
        WHERE mir.badge_id IN (#{ids_list});
      SQL
      @sql_log << ''
    end

    # Step 4: Update MRRs with correct team_id and team_affiliation_id.
    def prepare_mrr_updates
      return if affected_mrr_ids.empty?

      @sql_log << '-- Step 4: Update MRRs with correct team_id and season-specific team_affiliation_id'
      badge_ids_by_season.sort.each do |season_id, ids|
        @sql_log << <<~SQL.squish
          UPDATE meeting_relay_results mrr
          INNER JOIN meeting_relay_swimmers mrs ON mrs.meeting_relay_result_id = mrr.id
          INNER JOIN badges b ON b.id = mrs.badge_id
          SET mrr.team_id = #{@new_team.id}, mrr.team_affiliation_id = #{@dest_tas_by_season[season_id].id}, mrr.updated_at = NOW()
          WHERE b.season_id = #{season_id} AND mrs.badge_id IN (#{ids.join(', ')});
        SQL
      end
      @sql_log << ''
    end

    # Step 5: Update relay_laps with correct team_id.
    def prepare_relay_lap_updates
      return if affected_mrr_ids.empty?

      mrr_ids_list = affected_mrr_ids.join(', ')
      @sql_log << '-- Step 5: Update relay_laps with correct team_id'
      @sql_log << "UPDATE relay_laps SET team_id = #{@new_team.id} " \
                  "WHERE meeting_relay_result_id IN (#{mrr_ids_list});"
      @sql_log << ''
    end

    # Step 6: Delete meeting_entries for affected badges.
    def prepare_entry_deletions(ids_list)
      @sql_log << '-- Step 6: Delete meeting entries for affected badges'
      @sql_log << "DELETE FROM meeting_entries WHERE badge_id IN (#{ids_list});"
      @sql_log << ''
    end

    # Steps 7-9: Delete all reservation types for affected badges.
    def prepare_reservation_deletions(ids_list)
      @sql_log << '-- Step 7: Delete meeting event reservations for affected badges'
      @sql_log << "DELETE FROM meeting_event_reservations WHERE badge_id IN (#{ids_list});"
      @sql_log << ''
      @sql_log << '-- Step 8: Delete meeting relay reservations for affected badges'
      @sql_log << "DELETE FROM meeting_relay_reservations WHERE badge_id IN (#{ids_list});"
      @sql_log << ''
      @sql_log << '-- Step 9: Delete meeting reservations for affected badges'
      @sql_log << "DELETE FROM meeting_reservations WHERE badge_id IN (#{ids_list});"
    end
  end
end
