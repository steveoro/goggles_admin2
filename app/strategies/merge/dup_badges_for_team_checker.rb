# frozen_string_literal: true

module Merge
  # = Merge::DupBadgesForTeamChecker
  #
  #   - version:  7-0.8.40
  #   - author:   Steve A.
  #   - build:    20260503
  #
  # Checks for swimmers that have ever had a badge associated to a specific team
  # and identifies which of those swimmers have duplicate badges in any season
  # (across any team).
  #
  # For each flagged swimmer, reports all badge rows across all seasons ordered
  # by season_id, badge_id with MIR counts.
  #
  # == Usage:
  #   checker = Merge::DupBadgesForTeamChecker.new(team: team)
  #   checker.run
  #   checker.display_report
  #
  class DupBadgesForTeamChecker
    attr_reader :team, :report_data, :log

    # Initializes the checker with the target team.
    #
    # == Params:
    # - <tt>:team</tt> => target Team row, *required*
    #
    def initialize(team:)
      raise(ArgumentError, 'Invalid Team!') unless team.is_a?(GogglesDb::Team)

      @team = team
      @log = []
      @report_data = {}
    end

    # Runs the analysis and populates report_data.
    # Returns self.
    #
    # report_data structure:
    # {
    #   swimmer_id => {
    #     swimmer_label: String,
    #     badges: [
    #       {
    #         season_id: Integer,
    #         badge_id: Integer,
    #         team_id: Integer,
    #         team_affiliation_id: Integer,
    #         team_name: String,
    #         mir_count: Integer
    #       },
    #       ...
    #     ]
    #   },
    #   ...
    # }
    def run # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
      @log << "Checking for duplicate badges among swimmers associated with team #{@team.id} (#{@team.name})"

      # Step 1: Find all swimmers that have ever had a badge on the target team
      swimmer_ids = GogglesDb::Badge.where(team_id: @team.id).pluck(:swimmer_id).uniq

      @log << "Found #{swimmer_ids.size} swimmers with badges on team #{@team.id}"

      return self if swimmer_ids.empty?

      # Step 2: Identify swimmers with duplicate badges in any season (count > 1)
      # This is team-agnostic: any swimmer with >1 badge in a season is flagged
      dup_swimmer_ids = GogglesDb::Badge
                        .select('badges.swimmer_id, badges.season_id, COUNT(*) as badge_count')
                        .where(swimmer_id: swimmer_ids)
                        .group('badges.swimmer_id, badges.season_id')
                        .having('COUNT(*) > 1')
                        .pluck(:swimmer_id)
                        .uniq

      @log << "Found #{dup_swimmer_ids.size} swimmers with duplicate badges in some season(s)"

      return self if dup_swimmer_ids.empty?

      # Step 3: For each flagged swimmer, collect ALL badges across ALL seasons
      # Precompute MIR counts to avoid N+1
      all_badge_ids_for_swimmers = GogglesDb::Badge
                                   .where(swimmer_id: dup_swimmer_ids)
                                   .pluck(:id)

      mir_counts_by_badge = GogglesDb::MeetingIndividualResult
                            .where(badge_id: all_badge_ids_for_swimmers)
                            .group(:badge_id)
                            .count

      # Build report data
      dup_swimmer_ids.each do |swimmer_id|
        # Get the swimmer from any of their badges
        swimmer = GogglesDb::Badge.where(swimmer_id:).first&.swimmer
        next unless swimmer

        badges = GogglesDb::Badge
                 .includes(:team, :team_affiliation)
                 .where(swimmer_id:)
                 .order(:season_id, :id)

        badge_rows = badges.map do |badge|
          {
            season_id: badge.season_id,
            badge_id: badge.id,
            team_id: badge.team_id,
            team_affiliation_id: badge.team_affiliation_id || 0,
            team_name: badge.team.name,
            mir_count: mir_counts_by_badge[badge.id] || 0
          }
        end

        @report_data[swimmer_id] = {
          swimmer_label: "#{swimmer.complete_name} (ID: #{swimmer.id})",
          badges: badge_rows
        }
      end

      @log << "Report data prepared for #{@report_data.size} swimmers"
      self
    end

    # Outputs the report to stdout as a table grouped by swimmer.
    # rubocop:disable Rails/Output, Metrics/AbcSize
    def display_report
      puts @log.join("\n")
      puts ''

      if @report_data.empty?
        puts 'No swimmers with duplicate badges found.'
        return
      end

      # Table header
      header = 'season_id  badge_id   team_id    team_affiliation_id  team.name                                mir_count'
      puts '_' * header.length
      puts header
      puts '_' * header.length

      @report_data.each_value do |data|
        puts ''
        puts "Swimmer: #{data[:swimmer_label]}"
        puts '=' * header.length

        previous_season_id = nil
        data[:badges].each do |badge|
          # Add separator when season changes
          puts '-' * header.length if previous_season_id && badge[:season_id] != previous_season_id

          puts format('%<season_id>-10d %<badge_id>-10d %<team_id>-10d %<team_affiliation_id>-20d %<team_name>-40s %<mir_count>d',
                      season_id: badge[:season_id],
                      badge_id: badge[:badge_id],
                      team_id: badge[:team_id],
                      team_affiliation_id: badge[:team_affiliation_id],
                      team_name: badge[:team_name][0, 40],
                      mir_count: badge[:mir_count])

          previous_season_id = badge[:season_id]
        end
      end

      puts ''
      puts "Total swimmers with duplicates: #{@report_data.size}"
      nil
    end
    # rubocop:enable Rails/Output, Metrics/AbcSize
  end
end
