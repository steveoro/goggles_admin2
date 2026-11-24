# frozen_string_literal: true

require 'kaminari'

module Maintenance
  module Inspectors
    #
    # = Maintenance::Inspectors::MapTeamBadges ('team.map_badges')
    #
    # The map of 'check:map_team_badges': for each badge of a team in a season (10 per page), the categories and teams
    # of the swimmer in the latest seasons (Merge::BadgeChecker.map_categories_x_seasons). Read only. The 'stopped'
    # fact tells the rake caller that the task stopped early (no badge, or an empty page).
    #
    class MapTeamBadges < Maintenance::Inspector
      self.key = 'team.map_badges'

      PER_PAGE = 10

      param :season_id, :integer, lookup: :season
      param :team_id, :integer, lookup: :team
      param :page

      validates :season_id, :team_id, presence: true

      def self.params_from_finding(_finding) = {}

      def subject = ['team', team_id]
      def label = I18n.t('maintenance.operations.team_map_badges.label', team: team_id, season: season_id)

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        season = GogglesDb::Season.find_by(id: season_id)
        team = GogglesDb::Team.find_by(id: team_id)
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Season', id: season_id)]) unless season
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: team_id)]) unless team

        page_idx = page.to_i
        badges = GogglesDb::Badge.where(season_id: season.id, team_id: team.id)
        $stdout.puts("\r\n--> Found #{badges.size} badges => showing page #{page_idx} (/#{(badges.size / PER_PAGE) - 1})")
        badges_page = badges.empty? ? [] : Kaminari.paginate_array(badges).page(page_idx).per(PER_PAGE)
        return report_plan(summary: { 'badges' => badges.size, 'stopped' => true }) if badges_page.empty?

        GogglesDb::BadgeDecorator.decorate_collection(badges_page).each { |badge| print_badge(season, badge) }
        report_plan(subjects: [{ 'type' => 'team', 'id' => team.id }], summary: { 'badges' => badges.size, 'stopped' => false })
      end

      private

      def print_badge(season, badge)
        categories_x_seasons = Merge::BadgeChecker.map_categories_x_seasons(season.season_type_id, badge.swimmer_id)
        curr_hash = categories_x_seasons.find { |h| h[:season_id] == season.id }
        Merge::BadgeChecker.badge_report_header(
          src_badge: badge,
          computed_category_type_id: curr_hash[:computed_category_type_id],
          computed_category_type_code: curr_hash[:computed_category_type_code]
        ).each { |header_line| $stdout.puts(header_line) }

        categories_x_seasons.map { |categories_map| $stdout.puts(Merge::BadgeChecker.decorate_categories_map(categories_map)) }
      end
    end
  end
end
