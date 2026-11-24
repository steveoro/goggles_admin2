# frozen_string_literal: true

module Health
  module Checks
    #
    # = Health::Checks::Badges
    #
    # The 'badges' group: ONE Merge::BadgeSeasonChecker#run for the season (never #display_report), mapped to:
    # - badges.duplicate.sure: same swimmer, same team (or teams sharing a meeting) => error;
    # - badges.duplicate.possible: same swimmer, similar team names => warning;
    # - badges.relay_category: badge on a relay category => error;
    # - teams.possible_duplicates: similar team names (Jaro-Winkler >= Merge::BadgeSeasonChecker::DEFAULT_MATCH_BIAS)
    #   sharing a multi-badge swimmer => warning.
    #
    # The checker runs through QuietChecker, which skips the text log only (four private logging methods that
    # build the ANSI report lines and run extra queries for it): the analysis itself is unchanged.
    #
    class Badges < Base
      # Merge::BadgeSeasonChecker without its text log (same analysis, fewer queries; the relay-category log line
      # also raises when no individual category matches the swimmer's age).
      class QuietChecker < Merge::BadgeSeasonChecker
        private

        def log_stats; end
        def log_team_merge_candidates; end
        def log_badge_merge_candidates(*); end
        def compute_and_log_corrected_relay_only_categories; end
      end

      def call
        checker = QuietChecker.new(season:)
        checker.run
        @swimmers = load_swimmers(checker)
        badge_merge_findings('badges.duplicate.sure', 'error', checker.sure_badge_merges) +
          badge_merge_findings('badges.duplicate.possible', 'warning', checker.possible_badge_merges) +
          relay_findings(checker) + team_findings(checker)
      end

      private

      # { swimmer_id => [complete_name, year_of_birth] } for every swimmer involved.
      def load_swimmers(checker)
        ids = (checker.sure_badge_merges.keys + checker.possible_badge_merges.keys + checker.relay_badges.map(&:swimmer_id)).uniq
        GogglesDb::Swimmer.unscoped.where(id: ids).pluck(:id, :complete_name, :year_of_birth).to_h { |id, *rest| [id, rest] }
      end

      def badge_merge_findings(check_key, severity, merges)
        merges.map { |swimmer_id, badges| badge_merge_finding(check_key, severity, swimmer_id, badges.to_a.sort_by(&:id)) }
      end

      # (+list+: the badges of the swimmer, by id)
      def badge_merge_finding(check_key, severity, swimmer_id, list)
        name, year = @swimmers.fetch(swimmer_id, [nil, nil])
        ids = list.map(&:id)
        finding(check_key, severity:, subject_type: 'swimmer', subject_id: swimmer_id, subject_ids: ids,
                           identity: "swimmer:#{swimmer_id}|badges:#{id_list(ids)}",
                           title_args: { name: name || "##{swimmer_id}", year: year || '-', count: list.size },
                           payload: { 'swimmer_id' => swimmer_id, 'swimmer_name' => name, 'year_of_birth' => year,
                                      'same_team' => list.map(&:team_id).uniq.one?, 'badges' => list.map { |badge| badge_payload(badge) },
                                      'rake' => { 'src' => ids.second, 'dest' => ids.first } })
      end

      def relay_findings(checker)
        relay_only_ids = checker.relay_only_badges.map(&:id)
        checker.relay_badges.to_a.sort_by(&:id).map do |badge|
          name, year = @swimmers.fetch(badge.swimmer_id, [nil, nil])
          finding('badges.relay_category', severity: 'error', subject_type: 'badge', subject_id: badge.id, identity: "badge:#{badge.id}",
                                           title_args: { id: badge.id, name: name || "##{badge.swimmer_id}",
                                                         category: badge.category_type&.code.to_s },
                                           payload: badge_payload(badge).merge('swimmer_id' => badge.swimmer_id, 'swimmer_name' => name,
                                                                               'year_of_birth' => year,
                                                                               'relay_only' => relay_only_ids.include?(badge.id),
                                                                               'rake' => { 'src' => badge.id }))
        end
      end

      def team_findings(checker)
        checker.possible_team_merges.map do |teams|
          list = teams.uniq(&:id).sort_by(&:id)
          ids = list.map(&:id)
          finding('teams.possible_duplicates', severity: 'warning', subject_type: 'teams', subject_id: ids.first, subject_ids: ids,
                                               identity: "teams:#{id_list(ids)}",
                                               title_args: { names: list.map(&:name).join(' / ').truncate(120) },
                                               payload: { 'teams' => list.map do |team|
                                                 { 'id' => team.id, 'name' => team.name, 'editable_name' => team.editable_name }
                                               end,
                                                          'rake' => { 'src' => ids.second, 'dest' => ids.first } })
        end
      end

      def badge_payload(badge)
        { 'id' => badge.id, 'team_id' => badge.team_id, 'team_name' => badge.team&.name,
          'category_type_id' => badge.category_type_id, 'category_code' => badge.category_type&.code,
          'relay_category' => badge.category_type&.relay? || false }
      end
    end
  end
end
