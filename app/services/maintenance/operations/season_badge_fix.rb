# frozen_string_literal: true

module Maintenance
  module Operations
    #
    # = Maintenance::Operations::SeasonBadgeFix ('season.badge_fix')
    #
    # Fixes the badges of a whole season, one step per run (Merge::SeasonBadgeFixer): the 'sure' duplicate merges
    # (step 1), then the relay-only badges (2) and the remaining relay badges (3); the 'possible' merges (step 0) only
    # with +include_possible+ AND a source team filter. The dry run shows the candidate counts of every step (after the
    # team filter), the step it applies, the per-badge plan and the badges deferred to the next run or failed. One
    # script per run (= per step), each badge in its own transaction inside the file.
    #
    # Without +src_team_id+ every candidate is processed (the former 'merge:season_fix' skipped them all). With
    # +dest_team_id+ a candidate whose destination is on that team is merged with force (else autofix).
    #
    # Long and cancellable: the progress is shown on the run page, "Cancel" stops the dry run (or the apply's re-plan)
    # at the next badge. Typed confirmation ("FIX SEASON <id>"). Fixes: badges.duplicate.sure and
    # badges.relay_category (the season of the finding). Suggests itself again while candidates are left.
    #
    class SeasonBadgeFix < Maintenance::Operation
      self.key = 'season.badge_fix'
      self.confirmation = :typed
      self.outbox_kind = 'merge'
      self.health_group = 'badges'
      self.fixes = %w[badges.duplicate.sure badges.relay_category].freeze
      self.bumps_db_generation = true
      self.cancellable = true

      MAX_LISTED = 200

      param :season_id, :integer, lookup: :season
      param :include_possible, :flag
      param :src_team_id, :integer, lookup: :team
      param :dest_team_id, :integer, lookup: :team

      validates :season_id, presence: true
      validate :team_filters

      attr_reader :fixer

      def self.params_from_finding(finding)
        { 'season_id' => finding.season_id || payload_of(finding)['season_id'] }
      end

      def self.season_wide? = true

      # A season-wide button: only on findings carrying their season.
      def self.offer_for?(finding)
        super && finding.season_id.present?
      end

      def file_base
        step = @fixer&.step
        return "season_fix_#{season_id}" unless step

        "season_fix_#{season_id}-step#{@fixer.step_number}-#{step}"
      end

      def subject = ['season', season_id]
      def typed_token = "FIX SEASON #{season_id}"

      def label
        return I18n.t('maintenance.operations.season_badge_fix.label_team', id: season_id, team: src_team_id) if src_team_id.present?

        I18n.t('maintenance.operations.season_badge_fix.label', id: season_id)
      end

      # This operation again (same params) while candidates are left (never chained).
      def follow_ups(plan)
        return [] if plan.blocked? || plan.empty? || !plan.summary['more_to_do']

        [{ 'operation_key' => key, 'params' => to_params }]
      end

      protected

      def build_plan
        season = GogglesDb::Season.find_by(id: season_id)
        return blank_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Season', id: season_id)]) unless season

        @fixer = Merge::SeasonBadgeFixer.new(season:, include_possible: flag?(:include_possible), src_team_id:, dest_team_id:,
                                             progress: ->(done, total, text) { report_progress(done, total, text) }).prepare
        blank_plan(subjects: [{ 'type' => 'season', 'id' => season.id }], summary: summary_for(season),
                   warnings: warnings_for, sql_lines: @fixer.sql_log)
      end

      private

      def team_filters
        errors.add(:dest_team_id, I18n.t('maintenance.operations.season_badge_fix.errors.dest_without_src')) if dest_team_id.present? && src_team_id.blank?
        return unless flag?(:include_possible) && src_team_id.blank?

        errors.add(:include_possible, I18n.t('maintenance.operations.season_badge_fix.errors.possible_without_team'))
      end

      def summary_for(season)
        {
          'season' => season.description, 'step' => @fixer.step&.to_s, 'step_number' => @fixer.step_number,
          'candidates' => @fixer.counts.transform_keys(&:to_s).compact, 'planned' => @fixer.planned.size,
          'deferred' => @fixer.deferred.size, 'failed' => @fixer.failed.size, 'more_to_do' => @fixer.more_to_do?,
          'badges' => @fixer.outcomes.first(MAX_LISTED).map(&:to_h), 'failures' => @fixer.failed.first(MAX_LISTED).map(&:to_h),
          'flags' => %w[include_possible].select { |name| flag?(name) }, 'src_team_id' => src_team_id, 'dest_team_id' => dest_team_id
        }.compact
      end

      def warnings_for
        list = []
        list << I18n.t('maintenance.operations.season_badge_fix.warnings.deferred', count: @fixer.deferred.size) if @fixer.deferred.any?
        list << I18n.t('maintenance.operations.season_badge_fix.warnings.failed', count: @fixer.failed.size) if @fixer.failed.any?
        list << I18n.t('maintenance.operations.season_badge_fix.warnings.possible') if flag?(:include_possible)
        list
      end
    end
  end
end
