# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::BadgeSwimmerFix ('badge.swimmer_fix')
    #
    # Fixes a wrongly assigned swimmer on one or more badges (results, laps, relay swimmers, entries and reservations)
    # with the exact calls of 'fix:swimmer_in_badge':
    #   Merge::SwimmerInBadge.new(badges:, new_swimmer:)#display_report, #prepare, #sql_log
    # #prepare raises after printing its report again when the new swimmer already has a badge for the same team and
    # season (a badge merge is needed instead): the plan is then blocked. Confirmation: the checkbox.
    #
    class BadgeSwimmerFix < Maintenance::Operation
      self.key = 'badge.swimmer_fix'
      self.confirmation = :confirm
      self.outbox_kind = 'fix'
      self.health_group = 'badges'
      self.fixes = [].freeze
      self.bumps_db_generation = true

      param :badge_ids, :string, lookup: :badge
      param :swimmer_id, :integer, lookup: :swimmer

      validates :badge_ids, :swimmer_id, presence: true

      attr_reader :fixer

      def self.params_from_finding(_finding) = {}

      def badge_id_list = badge_ids.to_s.split(',').map { |id| id.strip.to_i }.reject(&:zero?)

      def file_base = "fix_swimmer_in_badge-#{found_badges.map(&:id).join('-')}"
      def season_id = found_badges.map(&:season_id).uniq.then { |ids| ids.size == 1 ? ids.first : nil }
      def subject = ['badge', badge_id_list.first]
      def label = I18n.t('maintenance.operations.badge_swimmer_fix.label', badges: badge_id_list.join(', '), swimmer: swimmer_id)

      def found_badges
        @found_badges ||= badge_id_list.filter_map { |id| GogglesDb::Badge.find_by(id:) }
      end

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        return blank_plan(errors: [I18n.t('maintenance.operations.badge_team_fix.errors.no_badges')]) if found_badges.empty?

        new_swimmer = GogglesDb::Swimmer.find_by(id: swimmer_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Swimmer', id: swimmer_id)]) unless new_swimmer

        @fixer = Merge::SwimmerInBadge.new(badges: found_badges, new_swimmer:)
        @fixer.display_report
        @fixer.prepare
        blank_plan(subjects: found_badges.map { |badge| { 'type' => 'badge', 'id' => badge.id } } + [{ 'type' => 'swimmer', 'id' => new_swimmer.id }],
                   summary: { 'badges' => found_badges.map(&:id), 'new_swimmer' => new_swimmer.complete_name,
                              'mirs' => @fixer.affected_mirs.count, 'mrss' => @fixer.affected_mrss.count },
                   sql_lines: @fixer.sql_log)
      end
    end
  end
end
