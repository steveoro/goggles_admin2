# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::RunsController
  #
  # The operation runs (Ops::OperationRun), always started by an operator click:
  # - create (POST /operations/:key/runs): validates the form params, creates the 'preview' run and queues it
  #   (Maintenance::RunJob, 'maintenance' worker); the page then shows the dry run;
  # - show / status: the run page and its live status frame (dry run report, apply outcome, linked finding, health
  #   re-run, follow-up suggestions);
  # - apply (POST /operations/runs/:id/apply): the ONLY place where an apply is queued. Refused while a DB restore
  #   runs, when operations are disabled, for a dry run that can't be applied (errors, nothing to do, already applied),
  #   without the confirmation the dry run asks for (one click / checkbox / typed text), and when the DB sync gate
  #   (Drift::Gate, scope :operation) blocks or warns without the operator's tick. The job checks the gate again
  #   before planning.
  # - cancel (POST /operations/runs/:id/cancel, phase 13): the operator's Cancel click on a pending run of a cancellable
  #   operation ('season.badge_fix'): a queued run is refused at once, a running one stops at its next progress report.
  #
  class RunsController < ApplicationController
    before_action :require_ops!
    before_action :set_run, only: %i[show status apply cancel]
    before_action :refuse_while_restoring!, :refuse_when_disabled!, only: %i[create apply]

    # GET /operations/runs/:id
    def show
      @gate = drift_gate if @run.appliable? && !@run.applied_or_applying?
    end

    # POST /operations/:key/runs
    def create # rubocop:disable Metrics/AbcSize
      klass = Maintenance::Registry.find(params.expect(:key))
      return redirect_with(:error, t('maintenance.errors.unknown_operation'), operations_path) unless klass

      @operation_class = klass
      @operation = klass.new(**klass.permitted(params.fetch(:operation, {})))
      @finding = find_finding(klass)
      @origin = Ops::OperationRun::ORIGINS.include?(params[:origin].to_s) ? params[:origin].to_s : 'ui'
      return render('operations/new', status: :unprocessable_content) unless @operation.valid?

      run = create_preview!(@operation)
      enqueue(run)
      flash[:info] = t('maintenance.preview.queued')
      redirect_to(maintenance_run_path(run))
    end

    # GET /operations/runs/:id/status (frame)
    def status
      @gate = drift_gate if @run.appliable? && !@run.applied_or_applying?
      render(partial: 'maintenance/runs/status', locals: { run: @run, gate: @gate })
    end

    # POST /operations/runs/:id/apply
    def apply
      error = apply_error
      return redirect_with(:error, error, maintenance_run_path(@run)) if error

      apply_run = create_apply!(@run)
      enqueue(apply_run)
      flash[:info] = t('maintenance.apply.queued')
      redirect_to(maintenance_run_path(apply_run))
    end

    # POST /operations/runs/:id/cancel
    def cancel
      if @run.cancellable? && @run.request_cancel!
        Maintenance::Notifier.ping(@run)
        redirect_with(:info, t(@run.refused? ? 'maintenance.run.cancelled' : 'maintenance.run.cancel_requested'), maintenance_run_path(@run))
      else
        redirect_with(:warning, t('maintenance.run.cancel_refused'), maintenance_run_path(@run))
      end
    end

    private

    def require_ops!
      return if Ops.available?

      redirect_with(:error, t('maintenance.errors.ops_unavailable'), operations_path)
    end

    def set_run
      @run = Ops::OperationRun.find_by(id: params[:id])
      redirect_with(:warning, t('maintenance.run.not_found'), operations_path) unless @run
    end

    def refuse_while_restoring!
      lock = '::DbRestore::Lock'.safe_constantize
      return unless lock.respond_to?(:active?) && lock.active?

      redirect_with(:error, t('maintenance.errors.restore'), @run ? maintenance_run_path(@run) : operations_path)
    end

    def refuse_when_disabled!
      return if Maintenance.enabled?

      redirect_with(:error, t('maintenance.errors.disabled'), @run ? maintenance_run_path(@run) : operations_path)
    end

    def redirect_with(level, message, path)
      flash[level] = message
      redirect_to(path)
    end

    # The finding of params[:finding_id] when the operation fixes its check.
    def find_finding(klass)
      return if params[:finding_id].blank?

      finding = Ops::HealthFinding.find_by(id: params[:finding_id])
      finding if finding && klass.fixes.include?(finding.check_key)
    end

    def create_preview!(operation)
      subject_type, subject_id = operation.subject
      Ops::OperationRun.create!(
        operation_key: operation.key, params: operation.to_params, params_digest: operation.params_digest, mode: 'preview',
        status: 'queued', label: operation.label.to_s.truncate(250), season_id: @finding&.season_id || safe_season_id(operation),
        subject_type: subject_type&.to_s, subject_id:, origin: @finding ? 'health' : @origin,
        health_finding_id: @finding&.id, started_by: current_user&.id
      )
    end

    def create_apply!(preview)
      Ops::OperationRun.create!(
        operation_key: preview.operation_key, params: preview.params_hash, params_digest: preview.params_digest, mode: 'apply',
        parent_run_id: preview.id, status: 'queued', label: preview.label, season_id: preview.season_id,
        subject_type: preview.subject_type, subject_id: preview.subject_id, origin: preview.origin,
        health_finding_id: preview.health_finding_id, drift_ack: params[:drift_ack].to_s == '1', started_by: current_user&.id
      )
    end

    def safe_season_id(operation)
      operation.season_id
    rescue StandardError
      nil
    end

    # The operator click is the only enqueue site of Maintenance::RunJob (spec-asserted).
    def enqueue(run)
      job = Maintenance::RunJob.perform_later(run_id: run.id, mode: run.mode)
      run.update_columns(job_id: job.job_id) if job.respond_to?(:job_id) && job.job_id # rubocop:disable Rails/SkipsModelValidations
    end

    # The refusal text of an apply request, nil when it may be queued.
    def apply_error
      return t('maintenance.apply.errors.not_appliable') unless @run.appliable?
      return t('maintenance.apply.errors.already_applied') if @run.applied_or_applying?

      confirmation = Maintenance::Confirmation.for_run(@run)
      return t(confirmation.error_key) unless confirmation.satisfied_by?(params)

      gate = drift_gate(acknowledged: params[:drift_ack].to_s == '1')
      t('maintenance.apply.errors.drift', summary: gate.summary) unless gate.allowed?
    end

    # The DB sync gate for an apply (never asked for a dry run).
    def drift_gate(acknowledged: false)
      Drift::Gate.check(scope: :operation, acknowledged:)
    end
  end
end
