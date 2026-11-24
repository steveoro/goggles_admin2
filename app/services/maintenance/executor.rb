# frozen_string_literal: true

require 'fileutils'

module Maintenance
  #
  # = Maintenance::Executor
  #
  # Runs one Ops::OperationRun (Maintenance::RunJob on the single-thread 'maintenance' worker, or inline from a rake
  # task in phase 13), by mode:
  #
  # - preview: Operation#plan (the dry run). Stores the console output, the summary (with the confirmation level, the
  #   typed token, the Data-Fix reviews in progress of the season and the follow-up suggestions), the warnings, the
  #   errors, the SQL preview and its digest. Writes nothing else: no primary-DB statement, no file, no Outbox row.
  # - apply (child of a succeeded preview):
  #   1. refuses while a DB restore runs (DbRestore::Lock, when defined), without its preview, or when the preview
  #      already has another apply;
  #   2. Drift::Gate.check(scope: :operation (:rake for a rake caller), acknowledged: run.drift_ack) BEFORE planning
  #      (red blocks; amber/unknown needs the operator's tick); the verdict name is stored on the run;
  #   3. re-plans on live data and refuses a changed digest (+digest_changed+), a blocked or an empty plan;
  #   4. writes tmp/maintenance/<run id>.sql and runs it with LocalDb::SqlRunner (never raises); on failure the run
  #      fails and no Outbox script exists;
  #   5. only then registers the script with Outbox::Writer.write!(folder: 'misc', applied_locally: true) and
  #      (#after_apply!) links the finding (mitigation_run_id), records 'maintenance.applied', re-runs the season's
  #      health group (Health::SeasonRunJob.enqueue, trigger 'after_operation'), bumps the Data-Fix db generation for
  #      the operations changing entities and pings the pages.
  # - script_only (rake only, phase 13): re-plans and registers the script held 'not_applied_locally'; nothing runs.
  #
  # Never raises: an unexpected error closes the run as failed.
  #
  class Executor # rubocop:disable Metrics/ClassLength
    TMP_DIR = Rails.root.join('tmp/maintenance')
    # Data-Fix stages counted as "reviews in progress" on the dry run.
    REVIEW_STAGES = %w[preparing needs_review blocked ready_to_commit committing].freeze
    MAX_REVIEWS_LISTED = 20

    attr_reader :run

    # == Params
    # - run: the Ops::OperationRun (queued);
    # - data_root: crawler data root of the Outbox (specs: a temporary folder); sql_runner: LocalDb::SqlRunner (or a
    #   stand-in answering .call(path:)); gate: Drift::Gate (or a stand-in answering .check(scope:, acknowledged:, force:));
    # - gate_scope / gate_force: :operation (UI) by default; a rake caller (phase 13) passes :rake and its force=1.
    def initialize(run:, data_root: Outbox.data_root, sql_runner: LocalDb::SqlRunner, gate: Drift::Gate, tmp_dir: TMP_DIR, # rubocop:disable Metrics/ParameterLists
                   gate_scope: :operation, gate_force: false)
      @run = run
      @gate_scope = gate_scope
      @gate_force = gate_force
      @data_root = Pathname.new(data_root)
      @sql_runner = sql_runner
      @gate = gate
      @tmp_dir = Pathname.new(tmp_dir)
    end

    # Runs the queued run once (a run not queued any more is left as it is). Returns the run.
    def call
      return run if run.nil? || !run.claim!

      Notifier.ping(run)
      perform_mode
      run
    ensure
      Notifier.ping(run) if run
    end

    private

    MODE_STEPS = { 'preview' => :preview!, 'apply' => :apply!, 'script_only' => :script_only! }.freeze
    private_constant :MODE_STEPS

    def perform_mode
      send(MODE_STEPS.fetch(run.mode))
    rescue StandardError => e
      Rails.logger.error("[Maintenance::Executor] run #{run.id}: #{e.class}: #{e.message}")
      Rails.logger.debug { e.backtrace&.first(15)&.join("\n") }
      fail!(["#{e.class}: #{e.message}".truncate(2000)])
    end

    def operation
      @operation ||= run.operation
    end

    # == preview

    def preview!
      return refuse!(:unknown_operation) unless operation

      plan = operation.plan
      attributes = plan_attributes(plan)
      attributes[:warnings] = interrupted_apply_warnings + attributes[:warnings]
      run.finish!(status: 'succeeded', **attributes, summary: preview_summary(plan))
    end

    # One warning per interrupted apply of the same operation and params: the local DB may already hold its change
    # (this dry run reads the current data; nothing is re-run nor registered for the interrupted one).
    def interrupted_apply_warnings
      Ops.safely([]) do
        Ops::OperationRun.applies.pending.where(operation_key: run.operation_key, params_digest: run.params_digest)
                         .where.not(id: run.id).order(:id).select(&:interrupted?)
                         .map { |apply| I18n.t('maintenance.executor.interrupted_apply', id: apply.id) }
      end
    end

    def preview_summary(plan)
      plan.summary.to_h.stringify_keys.merge(
        'confirmation' => operation.confirmation_for(plan).to_s, 'typed_token' => operation.typed_token,
        'empty' => plan.empty?, 'statements' => plan.write_statements_count, 'health_group' => plan.health_group,
        'subjects' => plan.subjects, 'file_base' => (plan.blocked? ? nil : safe_file_base),
        'reviews_in_progress' => reviews_in_progress(plan.season_id), 'follow_ups' => operation.follow_ups(plan)
      ).compact
    end

    # == apply

    def apply! # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      return refuse!(:restore_in_progress) if restore_in_progress?
      return refuse!(:unknown_operation) unless operation

      parent = run.parent_run
      return refuse!(:no_preview) unless parent&.preview? && parent.succeeded? && parent.operation_key == run.operation_key
      return refuse!(:already_applied) if other_apply_of?(parent)

      gate = @gate.check(scope: @gate_scope, acknowledged: run.drift_ack, force: @gate_force)
      run.update_columns(drift_verdict: gate.verdict_name) if gate.respond_to?(:verdict_name) # rubocop:disable Rails/SkipsModelValidations
      return refuse!(gate.block? ? :drift_blocked : :drift_unacknowledged, message: gate_message(gate)) unless gate.allowed?

      plan = operation.plan
      return refuse!(:digest_changed, **plan_attributes(plan)) if plan.digest != parent.sql_digest
      return refuse!(:blocked, **plan_attributes(plan)) if plan.blocked?
      return refuse!(:empty, **plan_attributes(plan)) if plan.empty?

      apply_locally!(plan)
    end

    def apply_locally!(plan)
      tmp_path = write_tmp(plan)
      result = @sql_runner.call(path: tmp_path)
      unless result.success?
        FileUtils.rm_f(tmp_path)
        return fail!([I18n.t('maintenance.executor.local_apply_failed', error: result.stderr.to_s.strip.truncate(4000))],
                     **plan_attributes(plan))
      end

      script = register!(plan, applied_locally: true, tmp_path:)
      FileUtils.rm_f(tmp_path)
      after_apply!(plan, script)
    end

    # The local DB changed: the script MUST be registered. When the Writer fails, the temporary file is kept and named
    # in the error, so that the operator can register it by hand.
    def register!(plan, applied_locally:, tmp_path: nil)
      Outbox::Writer.write!(
        kind: operation.class.outbox_kind, name: operation.file_base, sql: plan.sql_text, folder: Outbox::MISC_FOLDER,
        season_id: plan.season_id, applied_locally:, held: false, data_root: @data_root,
        origin: { 'producer' => 'maintenance', 'operation_key' => run.operation_key, 'operation_run_id' => run.id,
                  'preview_run_id' => run.parent_run_id, 'health_finding_id' => run.health_finding_id }.compact
      )
    rescue StandardError => e
      raise e unless tmp_path

      raise Outbox::Error, I18n.t('maintenance.executor.outbox_failed', error: "#{e.class}: #{e.message}", path: tmp_path.to_s)
    end

    def after_apply!(plan, script)
      health_run = enqueue_health_run(plan)
      generation = DataFix::Pipeline.bump_db_generation! if operation.class.bumps_db_generation
      run.finish!(status: 'succeeded', applied_locally: true, sql_script_id: script.persisted? ? script.id : nil,
                  **plan_attributes(plan),
                  summary: run.parent_run.summary_hash.merge('sql_rel_path' => script.rel_path, 'sql_filename' => script.filename,
                                                             'health_run_id' => health_run&.id, 'db_generation' => generation).compact)
      link_finding!
      record_event('maintenance.applied', 'success', script:)
      Outbox::Notifier.ping
      SeasonBoard::Notifier.ping
    end

    def enqueue_health_run(plan)
      return if plan.season_id.blank? || plan.health_group.blank?

      Health::SeasonRunJob.enqueue(season_id: plan.season_id, group: plan.health_group, trigger: 'after_operation')
    rescue StandardError => e
      Rails.logger.error("[Maintenance::Executor] health re-run not queued: #{e.class}: #{e.message}")
      nil
    end

    def link_finding!
      return if run.health_finding_id.blank?

      Ops.safely { Ops::HealthFinding.where(id: run.health_finding_id).update_all(mitigation_run_id: run.id, updated_at: Time.current) } # rubocop:disable Rails/SkipsModelValidations
    end

    # == script_only (rake, phase 13)

    def script_only!
      return refuse!(:unknown_operation) unless operation

      plan = operation.plan
      return refuse!(:blocked, **plan_attributes(plan)) if plan.blocked?
      return refuse!(:empty, **plan_attributes(plan)) if plan.empty?

      script = register!(plan, applied_locally: false)
      run.finish!(status: 'succeeded', applied_locally: false, sql_script_id: script.persisted? ? script.id : nil,
                  **plan_attributes(plan), summary: preview_summary(plan).merge('sql_rel_path' => script.rel_path,
                                                                                'sql_filename' => script.filename))
      record_event('maintenance.script_written', 'info', script:)
    end

    # == helpers

    def plan_attributes(plan)
      {
        label: plan.label.to_s.truncate(250), season_id: plan.season_id || run.season_id,
        console: Ops::OperationRun.cap(plan.console, Ops::OperationRun::CONSOLE_LIMIT),
        warnings: plan.warnings.map(&:to_s), error_messages: plan.errors.map(&:to_s),
        sql_preview: Ops::OperationRun.cap(plan.sql_lines.join("\n"), Ops::OperationRun::SQL_PREVIEW_LIMIT),
        sql_digest: plan.sql_lines.any? ? plan.digest : nil
      }.merge(subject_attributes)
    end

    def subject_attributes
      type, id = safe_subject
      type ? { subject_type: type.to_s, subject_id: id } : {}
    end

    def safe_subject
      operation&.subject
    rescue StandardError
      nil
    end

    def safe_file_base
      operation.file_base
    rescue StandardError
      nil
    end

    def refuse!(reason, message: nil, **attributes)
      run.refuse!(reason, message:, **attributes)
      record_event('maintenance.refused', 'warning', reason:) unless run.preview?
    end

    def fail!(messages, **attributes)
      run.finish!(status: 'failed', **attributes, error_messages: messages)
      record_event('maintenance.apply_failed', 'error') unless run.preview?
    end

    def other_apply_of?(parent)
      parent.applies_of_preview.where.not(id: run.id).exists?(status: Ops::OperationRun::PENDING_STATUSES + ['succeeded'])
    end

    def restore_in_progress?
      lock = '::DbRestore::Lock'.safe_constantize
      lock.respond_to?(:active?) && lock.active?
    end

    def gate_message(gate)
      gate.respond_to?(:summary) ? gate.summary : Array(gate.reasons).join(' • ')
    end

    # tmp/maintenance/<run id>.sql (same bytes as the Outbox script).
    def write_tmp(plan)
      FileUtils.mkdir_p(@tmp_dir)
      path = @tmp_dir.join("#{run.id}.sql")
      File.binwrite(path, plan.sql_text)
      path
    end

    # The Data-Fix sources of the season under review (they may reference rows the apply changes).
    def reviews_in_progress(season_id)
      return [] if season_id.blank?

      Ops.safely([]) do
        Ops::PipelineSource.where(season_id:, stage: REVIEW_STAGES).order(:base).limit(MAX_REVIEWS_LISTED)
                           .map { |source| { 'base' => source.base, 'stage' => source.stage, 'source_path' => source.source_path } }
      end
    end

    def record_event(kind, level, script: nil, reason: nil)
      Ops.record_event!(
        kind:, level:, actor: run.started_by ? 'operator' : 'system', season_id: run.season_id,
        subject_type: 'operation_run', subject_key: run.id,
        data: { 'operation_key' => run.operation_key, 'mode' => run.mode, 'label' => run.label, 'reason' => reason&.to_s,
                'sql_filename' => script&.filename, 'health_finding_id' => run.health_finding_id }.compact,
        link_path: Rails.application.routes.url_helpers.maintenance_run_path(run)
      )
    end
  end
end
