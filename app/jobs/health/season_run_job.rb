# frozen_string_literal: true

module Health
  #
  # = Health::SeasonRunJob
  #
  # Runs one data health check group for one season (Health::Runner), on the single-thread 'maintenance' worker.
  # Read-only on the primary DB: it writes only ops rows (Ops::HealthRun, Ops::HealthFinding).
  #
  # Enqueue it through .enqueue / .enqueue_season, which create the 'queued' Ops::HealthRun shown by the
  # health pages and skip a (season, group) that already has a pending run. Solid Queue discards a duplicate
  # enqueued meanwhile (same season and group). No retries: the next sweep catches up.
  #
  # Triggers: 'manual' (Re-run / Run all), 'post_commit' (after a Data-Fix commit), 'scheduled' / 'catch_up'
  # (Health::SweepJob), 'after_operation' (phase 11 operations).
  #
  class SeasonRunJob < ApplicationJob
    queue_as :maintenance

    limits_concurrency key: ->(season_id:, group:, **) { "health-#{season_id}-#{group}" }, to: 1, duration: 2.hours,
                       on_conflict: :discard

    # Lower runs first (Solid Queue): on-demand runs before the sweeps.
    PRIORITY_ON_DEMAND = 5
    PRIORITY_SWEEP = 10
    # A queued or running run older than this is considered dead (worker stopped, job discarded).
    STALE_AFTER = 3.hours

    class << self
      # Creates the queued Ops::HealthRun and enqueues the job. Returns the run, or nil when the ops DB is not
      # available or the (season, group) already has a pending run.
      #
      # == Params:
      # - season_id, group (Ops::HealthRun::GROUPS), trigger (Ops::HealthRun::TRIGGERS);
      # - skip_unchanged: see Health::Runner; priority: default PRIORITY_ON_DEMAND.
      def enqueue(season_id:, group:, trigger:, skip_unchanged: false, priority: PRIORITY_ON_DEMAND)
        return unless Ops.available?

        fail_stale_runs!
        return if Ops::HealthRun.for_season(season_id).for_group(group).pending.exists?

        run = Ops::HealthRun.create!(season_id:, group_key: group.to_s, trigger: trigger.to_s, status: 'queued',
                                     db_epoch: Ops::Setting.db_epoch)
        job = set(priority:).perform_later(season_id: season_id.to_i, group: group.to_s, trigger: trigger.to_s,
                                           run_id: run.id, skip_unchanged:)
        return mark_not_enqueued(run) unless job

        run.update!(job_id: job.job_id)
        Health::Notifier.ping
        run
      rescue StandardError => e
        mark_not_enqueued(run, e) if run
        raise
      end

      # Enqueues every group of the season (Health::SeasonScope#groups_for). Returns the Array of queued runs.
      def enqueue_season(season_id:, trigger:, scope: Health::SeasonScope.new, **options)
        scope.groups_for(season_id).filter_map { |group| enqueue(season_id:, group:, trigger:, **options) }
      end

      # Marks the queued/running runs older than STALE_AFTER as failed. Returns their count.
      def fail_stale_runs!(now: Time.current)
        stale = Ops::HealthRun.pending.where(created_at: ...(now - STALE_AFTER))
        stale.update_all(status: 'failed', finished_at: now, updated_at: now, # rubocop:disable Rails/SkipsModelValidations
                         error_message: I18n.t('health.runs.stale_error', locale: :en))
      end

      private

      def mark_not_enqueued(run, error = nil)
        run.update!(status: 'failed', finished_at: Time.current,
                    error_message: "not enqueued#{": #{error.class}: #{error.message}" if error}".truncate(2000))
        nil
      end
    end

    # == Params:
    # - season_id, group, trigger; run_id: the queued Ops::HealthRun (optional); skip_unchanged: see Health::Runner.
    # Returns the finished Ops::HealthRun (or nil).
    def perform(season_id:, group:, trigger: 'manual', run_id: nil, skip_unchanged: false)
      run = Ops.safely { Ops::HealthRun.find_by(id: run_id) } if run_id
      season = GogglesDb::Season.unscoped.find_by(id: season_id)
      unless season
        run&.update!(status: 'failed', finished_at: Time.current, error_message: "Season #{season_id} not found")
        return run
      end

      Health::Runner.new(season:, group:, trigger:, run:, job_id:, skip_unchanged:).call
    end
  end
end
