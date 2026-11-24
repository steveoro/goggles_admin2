# frozen_string_literal: true

module Ops
  #
  # = Ops::HealthRun
  #
  # One run of a data health check group for a season (ops DB, table 'health_runs'), written by Health::Runner.
  # Only the last KEPT_PER_GROUP rows per (season, group) are kept (see .prune!).
  #
  # == Attributes
  # - season_id (MySQL Season ID), group_key (one of GROUPS), trigger (one of TRIGGERS), status (one of STATUSES);
  # - check_versions (Hash check key => version), stamp (Health::Stamp digest of the season data, when computed);
  # - counts (Hash check key => { 'open' =>, 'new' =>, 'resolved' => }), findings_count, new_count, resolved_count;
  # - duration_ms, db_epoch (Ops::Setting.db_epoch at run time), error_message (failed runs), job_id;
  # - started_at, finished_at.
  #
  class HealthRun < ApplicationRecord
    self.table_name = 'health_runs'

    GROUPS = %w[meetings badges people results setup].freeze
    TRIGGERS = %w[scheduled manual post_commit catch_up after_operation].freeze
    STATUSES = %w[queued running succeeded failed skipped].freeze
    FINISHED_STATUSES = %w[succeeded failed skipped].freeze
    KEPT_PER_GROUP = 20

    validates :season_id, presence: true
    validates :group_key, inclusion: { in: GROUPS }
    validates :trigger, inclusion: { in: TRIGGERS }
    validates :status, inclusion: { in: STATUSES }

    scope :recent, -> { order(Arel.sql('COALESCE(finished_at, started_at, created_at) DESC'), id: :desc) }
    scope :for_season, ->(season_id) { where(season_id:) }
    scope :for_group, ->(group_key) { where(group_key: group_key.to_s) }
    scope :finished, -> { where(status: FINISHED_STATUSES) }
    scope :succeeded, -> { where(status: 'succeeded') }
    scope :failed, -> { where(status: 'failed') }
    scope :pending, -> { where(status: %w[queued running]) }

    class << self
      # Latest finished run per (season, group) among +scope+: Hash [season_id, group_key] => HealthRun.
      def latest_by_season_and_group(scope = all)
        ids = scope.finished.group(:season_id, :group_key).maximum(:id).values
        where(id: ids).index_by { |run| [run.season_id, run.group_key] }
      end

      # Last succeeded run of the group for the season (or nil).
      def last_succeeded(season_id:, group_key:)
        for_season(season_id).for_group(group_key).succeeded.order(id: :desc).first
      end

      # Deletes the oldest finished runs of the (season, group) beyond KEPT_PER_GROUP. Returns the deleted count.
      def prune!(season_id:, group_key:)
        keep_ids = for_season(season_id).for_group(group_key).order(id: :desc).limit(KEPT_PER_GROUP).pluck(:id)
        return 0 if keep_ids.size < KEPT_PER_GROUP

        for_season(season_id).for_group(group_key).finished.where.not(id: keep_ids).delete_all
      end
    end

    def succeeded? = status == 'succeeded'
    def failed? = status == 'failed'
    def skipped? = status == 'skipped'
    def finished? = FINISHED_STATUSES.include?(status)
    def pending? = %w[queued running].include?(status)

    # Time shown for the run: finished_at, else started_at, else created_at.
    def shown_at
      finished_at || started_at || created_at
    end
  end
end
