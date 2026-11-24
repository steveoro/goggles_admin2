# frozen_string_literal: true

module Maintenance
  module Inspectors
    #
    # = Maintenance::Inspectors::SeasonBadges ('season.badges')
    #
    # The season badge analysis of 'check:season' (Merge::BadgeSeasonChecker#run, #display_report) with, when
    # +list_teams+ is set (or when there is no merge candidate at all, as the task did), the list of the possible and
    # sure merge candidates with their badges and teams. Read only: the preview of 'season.badge_fix' (the 'listed'
    # fact tells the rake caller whether the task stopped before the list).
    #
    class SeasonBadges < Maintenance::Inspector
      self.key = 'season.badges'

      param :season_id, :integer, lookup: :season
      param :list_teams, :flag

      validates :season_id, presence: true

      def self.params_from_finding(finding)
        { 'season_id' => finding.season_id }
      end

      def subject = ['season', season_id]
      def label = I18n.t('maintenance.operations.season_badges.label', id: season_id)

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        season = GogglesDb::Season.find_by(id: season_id)
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Season', id: season_id)]) unless season

        $stdout.puts('--> LIST TEAMS for sure & possible badge merges: ✔') if flag?(:list_teams)
        checker = Merge::BadgeSeasonChecker.new(season:)
        checker.run
        checker.display_report
        listed = flag?(:list_teams) || (checker.sure_badge_merges.blank? && checker.possible_badge_merges.blank?)
        list_candidates(checker) if listed
        report_plan(subjects: [{ 'type' => 'season', 'id' => season.id }],
                    summary: { 'sure_badge_merges' => checker.sure_badge_merges.size, 'possible_badge_merges' => checker.possible_badge_merges.size,
                               'relay_badges' => checker.relay_badges.size, 'relay_only_badges' => checker.relay_only_badges.size,
                               'listed' => listed })
      end

      private

      def list_candidates(checker) # rubocop:disable Metrics/AbcSize
        %i[possible_badge_merges sure_badge_merges].each do |method_name|
          $stdout.puts("\r\n\033[1;33;37m#{method_name.upcase} candidates w/ badge details:\033[0m (tot. #{checker.send(method_name).size})")
          $stdout.puts("#{'SWIMMER'.center(40)} #{'BADGE ID DETAILS'.center(90)}")
          checker.send(method_name).each do |swimmer_id, badge_list|
            deco_list = badge_list.map do |badge|
              "[\033[1;33;33m#{badge.id.to_s.rjust(6)}\033[0m, team #{badge.team_id.to_s.rjust(5)}: #{badge.team.name} / #{badge.category_type.code}]".ljust(90)
            end
            swimmer_name = GogglesDb::Swimmer.find(swimmer_id).complete_name
            $stdout.puts("- #{swimmer_id.to_s.rjust(5)}, #{swimmer_name.ljust(30)}#{deco_list.join(' ')}")
          end
        end
      end
    end
  end
end
