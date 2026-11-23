# frozen_string_literal: true

#
# = DashboardController
#
# The landing page (root): an inbox-first dashboard. #index renders only the page layout; each zone is a Turbo frame
# loaded on its own (and reloaded live by live_frames_controller.js):
# - needs_you:       the inbox (Inbox::Builder over the Inbox::Registry sources), one primary action per item;
# - in_progress:     Season board crawls/extractions and Solid Queue jobs queued or running, next scheduled runs;
# - season_progress: the Season board state counts (stored board summary);
# - system_status:   one row per SystemStatus probe;
# - activity_feed:   the latest Ops::Event rows (the full list is #activity_log, /activity);
# - kpis:            the four API counters from the KpiRefreshJob snapshot;
# - health:          the data health card (open errors of the board season and of the other seasons, last sweep).
#
# Nothing here calls the API: remote values come only from the ops snapshots written by the jobs, so the page
# renders in an API-offline session too (every action is allowed there). The only writes are the operator's
# clicks: refresh_kpis (enqueues KpiRefreshJob), discard_failed_job and retry_failed_job (Solid Queue).
#
class DashboardController < ApplicationController
  FEED_SIZE = 20
  ACTIVITY_PER_PAGE = 50

  # GET / (and /home/index): the page layout, with the zone frames.
  def index; end

  # GET /dashboard/needs_you (frame)
  def needs_you
    @now = Time.current
    @context = Inbox::Context.new(now: @now, api_offline: api_offline_session?, user: current_user)
    # (SQL Outbox: adopt the scripts written or moved on disk, at most every 30 s; local files and ops DB only)
    Outbox::Reconciler.call_throttled(data_root: @context.data_dir) if @context.ops_available?
    @inbox = Inbox::Builder.new.call(@context)
    render_frame
  end

  # GET /dashboard/in_progress (frame)
  def in_progress
    season = SeasonBoard::Builder.latest_season
    @activities = safe([]) { SeasonBoard::ActivityLog.new.active }
    @names = board_names(season) || {}
    @queue = Dashboard::QueueActivity.new
    @next_runs = safe([]) { SeasonBoard::ActivityStripComponent.new(activities: [], names: {}).next_runs }
    render_frame
  end

  # GET /dashboard/season_progress (frame): the stored board summary (a local build only when none is stored).
  def season_progress
    @season = SeasonBoard::Builder.latest_season
    @summary = @season && safe(nil) { SeasonBoard::Snapshot.read(@season) || SeasonBoard::Snapshot.fetch(@season) }
    render_frame
  end

  # GET /dashboard/system (frame)
  def system_status
    @results = SystemStatus::Registry.results(offline: api_offline_session?, api_url: Shell::APITarget.configured_url)
    render_frame
  end

  # GET /dashboard/activity (frame)
  def activity_feed
    @ops_available = Ops.available?
    @events = @ops_available ? Ops.safely([]) { Ops::Event.recent.limit(FEED_SIZE).to_a } : []
    render_frame
  end

  # GET /dashboard/kpis (frame)
  def kpis
    @api_url = Shell::APITarget.configured_url
    @snapshot = KpiRefreshJob.read(@api_url)
    @refreshing = Dashboard::QueueActivity.new.pending?(KpiRefreshJob.name)
    render_frame
  end

  # GET /dashboard/health (frame): the data health card (ops DB findings & runs; see Health::DashboardCardComponent)
  def health
    @ops_available = Ops.available?
    @board_season = SeasonBoard::Builder.latest_season if @ops_available
    render_frame
  end

  # GET /activity: the whole event log, paginated.
  def activity_log
    @ops_available = Ops.available?
    @events = Ops.safely(nil) { Ops::Event.recent.page(params[:page]).per(ACTIVITY_PER_PAGE).tap(&:load) } if @ops_available
  end

  # POST /dashboard/refresh_kpis: queues a KpiRefreshJob (duplicates are discarded by the job itself).
  def refresh_kpis
    KpiRefreshJob.perform_later
    flash[:info] = t('dashboard.flash.kpis_queued')
  rescue StandardError => e
    logger.error("[DashboardController] KPI refresh not queued: #{e.class}: #{e.message}")
    flash[:error] = t('dashboard.flash.kpis_failed', error: e.message)
  ensure
    redirect_to(root_path)
  end

  # POST /dashboard/discard_failed_job (id: the Solid Queue failed execution ID)
  def discard_failed_job
    flash_and_go_home(*failed_execution_action do |execution, class_name|
      execution.discard
      [:notice, t('dashboard.flash.job_discarded', job: class_name)]
    end)
  end

  # POST /dashboard/retry_failed_job (id: the Solid Queue failed execution ID); refused for the protected jobs
  # (commit, push, maintenance apply, restore: see Inbox::Sources::FailedJobs::PROTECTED_JOBS).
  def retry_failed_job
    flash_and_go_home(*failed_execution_action do |execution, class_name|
      next [:warning, t('dashboard.flash.job_protected', job: class_name)] unless Inbox::Sources::FailedJobs.retriable?(class_name)

      execution.retry
      [:notice, t('dashboard.flash.job_retried', job: class_name)]
    end)
  end

  protected

  # The dashboard reads only local data: it is the landing page of API-offline sessions too.
  def api_offline_allowed?
    true
  end

  private

  def render_frame
    render(layout: false)
  end

  # Yields the failed execution for params[:id] and its job class name; returns the [flash key, message] pair
  # given by the block (or the one for a missing execution or a failure).
  def failed_execution_action
    execution = Dashboard::QueueActivity.failed_execution(params[:id].to_s)
    return [:warning, t('dashboard.flash.job_not_found')] unless execution

    yield(execution, execution.job&.class_name.to_s)
  rescue StandardError => e
    logger.error("[DashboardController] failed-job action: #{e.class}: #{e.message}")
    [:error, t('dashboard.flash.job_action_failed', error: e.message)]
  end

  def flash_and_go_home(key, message)
    flash[key] = message
    redirect_to(root_path)
  end

  # FIN event id => meeting name, from the stored board summary (or the watcher snapshot, see ActivityStripComponent).
  def board_names(season)
    summary = season && safe(nil) { SeasonBoard::Snapshot.read(season) }
    summary ? summary.rows.to_h { |row| [row.fin_event_id.to_s, row.name] } : nil
  end

  def safe(default)
    yield
  rescue StandardError => e
    logger.warn("[DashboardController] #{action_name}: #{e.class}: #{e.message}")
    default
  end
end
