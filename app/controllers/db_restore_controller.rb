# frozen_string_literal: true

#
# = DbRestoreController
#
# Guided restore of the local MySQL development DB from a production dump (phase 14, see docs/db_restore.md).
#
# Wizard (normal layout, signed-in operator, MySQL up):
# - new:          step 0-2: target guards, preconditions checklist, dump catalog (+ open run, history);
# - create:       starts a run for the chosen dump (status 'inspecting') and enqueues DbRestore::InspectJob;
# - dump_dirs:    stores the dump folders (Ops::Setting 'db_restore.dump_dirs');
# - inspection:   step 3 results (polls while inspecting / snapshotting; JSON for the poller);
# - snapshot:     step 4: enqueues DbRestore::SnapshotJob, or records the "skip the safety snapshot" tick;
# - confirmation: step 5 page (typed DB name, API URL choice, wizard or terminal load);
# - confirm:      step 5: re-checks everything, issues the progress token, takes DbRestore::Lock, enqueues the load;
# - cancel:       drops a run not confirmed yet;
# - result:       step 8 (after the lock is released).
# Progress page (restore layout, no MySQL access: the guard, the app settings, the JWT check and Devise are
# skipped; access needs a local request and the run's progress token in the URL, or this browser's session grant,
# set by the confirmation or by a valid token link: only the run id and an expiry, never the token):
# - show, poll (status JSON, polled every 2 s), resume, load_snapshot, abandon (typed DB name), post_steps.
#
# DbRestore::RestoreJob is enqueued in one place only (#enqueue_restore!, operator clicks).
#
class DbRestoreController < ApplicationController # rubocop:disable Metrics/ClassLength
  PROGRESS_ACTIONS = %i[show poll resume load_snapshot abandon post_steps].freeze
  HISTORY_LIMIT = 10

  skip_db_restore_guard only: PROGRESS_ACTIONS
  skip_before_action :app_settings_row, :check_jwt_session, :authenticate_user!, :set_current_attributes, only: PROGRESS_ACTIONS
  before_action :require_progress_access!, only: PROGRESS_ACTIONS
  before_action :require_ops!, except: PROGRESS_ACTIONS + %i[new]
  before_action :set_run, only: %i[inspection snapshot confirmation confirm cancel result]

  # GET /db_restore/:id (progress page)
  def show
    return redirect_to(db_restore_result_path(@run)) if @run.terminal? && !DbRestore::Lock.active?

    @progress_url = @url_token ? db_restore_url(@run, token: @url_token) : nil
    render(:show, layout: 'restore')
  end

  # GET /db_restore/new
  def new
    @ops_available = Ops.available?
    @target = DbRestore::Target.current
    @catalog = DbRestore::DumpCatalog.new
    return unless @ops_available

    @open_run = Ops::RestoreRun.open_runs.recent.first
    @preconditions = preconditions(run: @open_run).call(stage: :entry)
    @history = Ops::RestoreRun.recent.limit(HISTORY_LIMIT).to_a
  end

  # POST /db_restore (dump=<path>, discard_reviews=1)
  def create
    catalog = DbRestore::DumpCatalog.new
    dump = params[:dump].to_s
    entry = catalog.find(dump)
    return redirect_to(new_db_restore_path, alert: t('db_restore.flash.dump_unknown')) unless entry

    confirmations = { 'discard_reviews' => params[:discard_reviews].to_s == '1' }
    result = preconditions(confirmations:).call(stage: :entry)
    return redirect_to(new_db_restore_path, alert: t('db_restore.flash.refused', reasons: result.messages.join(' • '))) unless result.allowed?

    run = start_inspection!(entry, confirmations)
    redirect_to(inspect_db_restore_path(run), notice: t('db_restore.flash.inspecting'))
  end

  # POST /db_restore/dump_dirs (dirs=<one per line>)
  def dump_dirs
    dirs = DbRestore::DumpCatalog.store_dirs!(params[:dirs])
    redirect_to(new_db_restore_path, notice: t('db_restore.flash.dirs_saved', count: dirs.size))
  end

  # GET /db_restore/:id/inspect[.json]
  def inspection
    respond_to do |format|
      format.html { render(:inspect) }
      format.json { render(json: status_payload(@run)) }
    end
  end

  # POST /db_restore/:id/snapshot (skip=1: no safety snapshot)
  def snapshot
    return redirect_to(inspect_db_restore_path(@run), alert: t('db_restore.flash.not_ready')) unless @run.ready?

    if params[:skip].to_s == '1'
      @run.update!(confirmations: @run.confirmations.to_h.merge('skip_snapshot' => true))
      @run.append_log!(t('db_restore.log.snapshot_skipped'))
      return redirect_to(confirmation_db_restore_path(@run))
    end

    start_snapshot!(@run)
    redirect_to(inspect_db_restore_path(@run), notice: t('db_restore.flash.snapshotting'))
  end

  # GET /db_restore/:id/confirm
  def confirmation
    return redirect_to(inspect_db_restore_path(@run), alert: t('db_restore.flash.not_ready')) unless confirmable?(@run)

    @target = DbRestore::Target.current
    @preconditions = preconditions(run: @run).call(stage: :confirm)
    @api_url = APIProxy.configured_base_url.to_s
    render(:confirm)
  end

  # POST /db_restore/:id/confirm (typed_name, api_url_choice, load_mode)
  def confirm # rubocop:disable Metrics/AbcSize
    return redirect_to(inspect_db_restore_path(@run), alert: t('db_restore.flash.not_ready')) unless confirmable?(@run)

    target = DbRestore::Target.current
    if params[:typed_name].to_s.strip != target.database || target.database != @run.target_database
      return redirect_to(confirmation_db_restore_path(@run), alert: t('db_restore.flash.typed_name_mismatch'))
    end

    result = preconditions(run: @run).call(stage: :confirm)
    return redirect_to(confirmation_db_restore_path(@run), alert: t('db_restore.flash.refused', reasons: result.messages.join(' • '))) unless result.allowed?

    terminal = params[:load_mode].to_s == 'terminal'
    token = start_run!(terminal:)
    pause_queues!(@run)
    grant_db_restore_progress!(@run)
    enqueue_restore!(@run, terminal ? 'terminal' : 'load')
    # (The token is shown once, as the page's bookmark link; the redirect URL is filtered from the log.)
    redirect_to(db_restore_path(@run, token:))
  rescue DbRestore::Lock::HeldError => e
    redirect_to(confirmation_db_restore_path(@run), alert: e.message)
  end

  # POST /db_restore/:id/cancel
  def cancel
    return redirect_to(new_db_restore_path, alert: t('db_restore.flash.not_cancellable')) unless @run.preparing?

    @run.update!(status: 'cancelled', step: 'cancelled', finished_at: Time.current)
    @run.append_log!(t('db_restore.log.cancelled'))
    redirect_to(new_db_restore_path, notice: t('db_restore.flash.cancelled', id: @run.id))
  end

  # GET /db_restore/:id/result
  def result
    return redirect_to(db_restore_path(@run)) if @run.locking?

    @fingerprint = Ops::DbFingerprint.find_by(id: @run.outcome.to_h['db_fingerprint_id'])
  end

  # GET /db_restore/:id/status.json
  def poll
    render(json: status_payload(@run))
  end

  # POST /db_restore/:id/resume
  def resume
    return redirect_to(db_restore_path(@run), alert: t('db_restore.flash.not_interrupted')) unless @run.needs_operator?

    @run.append_log!(t('db_restore.log.resume'))
    enqueue_restore!(@run, 'resume')
    redirect_to(db_restore_path(@run), notice: t('db_restore.flash.resumed'))
  end

  # POST /db_restore/:id/load_snapshot
  def load_snapshot
    return redirect_to(db_restore_path(@run), alert: t('db_restore.flash.not_interrupted')) unless @run.needs_operator?
    return redirect_to(db_restore_path(@run), alert: t('db_restore.flash.no_snapshot')) unless @run.snapshot_exists?

    @run.append_log!(t('db_restore.log.load_snapshot', path: File.basename(@run.snapshot_path)))
    enqueue_restore!(@run, 'snapshot')
    redirect_to(db_restore_path(@run), notice: t('db_restore.flash.snapshot_loading'))
  end

  # POST /db_restore/:id/post_steps ("Load done, run post-steps", terminal mode)
  def post_steps
    return redirect_to(db_restore_path(@run), alert: t('db_restore.flash.not_awaiting')) unless @run.awaiting_terminal?

    @run.append_log!(t('db_restore.log.terminal_done'))
    enqueue_restore!(@run, 'post_steps')
    redirect_to(db_restore_path(@run), notice: t('db_restore.flash.post_steps'))
  end

  # POST /db_restore/:id/abandon (typed_name)
  def abandon
    abandonable = @run.confirmed? || @run.needs_operator? || @run.awaiting_terminal?
    return redirect_to(db_restore_path(@run), alert: t('db_restore.flash.not_abandonable')) unless abandonable
    return redirect_to(db_restore_path(@run), alert: t('db_restore.flash.typed_name_mismatch')) if params[:typed_name].to_s.strip != @run.target_database

    DbRestore::Restorer.abandon!(@run)
    redirect_to(db_restore_result_path(@run), notice: t('db_restore.flash.abandoned'))
  end

  protected

  # The wizard reads only local data (the API URL is shown, never called).
  def api_offline_allowed?
    true
  end

  private

  def require_ops!
    return if Ops.available?

    redirect_to(new_db_restore_path, alert: t('db_restore.flash.ops_missing'))
  end

  def set_run
    @run = Ops::RestoreRun.find_by(id: params[:id])
    redirect_to(new_db_restore_path, alert: t('db_restore.flash.not_found')) unless @run
  end

  # Progress page access: local request + the run's token in the URL (which renews this browser's grant) or the
  # session grant. Reads only the ops DB.
  def require_progress_access!
    return render_progress_refusal(:forbidden, 'db_restore.progress.not_local') unless local_request?

    @run = Ops.safely { Ops::RestoreRun.find_by(id: params[:id]) if Ops.available? }
    return render_progress_refusal(:not_found, 'db_restore.flash.not_found') unless @run

    url_token = params[:token].to_s.presence
    if url_token && @run.token_matches?(url_token)
      @url_token = url_token
      grant_db_restore_progress!(@run)
    elsif !db_restore_progress_granted?(@run)
      render_progress_refusal(:forbidden, 'db_restore.progress.bad_token')
    end
  end

  # Creates the 'inspecting' run for the catalog +entry+ and enqueues its inspection.
  def start_inspection!(entry, confirmations)
    run = Ops::RestoreRun.create!(status: 'inspecting', step: 'inspect', user_id: current_user.id, dump_path: entry.path,
                                  dump_bytes: entry.bytes, target_database: DbRestore::Target.current.database, confirmations:)
    job = DbRestore::InspectJob.perform_later(run_id: run.id)
    run.update!(job_id: job.job_id) if job.respond_to?(:job_id)
    run.append_log!(t('db_restore.log.created', dump: entry.basename))
    run
  end

  def start_snapshot!(run)
    run.update!(status: 'snapshotting', step: 'snapshot', error: nil, confirmations: run.confirmations.to_h.merge('skip_snapshot' => false))
    job = DbRestore::SnapshotJob.perform_later(run_id: run.id)
    run.update!(job_id: job.job_id) if job.respond_to?(:job_id)
  end

  def render_progress_refusal(status, key)
    if request.format.json?
      render(json: { error: t(key) }, status:)
    else
      @refusal = t(key)
      render(:refused, layout: 'restore', status:)
    end
  end

  def preconditions(run: nil, confirmations: nil)
    DbRestore::Preconditions.new(run:, confirmations:)
  end

  def confirmable?(run)
    run.ready? && (run.snapshot_exists? || run.ticked?(:skip_snapshot))
  end

  # Typed confirmation accepted: token, confirmations, status 'confirmed' and the lock, in one ops transaction.
  def start_run!(terminal:)
    token = nil
    Ops::ApplicationRecord.transaction do
      confirmations = @run.confirmations.to_h.merge(
        'typed_name' => true, 'api_url_choice' => DbRestore::Preserver::CHOICES.include?(params[:api_url_choice]) ? params[:api_url_choice] : 'keep',
        'confirmed_by' => current_user.id, 'confirmed_at' => Time.current.utc.iso8601
      )
      @run.update!(status: 'confirmed', step: 'confirmed', mode: terminal ? 'terminal' : 'wizard', confirmations:, error: nil)
      token = @run.issue_token!
      DbRestore::Lock.acquire!(@run)
    end
    @run.append_log!(t('db_restore.log.confirmed', mode: @run.mode))
    Ops.record_event!(kind: 'db_restore.confirmed', level: 'warning', actor: 'operator', subject_type: 'restore_run',
                      subject_key: @run.id, data: { 'dump' => @run.dump_basename, 'database' => @run.target_database, 'mode' => @run.mode })
    token
  end

  # Pauses DbRestore::PAUSED_QUEUES as soon as the lock is taken, so that no job of those queues is claimed (and
  # skipped through the lock) before DbRestore::RestoreJob starts; remembers the ones paused here (resumed later).
  def pause_queues!(run)
    paused = DbRestore::Queues.new.pause!(DbRestore::PAUSED_QUEUES)
    run.update!(preserved: run.preserved.to_h.merge('paused_queues' => paused))
  end

  # The only call site of DbRestore::RestoreJob (operator clicks: confirm, resume, load snapshot, post-steps).
  def enqueue_restore!(run, mode)
    job = DbRestore::RestoreJob.perform_later(run_id: run.id, mode:)
    run.update!(job_id: job.job_id) if job.respond_to?(:job_id)
  end

  def status_payload(run)
    {
      id: run.id, status: run.status, step: run.step, mode: run.mode,
      step_label: t("db_restore.steps.#{run.step.presence || run.status}", default: run.step.to_s),
      progress_bytes: run.progress_bytes.to_i, dump_bytes: run.dump_bytes.to_i, percent: run.progress_percent,
      stalled: run.stalled?, needs_operator: run.needs_operator?, updated_at: run.updated_at&.utc&.iso8601,
      error: run.error.to_s.truncate(500).presence
    }
  end
end
