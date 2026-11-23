# frozen_string_literal: true

module Health
  #
  # = Health::RunsController
  #
  # POST /health/runs: on-demand data health runs (trigger 'manual'), enqueued on the 'maintenance' worker:
  # - season_id + group: one group of a season ("Re-run" of a cell);
  # - season_id: every group of the season;
  # - all=1: every group of every season with data ("Run all"; queued at the sweep priority, so that a later single
  #   "Re-run" goes first).
  # A (season, group) with a pending run is skipped. Read-only checks: nothing else is written.
  #
  class RunsController < BaseController
    # POST /health/runs
    def create
      return redirect_back_with(:alert, t('health.runs.ops_unavailable')) unless ops_available?

      runs = enqueue_runs
      record_request_event(runs)
      redirect_back_with(:notice, runs.any? ? t('health.runs.queued', count: runs.size) : t('health.runs.nothing_queued'))
    rescue StandardError => e
      logger.error("[Health::RunsController] runs not queued: #{e.class}: #{e.message}")
      redirect_back_with(:alert, t('health.runs.failed', error: e.message))
    end

    private

    def enqueue_runs
      scope = Health::SeasonScope.new
      if params[:all] == '1'
        return scope.runnable.flat_map do |entry|
          Health::SeasonRunJob.enqueue_season(season_id: entry.season_id, trigger: 'manual', scope:,
                                              priority: Health::SeasonRunJob::PRIORITY_SWEEP)
        end
      end

      season_id = params[:season_id].to_i
      group = params[:group].presence
      if group
        return [] unless scope.groups_for(season_id).include?(group)

        return [Health::SeasonRunJob.enqueue(season_id:, group:, trigger: 'manual')].compact
      end

      Health::SeasonRunJob.enqueue_season(season_id:, trigger: 'manual', scope:)
    end

    def record_request_event(runs)
      return if runs.empty?

      season_ids = runs.map(&:season_id).uniq
      Ops.record_event!(
        kind: 'health.runs_requested', level: 'info', actor: 'operator', season_id: season_ids.one? ? season_ids.first : nil,
        subject_type: 'health', subject_key: params[:all] == '1' ? 'all' : season_ids.join(','),
        data: { 'runs' => runs.size, 'groups' => runs.map(&:group_key).uniq, 'seasons' => season_ids.size },
        link_path: season_ids.one? ? health_season_path(season_ids.first) : health_path
      )
    end

    def redirect_back_with(key, message)
      flash[key == :alert ? :error : :info] = message
      redirect_to(safe_return_path(health_path))
    end
  end
end
