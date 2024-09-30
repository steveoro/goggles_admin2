# frozen_string_literal: true

module Merge
  #
  # = Merge::Swimmer
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20240930
  #
  class Swimmer
    attr_reader :sql_log, :checker, :source, :dest

    # Allows a source Swimmer to be merged into a destination one. All related entities
    # will be handled (badges, results, laps, ...).
    #
    # "Merging" implies moving all source data into the destination, so also the final source
    # columns values will usually become the new destination values (values from SOURCE/Master |=>
    # become new values for DESTINATION/Slave).
    # For this reason, use the dedicated parameter whenever the destination master row needs to
    # keep its columns untouched.
    #
    # More schematically:
    #
    #   [SOURCE] ------------------------> [DESTINATION]
    #   - to be purged (ID disappears)  /  - to be kept (ID remains)
    #   1. copies "master" column values into "slave" dest. values (overwritten)
    #   2. copies source sub-enties which are totally missing from dest.
    #   3. updates "shared" sub-enties which present some differences at any level of the hierarchy.
    #
    # While the first step is pretty straightforward, both the second and third steps
    # involve defining what is a "shared" sub-entity and what may make two rows similar or
    # overlapping for the specific entity we are trying to merge.
    #
    # In most cases, the merge is considered "unfeasible" (at least automatically) if
    # there are any shared/conflicting parent entities linked to any of the sub-entities involved,
    # so step 3. from above won't even happen.
    #
    # == Additional notes:
    # This merge class won't actually touch the DB: it will just prepare the script so
    # that this process can be replicated on any DB that is in sync with the current one.
    #
    # == Params
    # - <tt>:source</tt> => source Swimmer row, *required*
    # - <tt>:dest</tt>   => destination Swimmer row, *required*
    #
    # - <tt>:skip_columns</tt> => Force this to +true+ to avoid updating the destination row columns
    #   with the values stored in source; default: +false+.
    #
    def initialize(source:, dest:, skip_columns: false)
      raise(ArgumentError, 'Both source and destination must be Swimmers!') unless source.is_a?(GogglesDb::Swimmer) && dest.is_a?(GogglesDb::Swimmer)

      @skip_columns = skip_columns
      @checker = SwimmerChecker.new(source:, dest:)
      @source = @checker.source
      @dest = @checker.dest
      @sql_log = []
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the merge script inside a single transaction.
    def prepare
      result_ok = @checker.run
      @checker.display_report && return unless result_ok

      @checker.log << "\r\n\r\n- #{'Checker'.ljust(44, '.')}: OK"
      @sql_log << "\r\n-- Merge swimmer (#{@source.id}) #{@source.display_label} |=> (#{@dest.id}) #{@dest.display_label}-- \r\n"
      # NOTE: uncommenting the following in the output SQL may yield nulls for created_at & updated_at if we don't provide values in the row
      @sql_log << '-- SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";'
      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'
      @sql_log << ''

      prepare_script_for_badge_and_swimmer_links
      prepare_script_for_swimmer_only_links

      # Move any swimmer-only association too:
      @sql_log << "UPDATE individual_records SET updated_at=NOW(), swimmer_id=#{@dest.id} WHERE swimmer_id=#{@source.id};"
      @sql_log << "UPDATE users SET updated_at=NOW(), swimmer_id=#{@dest.id} WHERE swimmer_id=#{@source.id};"
      # Remove the source swimmer before making the destination columns a duplicate of it:
      @sql_log << "DELETE FROM swimmers WHERE id=#{@source.id};"

      # Overwrite all commonly used columns at the end, if requested (this will update the index too):
      unless @skip_columns
        @sql_log << "UPDATE swimmers SET updated_at=NOW(), last_name=\"#{@source.last_name}\", first_name=\"#{@source.first_name}\", year_of_birth=#{@source.year_of_birth},"
        @sql_log << "  complete_name=\"#{@source.complete_name}\", nickname=\"#{@source.nickname || 'NULL'}\","
        @sql_log << "  associated_user_id=#{@source.associated_user_id || 'NULL'}, gender_type_id=#{@source.gender_type_id}, year_guessed=#{@source.year_guessed} WHERE id=#{@dest.id};\r\n"
      end

      @sql_log << ''
      @sql_log << 'COMMIT;'

      # FUTUREDEV: *** Cups & Records ***
      # - IndividualRecord: TODO, missing model (but table is there, links both team & swimmer)
      # - SeasonPersonalStandard: currently used only in old CSI meetings and not used nor updated anymore
      # - GoggleCupStandard: TODO
    end
    #-- ------------------------------------------------------------------------
    #++

    # Returns the <tt>#log</tt> array from the internal SwimmerChecker instance.
    def log
      @checker.log
    end

    # Returns the <tt>#errors</tt> array from the internal SwimmerChecker instance.
    def errors
      @checker.errors
    end

    # Returns the <tt>#warnings</tt> array from the internal SwimmerChecker instance.
    def warnings
      @checker.warnings
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    # Prepares the SQL text for the "Badge update" phase involving all entities that have a
    # foreign key to the source swimmer's Badge.
    def prepare_script_for_badge_and_swimmer_links
      return if @checker.src_only_badges.blank? && @checker.shared_badges.blank?

      # Entities names implied in a badge IDs update (+ swimmer_id):
      tables_with_badge = %w[
        meeting_entries meeting_event_reservations meeting_individual_results
        meeting_relay_reservations meeting_relay_swimmers meeting_reservations
      ]

      if @checker.src_only_badges.present?
        @checker.log << "- #{'Updates for Badges (badge_id + swimmer_id)'.ljust(44, '.')}: #{@checker.src_only_badges.count}"
        @checker.log << "- #{'Updates for MeetingIndividualResults'.ljust(44, '.')}: #{@checker.src_only_mirs.count}" if @checker.src_only_mirs.present?
        @checker.log << "- #{'Updates for MeetingRelaySwimmers'.ljust(44, '.')}: #{@checker.src_only_mrss.count}" if @checker.src_only_mrss.present?
        @checker.log << "- #{'Updates for MeetingEntries'.ljust(44, '.')}: #{@checker.src_only_mes.count}" if @checker.src_only_mes.present?
        @checker.log << "- #{'Updates for MeetingReservations'.ljust(44, '.')}: #{@checker.src_only_mres.count}" if @checker.src_only_mres.present?
        @checker.log << "- #{'Updates for MeetingEventReservations'.ljust(44, '.')}: #{@checker.src_only_mev_res.count}" if @checker.src_only_mev_res.present?
        @checker.log << "- #{'Updates for MeetingRelayReservations'.ljust(44, '.')}: #{@checker.src_only_mrel_res.count}" if @checker.src_only_mrel_res.present?
        @sql_log << '-- [Source-only badges updates:]'
        # Move ownership to dest.row:
        @sql_log << "UPDATE badges SET updated_at=NOW(), swimmer_id=#{@dest.id}"
        @sql_log << "  WHERE id IN (#{@checker.src_only_badges.join(', ')});\r\n"

        # Update also swimmer_id in sub-entities:
        tables_with_badge.each do |sub_entity|
          @sql_log << "UPDATE #{sub_entity} SET updated_at=NOW(), swimmer_id=#{@dest.id} WHERE badge_id IN (#{@checker.src_only_badges.join(', ')});"
        end
        @sql_log << '' # empty line separator every badge update
      end
      return if @checker.shared_badges.blank?

      @checker.log << "- #{'Badges to be updated and DELETED'.ljust(44, '.')}: #{@checker.shared_badges.count}"
      @sql_log << '-- [Shared badges:]'
      # For each sub-entity linked to a SHARED source badge (key), move it to the destination
      # swimmer and badge ID (value):
      @checker.shared_badges.each do |src_badge_id, dest_badge_id|
        tables_with_badge.each do |sub_entity|
          @sql_log << "UPDATE #{sub_entity} SET updated_at=NOW(), swimmer_id=#{@dest.id}, badge_id=#{dest_badge_id} " \
                      "WHERE badge_id=#{src_badge_id};"
        end
        @sql_log << '' # empty line separator every badge update
      end
      @sql_log << ''

      # Delete source shared badges (keys) after sub-entity update:
      @sql_log << "DELETE FROM badges WHERE id IN (#{@checker.shared_badges.keys.join(', ')});"
    end
    #-- ------------------------------------------------------------------------
    #++

    # Prepares the SQL text for the "Swimmer-only" update phase involving all entities that have a
    # foreign key to Badge.
    def prepare_script_for_swimmer_only_links
      # Entities implied in a swimmer_id-only update:
      [
        GogglesDb::Lap, GogglesDb::RelayLap, GogglesDb::UserResult, GogglesDb::UserLap
        # GogglesDb::IndividualRecord TODO
      ].each do |entity|
        next unless entity.exists?(swimmer_id: @source.id)

        @checker.log << "- Updates for #{entity.name.split('::').last.ljust(32, '.')}: #{entity.where(swimmer_id: @source.id).count}"
        @sql_log << "UPDATE #{entity.table_name} SET updated_at=NOW(), swimmer_id=#{@dest.id} WHERE swimmer_id=#{@source.id};"
      end
    end
    #-- ------------------------------------------------------------------------
    #++
  end
end
