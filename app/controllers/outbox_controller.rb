# frozen_string_literal: true

#
# = OutboxController
#
# The SQL Outbox page (phase 07, see Outbox and docs/outbox.md): every SQL script waiting to be pushed, in global
# sequence order, the ones already on the server and the history; the operator actions on a script; the push
# confirmation and the push itself (a clicked Outbox::PushJob, the ONLY place that enqueues it).
#
# - index:   'Needs push' (all folders, always), 'On the server' and 'History' (default filter: the default season
#            folder + 'misc'); <tt>focus=<filename></tt> scrolls to and highlights a row; <tt>frame=1</tt> renders only
#            the live frame (outbox_controller.js). Reconciles the disk first (throttled, 30 s) and enqueues the
#            read-only remote status check when due. With the ops DB missing: setup notice + the disk-derived list.
# - show:    one script (metadata, origin, SQL preview, actions).
# - hold / release / apply_locally / discard / resolve: Outbox::ScriptActions (one click each).
# - reconcile: rescans the disk now.
# - push_new: confirmation page (ordered list, size, target, environment, fresh ping, JWT, typed label).
# - push:    re-runs the Reconciler and the ordering guard, creates the Ops::PushRun, enqueues Outbox::PushJob.
#
# Everything but the push confirmation & the push works in an API-offline session (local files & ops DB only).
#
class OutboxController < ApplicationController # rubocop:disable Metrics/ClassLength
  # Rows listed per section ('On the server', 'History')
  LIST_LIMIT = 100
  # Bytes of SQL shown in the previews
  PREVIEW_BYTES = { row: 1.kilobyte, show: 64.kilobytes }.freeze
  PING_TIMEOUTS = { open_timeout: 3, timeout: 5 }.freeze
  OFFLINE_ACTIONS = %w[index show reconcile hold release apply_locally discard resolve].freeze

  before_action :require_ops!, except: :index
  before_action :set_script, only: %i[show hold release apply_locally discard resolve]

  helper_method :preview_for, :frame_locals

  # GET /outbox[?focus=<filename>&folder=<folder|all>&frame=1]
  def index
    @ops_ready = Ops.available?
    @focus = params[:focus].to_s.presence
    return index_without_ops unless @ops_ready

    Outbox::Reconciler.call_throttled
    Outbox::RemoteStatusJob.enqueue_if_due
    load_index
    render(partial: 'outbox/scripts_frame', locals: frame_locals, layout: false) if params[:frame].present?
  end

  # GET /outbox/:id
  def show
    @plan_blockers = @script.needs_push? ? @script.blockers.limit(5).to_a : []
  end

  # POST /outbox/reconcile
  def reconcile
    report = Outbox::Reconciler.call
    summary = report.counts.except('unchanged', 'restat').map { |action, count| "#{action} #{count}" }.join(', ')
    redirect_to(outbox_path, notice: I18n.t('outbox.flash.reconciled', summary: summary.presence || '-'))
  end

  # POST /outbox/:id/hold
  def hold
    run_action(:held) { Outbox::ScriptActions.hold!(@script) }
  end

  # POST /outbox/:id/release[?force=1]
  def release
    run_action(:released) { Outbox::ScriptActions.release!(@script, force: params[:force].to_s == '1') }
  end

  # POST /outbox/:id/apply_locally: runs the script on the local DB (an operator click).
  def apply_locally
    result = Outbox::ScriptActions.apply_locally!(@script)
    if result.success?
      flash[:notice] = I18n.t('outbox.flash.applied', file: @script.filename, duration: result.duration.round(1))
    else
      flash[:error] = I18n.t('outbox.flash.apply_failed', file: @script.filename, error: result.stderr.to_s.truncate(300))
    end
    redirect_to(outbox_script_path(@script))
  rescue Ops::SqlScript::InvalidTransition => e
    redirect_to(outbox_script_path(@script), alert: e.message)
  end

  # POST /outbox/:id/discard (note required)
  def discard
    run_action(:discarded) { Outbox::ScriptActions.discard!(@script, note: params[:note]) }
  end

  # POST /outbox/:id/resolve (to: sent|pending|discarded, remote_iq_id, note)
  def resolve
    run_action(:resolved, state: params[:to]) do
      Outbox::ScriptActions.resolve!(@script, to: params[:to], remote_iq_id: params[:remote_iq_id], note: params[:note])
    end
  end

  # GET /outbox/push/new?ids[]=..|scope=all_pending|next[&override_order=1]
  def push_new
    @plan = push_plan
    @ping = APIProxy.ping(@plan.target_url, **PING_TIMEOUTS) unless @plan.empty?
    @jwt_valid = Outbox::Pusher.jwt_valid?(current_user.jwt)
    @jwt_expires_at = jwt_expires_at
  end

  # POST /outbox/push (confirmed=1, confirm_label, ids[] / scope, override_order)
  def push # rubocop:disable Metrics/AbcSize
    return redirect_to(new_outbox_push_path(push_params), alert: I18n.t('outbox.flash.confirmation_required')) unless params[:confirmed] == '1'
    return redirect_to(outbox_path, alert: I18n.t('outbox.flash.run_in_progress')) if Ops::PushRun.live?
    return redirect_to(outbox_path, alert: I18n.t('outbox.flash.jwt_invalid')) unless Outbox::Pusher.jwt_valid?(current_user.jwt)

    Outbox::Reconciler.call
    plan = push_plan
    return redirect_to(outbox_path, alert: I18n.t('outbox.flash.nothing_to_push')) if plan.empty?
    return redirect_to(new_outbox_push_path(push_params), alert: I18n.t('outbox.flash.blocked')) unless plan.allowed?
    return redirect_to(new_outbox_push_path(push_params), alert: I18n.t('outbox.flash.label_mismatch')) unless plan.label_confirmed?(params[:confirm_label])

    run = Ops::PushRun.create!(user_id: current_user.id, target_api_url: plan.target_url, target_env: plan.environment,
                               script_ids: plan.script_ids, override_order: plan.override_order, status: 'running',
                               started_at: Time.current)
    job = Outbox::PushJob.perform_later(run.id)
    run.update!(job_id: job.job_id) if job.respond_to?(:job_id)
    Outbox::Notifier.ping
    redirect_to(outbox_path(run: run.id), notice: I18n.t('outbox.runs.started', id: run.id, count: run.total))
  end

  protected

  def api_offline_allowed?
    OFFLINE_ACTIONS.include?(action_name)
  end

  private

  def require_ops!
    return if Ops.available?

    redirect_to(outbox_path, alert: I18n.t('outbox.flash.ops_missing'))
  end

  def set_script
    @script = Ops::SqlScript.find_by(id: params[:id])
    redirect_to(outbox_path, alert: I18n.t('outbox.flash.not_found')) unless @script
  end

  # Runs an operator action on @script, then back to the script page (flash: 'outbox.flash.<key>').
  def run_action(flash_key, **options)
    yield
    redirect_to(outbox_script_path(@script), notice: I18n.t("outbox.flash.#{flash_key}", file: @script.filename, **options))
  rescue Ops::SqlScript::InvalidTransition, Outbox::Error => e
    redirect_to(outbox_script_path(@script), alert: e.message)
  end

  def push_params
    params.permit(:scope, :override_order, ids: []).to_h
  end

  def push_plan
    Outbox::PushPlan.new(ids: params[:ids], scope: params[:scope], override_order: params[:override_order])
  end

  def jwt_expires_at
    exp = JWT.decode(current_user.jwt, Rails.application.credentials.api_static_key, true, algorithm: 'HS512').first['exp']
    exp ? Time.zone.at(exp.to_i) : nil
  rescue StandardError
    nil
  end

  def index_without_ops
    @disk_scripts = disk_scripts
    render(partial: 'outbox/scripts_frame', locals: frame_locals, layout: false) if params[:frame].present?
  end

  # (ops DB missing) results.new SQL files by name, as [rel_path, size] pairs.
  def disk_scripts
    root = Outbox.data_root
    Dir.glob(root.join(Outbox::NEW_DIR, '**', '*.sql').to_s)
       .reject { |path| path.include?("/#{Outbox::NEW_DIR}/#{Outbox::DISCARDED_DIR}/") }
       .sort_by { |path| [Outbox::Sequence.prefix_of(path).to_i, File.basename(path)] }
       .map { |path| [Outbox.relative_path(path, data_root: root), File.size(path)] }
  end

  def load_index # rubocop:disable Metrics/AbcSize
    @folder = params[:folder].presence
    @default_season_id = SeasonDefaults.default_season_id
    @needs_push = Ops::SqlScript.needs_push.to_a
    @blockers = blockers_by_id(@needs_push)
    @on_server = filtered(Ops::SqlScript.on_server).reorder(seq: :desc).limit(LIST_LIMIT).to_a
    @history = filtered(Ops::SqlScript.history).reorder(seq: :desc).limit(LIST_LIMIT).to_a
    @runs = Ops::PushRun.recent.limit(5).to_a
    @live_run = @runs.find(&:live?)
    @remote_status = Outbox::RemoteStatusJob.read
    @imported = Outbox::Reconciler.imported?
    @focus_script = @focus && ([*@needs_push, *@on_server, *@history].find { |script| script.filename == @focus } ||
                               Ops::SqlScript.find_by(filename: @focus))
  end

  # Section filter: the default season folder + 'misc' (default), one folder, or all of them.
  def filtered(relation)
    case @folder
    when 'all' then relation
    when nil then relation.in_folders(@default_season_id.to_s, Outbox::MISC_FOLDER)
    else relation.in_folders(@folder)
    end
  end

  # { script id => first lower-seq blocking script } for the needs-push rows.
  def blockers_by_id(scripts)
    first_blocking = nil
    scripts.each_with_object({}) do |script, map|
      map[script.id] = first_blocking if first_blocking
      first_blocking ||= script if Ops::SqlScript::BLOCKING_STATES.include?(script.state)
    end
  end

  def frame_locals
    {
      ops_ready: @ops_ready, needs_push: @needs_push || [], blockers: @blockers || {}, on_server: @on_server || [],
      history: @history || [], runs: @runs || [], live_run: @live_run, focus: @focus, folder: @folder,
      default_season_id: @default_season_id, disk_scripts: @disk_scripts || [], remote_status: @remote_status
    }
  end

  # First bytes of the script file (String) and whether it was cut, or nil when the file is gone.
  def preview_for(script, size: PREVIEW_BYTES[:row])
    path = script.absolute_path
    return unless path.file?

    text = File.open(path, 'rb') { |file| file.read(size) }.to_s
    [text.force_encoding(Encoding::UTF_8).scrub, path.size > size]
  rescue SystemCallError
    nil
  end
end
