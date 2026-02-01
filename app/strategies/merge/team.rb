# frozen_string_literal: true

module Merge
  #
  # = Merge::Team
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20241015
  #
  class Team
    attr_reader :sql_log, :checker, :source, :dest

    # Allows a source Team to be merged into a destination one.
    # All related entities will be handled (team_affiliations, badges, results, laps, ...)
    # mostly by a simple 'team_id' update.
    #
    # This is a much more simplified version of merge process done by Merge::Badge for
    # instance, which instead does more checks and performs additional fixes to prevent
    # data inconsistencies.
    #
    # === Involved entities (in alphabetical order):
    #
    # - Badge                   (#team_id, #team_affiliation_id)
    # - ComputedSeasonRanking   (#team_id)
    # - GoggleCup               (#team_id)
    # - IndividualRecord        (#team_id)
    # - Lap                     (#team_id)
    # - ManagedAffiliation      (#team_affiliation_id)
    # - MeetingEntry            (#team_id, #team_affiliation_id)
    # - MeetingEventReservation (#team_id) (*)unique idx with team_id + more
    # - MeetingReservation      (#team_id) (*)unique idx with badge_id + more
    # - MeetingRelayReservation (#team_id) (*)unique idx with team_id + more
    # - MeetingIndividualResult (#team_id, #team_affiliation_id)
    # - MeetingRelayResult      (#team_id, #team_affiliation_id)
    # - MeetingTeamScore        (#team_id, #team_affiliation_id)
    # - Meeting                 (#home_team_id)
    # - RelayLap                (#team_id)
    # (- Team)
    # - TeamAffiliation         (#team_id) (*)unique idx with team_id & season_id
    # - TeamAlias               (#team_id) (*)unique idx with team_id & name
    # - TeamLapTemplate         (#team_id)
    # - UserWorkshop            (#team_id)
    #
    # Entity rows affected by unique indexes (*) need to be deleted before becoming duplicates.
    #
    # All other duplicate rows generated with the merge Team process *must* be dealt with
    # using the dedicated tasks 'merge:season_fix' or 'merge:badge'.
    # These will perform the necessary cleanup on a season-by-season or badge-by-badge basis.
    #
    # == Additional notes:
    # This merge class won't actually touch the DB: it will just prepare the script so
    # that this process can be replicated on any DB that is in sync with the current one.
    #
    # == Params
    # - <tt>:source</tt> => source Team row, *required*
    # - <tt>:dest</tt>   => destination Team row, *required*
    #
    # - <tt>:skip_columns</tt> => Force this to +true+ to avoid updating the destination row columns
    #   with the values stored in source; default: +false+.
    #
    def initialize(source:, dest:, skip_columns: false)
      raise(ArgumentError, 'Both source and destination must be Teams!') unless source.is_a?(GogglesDb::Team) && dest.is_a?(GogglesDb::Team)

      @skip_columns = skip_columns
      @checker = TeamChecker.new(source:, dest:)
      @source = @checker.source
      @dest = @checker.dest
      @sql_log = []
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the merge script inside a single transaction.
    # Countrary to other Merge classes, this strategy class does not halt in case of conflicts
    # and always displays the checker report.
    def prepare # rubocop:disable Metrics/AbcSize
      @checker.run
      @checker.display_report

      @sql_log << "\r\n-- Merge team (#{@source.id}) #{@source.display_label} |=> (#{@dest.id}) #{@dest.display_label}-- \r\n"
      # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''

      prepare_script_for_team_affiliation_links
      prepare_script_for_team_only_links

      # Overwrite all commonly used columns at the end, if requested (this will update the index too)
      attrs = []
      if @skip_columns
        # Update just the name variations:
        name_variations = @dest.name_variations.include?(@source.name) ? @dest.name_variations : "#{@dest.name_variations};#{@source.name}"
        attrs << "name_variations=\"#{name_variations}\""
      else
        # Update only attributes with values (don't overwrite existing with nulls):
        attrs << "name=\"#{@source.name}\""
        attrs << "editable_name=\"#{@source.editable_name}\"" if @source.editable_name.present?
        attrs << "name_variations=\"#{@source.name_variations}\"" if @source.name_variations.present?
        attrs << "city_id=#{@source.city_id}" if @source.city_id.present?
      end
      @sql_log << "UPDATE teams SET updated_at=NOW(), #{attrs.join(', ')} WHERE id=#{@dest.id};"

      @sql_log << ''
      @sql_log << 'COMMIT;'
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the <tt>#log</tt> array from the internal TeamChecker instance.
    delegate :log, to: :@checker
    #-- ------------------------------------------------------------------------
    #++

    private

    # Prepares the SQL text for the "TeamAffiliation update" phase involving all entities that have a
    # foreign key to the source TeamAffiliation ID.
    #
    # == TeamAffiliation is bound to:
    # - Badge                   (#team_id, #team_affiliation_id)
    # - ManagedAffiliation      (#team_affiliation_id)
    # - MeetingEntry            (#team_id, #team_affiliation_id)
    # - MeetingIndividualResult (#team_id, #team_affiliation_id)
    # - MeetingRelayResult      (#team_id, #team_affiliation_id)
    # - MeetingTeamScore        (#team_id, #team_affiliation_id)
    # - [TeamAffiliation]       (#team_id) (*)unique idx with team_id & season_id
    #
    # rubocop:disable Layout/LineLength
    def prepare_script_for_team_affiliation_links # rubocop:disable Metrics/AbcSize
      # For each source TeamAffiliation, set the correct destination Team & TA for all its sub-entities:
      GogglesDb::TeamAffiliation.where(team_id: @source.id).order(:season_id).each do |src_ta|
        dest_ta = GogglesDb::TeamAffiliation.where(season_id: src_ta.season_id, team_id: @dest.id).first

        # Found dest. TA for a corresponding source? => Use it as destination for updating all source TA references
        # (src_ta |==> dest_ta)
        if dest_ta
          @sql_log << "\r\n-- Season #{src_ta.season_id}, dest. TA found #{dest_ta.id}, updating references to source TA #{src_ta.id}:"
          # All source sub-entities will become dest:
          @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
          @sql_log << "UPDATE managed_affiliations SET updated_at=NOW(), team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
          @sql_log << "UPDATE meeting_entries SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
          @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
          @sql_log << "UPDATE meeting_team_scores SET updated_at=NOW(), team_id=#{@dest.id}, team_affiliation_id=#{dest_ta.id} WHERE team_affiliation_id=#{src_ta.id};"
          # Update source TA only at the end:
          @sql_log << "DELETE FROM team_affiliations WHERE id=#{src_ta.id};"

        # Dest. TA MISSING? Use source TA row and change its team_id:
        # (src_ta |==> src_ta recycled into dest, so ta's links are ok)
        else
          @sql_log << "\r\n-- Season #{src_ta.season_id}, dest. TA MISSING, recycling source TA #{src_ta.id} (updating only team references):"
          @sql_log << "UPDATE badges SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
          # (managed_affiliations table is already ok, as src will become "new dest")
          @sql_log << "UPDATE meeting_entries SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
          @sql_log << "UPDATE meeting_individual_results SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
          @sql_log << "UPDATE meeting_relay_results SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
          @sql_log << "UPDATE meeting_team_scores SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_affiliation_id=#{src_ta.id};"
          # Update source TA only at the end:
          @sql_log << "UPDATE team_affiliations SET updated_at=NOW(), team_id=#{@dest.id} WHERE id=#{src_ta.id};"
        end
      end
    end
    # rubocop:enable Layout/LineLength

    # Prepares the SQL text for the "Team update" phase involving all entities that have a
    # foreign key to the source Team ID.
    #
    # == Team is bound to:
    # - ComputedSeasonRanking   (#team_id)
    # - GoggleCup               (#team_id)
    # - IndividualRecord        (#team_id)
    # - Lap                     (#team_id)
    # - Meeting                 (#home_team_id)
    # - RelayLap                (#team_id)
    # - TeamAlias               (#team_id) (*)unique idx with team_id & name
    # - TeamLapTemplate         (#team_id)
    # - UserWorkshop            (#team_id)
    # - [Team]
    #
    def prepare_script_for_team_only_links # rubocop:disable Metrics/AbcSize
      @sql_log << "\r\n-- Team-only updates (source Team #{@source.id} |=> dest #{@dest.id}})"
      @sql_log << "UPDATE computed_season_rankings SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE goggle_cups SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE laps SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE meetings SET updated_at=NOW(), home_team_id=#{@dest.id} WHERE home_team_id=#{@source.id};"
      @sql_log << "UPDATE relay_laps SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE team_lap_templates SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      @sql_log << "UPDATE user_workshops SET updated_at=NOW(), team_id=#{@dest.id} WHERE team_id=#{@source.id};"
      # No interest in keeping duplicate aliases: (Also, unique index won't allow creating duplicates)
      @sql_log << "DELETE FROM team_aliases WHERE id=#{@source.id};"
      @sql_log << "DELETE FROM teams WHERE id=#{@source.id};"
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
