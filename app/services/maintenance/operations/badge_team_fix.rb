# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::BadgeTeamFix ('badge.team_fix')
    #
    # Fixes a wrongly assigned team on one or more badges (results, laps, relay results updated; entries and
    # reservations deleted) with the exact calls of 'fix:team_in_badge':
    #   Merge::TeamInBadge.new(badges:, new_team:, nuke_team:)#display_report, #prepare, #sql_log
    # #prepare raises after printing its report again when a swimmer already has a badge on the new team (a badge merge
    # is needed instead): the plan is then blocked with that message. The printed reports are the console.
    # Confirmation: the checkbox; typed ("NUKE TEAM <team id>") with +nuke_team+ (it may reassign every row linked to a
    # reused team affiliation, not only the given badges).
    #
    class BadgeTeamFix < Maintenance::Operation
      self.key = 'badge.team_fix'
      self.confirmation = :confirm
      self.outbox_kind = 'fix'
      self.health_group = 'badges'
      self.fixes = [].freeze
      self.bumps_db_generation = true

      param :badge_ids, :string, lookup: :badge
      param :team_id, :integer, lookup: :team
      param :nuke_team, :flag

      validates :badge_ids, :team_id, presence: true

      attr_reader :fixer

      def self.params_from_finding(_finding) = {}

      # The badge ids of the comma-separated list (zeros and blanks dropped).
      def badge_id_list = badge_ids.to_s.split(',').map { |id| id.strip.to_i }.reject(&:zero?)

      def file_base = "fix_team_in_badge-#{found_badges.map(&:id).join('-')}"
      def season_id = found_badges.map(&:season_id).uniq.then { |ids| ids.size == 1 ? ids.first : nil }
      def subject = ['badge', badge_id_list.first]
      def label = I18n.t('maintenance.operations.badge_team_fix.label', badges: badge_id_list.join(', '), team: team_id)
      def typed_token = flag?(:nuke_team) ? "NUKE TEAM #{team_id}" : nil
      def confirmation_for(_plan) = flag?(:nuke_team) ? :typed : :confirm

      # The existing badges of the list, in list order.
      def found_badges
        @found_badges ||= badge_id_list.filter_map { |id| GogglesDb::Badge.find_by(id:) }
      end

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        return blank_plan(errors: [I18n.t('maintenance.operations.badge_team_fix.errors.no_badges')]) if found_badges.empty?

        new_team = GogglesDb::Team.find_by(id: team_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Team', id: team_id)]) unless new_team

        @fixer = Merge::TeamInBadge.new(badges: found_badges, new_team:, nuke_team: flag?(:nuke_team))
        @fixer.display_report
        @fixer.prepare
        blank_plan(subjects: found_badges.map { |badge| { 'type' => 'badge', 'id' => badge.id } } + [{ 'type' => 'team', 'id' => new_team.id }],
                   summary: { 'badges' => found_badges.map(&:id), 'new_team' => new_team.name, 'nuke_team' => flag?(:nuke_team),
                              'mirs' => @fixer.affected_mirs.count, 'mrrs' => @fixer.affected_mrrs.count },
                   warnings: flag?(:nuke_team) ? [I18n.t('maintenance.operations.badge_team_fix.warnings.nuke')] : [],
                   sql_lines: @fixer.sql_log)
      end
    end
  end
end
