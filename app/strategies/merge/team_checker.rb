# frozen_string_literal: true

module Merge
  # = Merge::TeamChecker
  #
  #   - version:  7-0.7.19
  #   - author:   Steve A.
  #   - build:    20241011
  #
  # Check the feasibility of merging the Team entities specified in the constructor while
  # also gathering all sub-entities that need to be moved or purged.
  #
  # Contrary to other "checker" classes, the TeamChecker does not halt in case of conflicts.
  # After calling #run, use #shared_badge_couples_by_season and #orphan_src_badges_by_season
  # to retrieve the badge data needed by Merge::Team for inline badge merging.
  #
  class TeamChecker # rubocop:disable Metrics/ClassLength
    attr_reader :log, :source, :dest,
                :src_season_ids, :dest_season_ids,
                :overall_season_ids, :shared_season_ids,
                :shared_badge_couples # (= Merge::Badge candidates)

    unless defined? INVOLVED_ENTITIES
      INVOLVED_ENTITIES = [
        GogglesDb::Badge,
        GogglesDb::ComputedSeasonRanking,
        GogglesDb::GoggleCup,
        GogglesDb::IndividualRecord,
        GogglesDb::Lap,
        # GogglesDb::ManagedAffiliation, # (team_affiliation_id only)
        GogglesDb::MeetingEntry,
        GogglesDb::MeetingEventReservation,
        GogglesDb::MeetingReservation,
        GogglesDb::MeetingRelayReservation,
        GogglesDb::MeetingIndividualResult,
        GogglesDb::MeetingRelayResult,
        GogglesDb::MeetingTeamScore,
        # GogglesDb::Meeting, # (home_team_id)
        GogglesDb::RelayLap,
        GogglesDb::TeamAffiliation,
        # GogglesDb::TeamAlias, (??? 'data_import_team_aliases' for Admin2? It's there in the test DB)
        GogglesDb::TeamLapTemplate,
        GogglesDb::UserWorkshop
      ].freeze
    end
    #-- -----------------------------------------------------------------------
    #++

    # Checks Team merge feasibility while collecting all involved entity IDs.
    #
    # == Attributes:
    # - <tt>#log</tt> => analysis log (array of string lines)
    #
    # == Params:
    # - <tt>:source</tt> => source Team row, *required*
    # - <tt>:dest</tt> => destination Team row, *required*
    #
    def initialize(source:, dest:)
      raise(ArgumentError, 'Both source and destination must be Teams!') unless source.is_a?(GogglesDb::Team) && dest.is_a?(GogglesDb::Team)
      raise(ArgumentError, 'Identical source and destination!') if source.id == dest.id

      @source = source.decorate
      @dest = dest.decorate
      @log = []
      @src_entities = {}  # format: { entity.to_s => [relation_of_entity_rows] }
      @dest_entities = {} # (format as above)

      @src_season_ids = src_entities(GogglesDb::TeamAffiliation).pluck(:season_id).uniq.sort
      @dest_season_ids = dest_entities(GogglesDb::TeamAffiliation).pluck(:season_id).uniq.sort
      @overall_season_ids = @src_season_ids.union(@dest_season_ids).sort
      @shared_season_ids = @src_season_ids.intersection(@dest_season_ids).sort
    end
    #-- ------------------------------------------------------------------------
    #++

    # Launches the analysis process for merge feasibility while also collecting the IDs
    # and the rows needed for the merge. (It's useless to run this method more than once.)
    # *This process does not alter the database.*
    #
    def run
      return if @log.present? # Prevent running the analysis more than once

      @log << "\r\n[src: '#{@source.display_label}', id #{@source.id}] |=> [dest: '#{@dest.display_label}', id #{@dest.id}]"
      # Collect all entity rows for the source and destination teams for later use
      # and log the analysis:
      log_seasons_distribution
      log_swimmer_distribution
      log_entity_rows_count

      log_badge_merge_candidates
      nil
    end
    #-- ------------------------------------------------------------------------
    #++

    # Creates and outputs to stdout a detailed report of the entities involved in merging
    # the source into the destination as an ASCII table for quick reference.
    # rubocop:disable Rails/Output
    def display_report
      puts(@log.join("\r\n"))
      nil
    end
    # rubocop:enable Rails/Output
    #-- ------------------------------------------------------------------------
    #++

    # Returns the memoized result of the ActiveRecord Relation of the entity rows bound
    # by the source Team ID (or an empty collection when none are found).
    #
    # == Params:
    # - entity: the Class of the entity to search for.
    def src_entities(entity)
      return @src_entities[entity.to_s] if @src_entities.key?(entity.to_s)

      @src_entities[entity.to_s] = entity.where(team_id: @source.id)
    end

    # Returns the memoized result of the ActiveRecord Relation of the entity rows bound
    # by the destination Team ID (or an empty collection when none are found).
    #
    # == Params:
    # - entity: the Class of the entity to search for.
    def dest_entities(entity)
      return @dest_entities[entity.to_s] if @dest_entities.key?(entity.to_s)

      @dest_entities[entity.to_s] = entity.where(team_id: @dest.id)
    end

    # Returns the count of the swimmer_ids for the specified season ID on the base domain.
    # == Params:
    # - domain: ActiveRecord Relation domain to be filtered by season.
    # - season_id: the Season ID for the WHERE condition.
    def count_swimmers_for(domain, season_id)
      domain.where(season_id:).pluck(:swimmer_id).uniq.count
    end

    # Returns shared_badge_couples grouped by season_id.
    # Requires #run to have been called first.
    #
    # == Returns:
    # Hash { season_id => [[src_badge, dest_badge], ...] }
    #
    def shared_badge_couples_by_season
      return {} if @shared_badge_couples.blank?

      @shared_badge_couples_by_season ||= @shared_badge_couples.group_by { |couple| couple.first.season_id }
    end

    # Returns source badges that have no destination counterpart for the same swimmer
    # in the same season, grouped by season_id. These badges only need a team_id /
    # team_affiliation_id update (no merge).
    # Requires #run to have been called first.
    #
    # == Returns:
    # Hash { season_id => [badge, ...] }
    #
    def orphan_src_badges_by_season
      @orphan_src_badges_by_season ||= compute_orphan_src_badges
    end
    #-- ------------------------------------------------------------------------
    #++

    private

    # Logs a table showing which seasons are present in both the source and destination
    # teams for the involved Badges / TeamAffiliations.
    def log_seasons_distribution
      @log << "\r\nShared @overall_season_ids: #{@shared_season_ids.inspect} (both Badges & TeamAffiliations)"
      @log << "\r\nSeason | #{@overall_season_ids.map { |season_id| format('%4d', season_id) }.join(' | ')}"
      @log << "-------#{'+------' * @overall_season_ids.size}"
      @log << "source | #{@overall_season_ids.map { |season_id| @src_season_ids.include?(season_id) ? '   ✔' : '    ' }.join(' | ')}"
      @log << "dest.  | #{@overall_season_ids.map { |season_id| @dest_season_ids.include?(season_id) ? '   ✔' : '    ' }.join(' | ')}"
      @log << "-------#{'-------' * @overall_season_ids.size}"
    end

    # Logs swimmer distribution for each season, comparing source & destination teams.
    # The 'shared' section shows the distribution of swimmer IDs that are shared between
    # both the source & destination teams for the involved Badges / TeamAffiliations.
    def log_swimmer_distribution # rubocop:disable Metrics/AbcSize
      @log << 'Swimmers x Season:'
      # Detect *overall* intersection of source & destination swimmer IDs:
      src_swimmer_ids = src_entities(GogglesDb::Badge).pluck(:swimmer_id).uniq
      dest_swimmer_ids = dest_entities(GogglesDb::Badge).pluck(:swimmer_id).uniq
      shared_swimmer_ids = src_swimmer_ids.intersection(dest_swimmer_ids)

      @log << "source | #{@overall_season_ids.map do |season_id|
        @src_season_ids.include?(season_id) ? format('%4d', count_swimmers_for(src_entities(GogglesDb::Badge), season_id)) : '    '
      end.join(' | ')} => #{format('%5d', src_swimmer_ids.count)} *unique* swimmer_ids (overall, among all seasons)"
      @log << "dest.  | #{@overall_season_ids.map do |season_id|
        @dest_season_ids.include?(season_id) ? format('%4d', count_swimmers_for(dest_entities(GogglesDb::Badge), season_id)) : '    '
      end.join(' | ')} => #{format('%5d', dest_swimmer_ids.count)} *unique* swimmer_ids"
      @log << "-------#{'-------' * @overall_season_ids.size}"
      @log << "shared | #{@overall_season_ids.map do |season_id|
        @shared_season_ids.include?(season_id) ? format('%4d', count_shared_swimmers_for(season_id)) : '    '
      end.join(' | ')} => #{format('%5d', shared_swimmer_ids.count)} *unique & shared* swimmer_ids"
      @log << "-------#{'-------' * @overall_season_ids.size}"
    end

    # Returns the count of the *shared* swimmer_ids for the specified season ID on
    # both source & destination domains.
    #
    # Additionally, at the same time, this method collects all the shared Badges for the specified season that
    # can be merged together. (So it shouldn't be run more than once per season.)
    #
    # == Params:
    # - season_id: the Season ID for the WHERE condition.
    #
    # == Returns:
    # The shared swimmer (as unique IDs) count.
    # Updates the internal @shared_badge_couples array.
    #
    def count_shared_swimmers_for(season_id)
      # Detect intersection x season of source & destination swimmer IDs:
      src_swimmer_ids = src_entities(GogglesDb::Badge).where(season_id:).pluck(:swimmer_id).uniq
      dest_swimmer_ids = dest_entities(GogglesDb::Badge).where(season_id:).pluck(:swimmer_id).uniq
      shared_swimmer_ids = src_swimmer_ids.intersection(dest_swimmer_ids)

      @shared_badge_couples ||= []
      # Add the shared Badges in couples (source, dest.) to get a list of Merge::Badge candidates couples:
      # WARNING:
      # - only the first badge for each swimmer & season is considered;
      #   => additional duplicate badges (x season) won't be dealt with.
      @shared_badge_couples += shared_swimmer_ids.map do |swimmer_id|
        [
          GogglesDb::Badge.where(swimmer_id:, season_id:, team_id: @source.id).first,
          GogglesDb::Badge.where(swimmer_id:, season_id:, team_id: @dest.id).first
        ]
      end
      shared_swimmer_ids.count
    end
    #-- ------------------------------------------------------------------------
    #++

    # Logs the shared Badges that will need to be merged together after the team merge.
    #
    # These are the Badges associated to the 'unique & shared' swimmer_ids found
    # in the intersection of source & destination Badges / TeamAffiliations.
    #
    # The output on the log displays a line for each couple of badge to be processed
    # and the total number of couples at the end.
    def log_badge_merge_candidates
      return if @shared_badge_couples.blank?

      @log << "\r\nThe 'unique & shared' swimmer_ids from shared Badges/TeamAffiliations will yield several duplicated rows after the merge."
      @log << "Please check the following Merge::Badge candidate couples after the team merge:\r\n"
      @shared_badge_couples.each do |badge_couple|
        b1 = badge_couple.first
        b2 = badge_couple.last
        @log << "- Season #{b1.season_id}: [SRC] Badge #{b1.id}, cat. #{b1.category_type_id} |=> [DEST] Badge #{b2.id}, cat. #{b1.category_type_id} / " \
                "Swimmer #{format('%5d', b1.swimmer_id)} #{b1.swimmer.complete_name}"
      end
      @log << "\r\nTot. shared Swimmer IDs: #{@shared_badge_couples.count}"
    end

    # Computes orphan source badges (no dest counterpart for the same swimmer+season).
    def compute_orphan_src_badges
      result = {}
      shared_ids_by_season = shared_badge_couples_by_season.transform_values do |couples|
        couples.map { |c| c.first.swimmer_id }.uniq
      end

      @src_season_ids.each do |season_id|
        shared_ids = shared_ids_by_season[season_id] || []
        orphans = src_entities(GogglesDb::Badge).where(season_id:)
        orphans = orphans.where.not(swimmer_id: shared_ids) if shared_ids.present?
        result[season_id] = orphans.to_a if orphans.exists?
      end
      result
    end

    def log_entity_rows_count
      @log << "\r\nOverall sub-entity rows involved (src / dest):"
      INVOLVED_ENTITIES.each do |entity|
        @log << "- #{format('%25s', entity.to_s.split('::').last)}: " \
                "#{format('%5d', src_entities(entity).count)} / " \
                "#{format('%5d', dest_entities(entity).count)}"
      end
    end
  end
end
