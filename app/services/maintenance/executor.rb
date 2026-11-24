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
  # Phase 13: the script goes to Operation#outbox_folder ('misc', or the season folder of 'standard_timings.import')
  # and starts held when Operation#held_reason says so; Operation#after_local_apply adds its text to the console of a
  # succeeded apply; a long plan reports its progress (Operation#report_progress => run.progress, at most every
  # PROGRESS_INTERVAL) and stops with the refusal 'cancelled' once the operator asked for it (run.cancel_requested_at).
  # The rake callers (Maintenance::RakeRunner) read #plan / #operation after #call and pass the exact script bytes of
  # the former tasks (+script_text+), their 'index=' (+script_prefix+) and their task name (+origin+).
  #
  # The Outbox always holds what ran on the local DB (phase 13 review):
  # - a script with several transaction blocks (Maintenance::ScriptBlocks, e.g. 'season.badge_fix': one per badge)
  #   is run block by block; when a block fails after others ran, the blocks that ran are registered as a PARTIAL
  #   script and the run fails naming the block (the next dry run plans what is left); nothing that ran is lost;
  # - when the Outbox registration fails AFTER a local apply, the run fails with applied_locally true and the SQL
  #   that ran stays in tmp/maintenance/<run id>.sql ('unregistered_sql_path' in the summary): the run page and the
  #   rake task say so (register it by hand, never run it again);
  # - an operation's #held_reason is stored in the script origin ('held_after_local_apply'): a script-only script
  #   applied later from the Outbox goes back to that hold (Outbox::Writer.mark_applied_locally!).
  #
  # Never raises: an unexpected error closes the run as failed.
  #
  class Executor # rubocop:disable Metrics/ClassLength
    TMP_DIR = Rails.root.join('tmp/maintenance')
    # Data-Fix stages counted as "reviews in progress" on the dry run.
    REVIEW_STAGES = %w[preparing needs_review blocked ready_to_commit committing].freeze
    MAX_REVIEWS_LISTED = 20
    # Minimum delay between two progress writes / cancel checks of a long plan.
    PROGRESS_INTERVAL = 1.0

    # The run; the last plan computed by #call (nil before); the text added by Operation#after_local_apply.
    attr_reader :run, :plan, :after_apply_output

    # == Params
    # - run: the Ops::OperationRun (queued);
    # - data_root: crawler data root of the Outbox (specs: a temporary folder); sql_runner: LocalDb::SqlRunner (or a
    #   stand-in answering .call(path:)); gate: Drift::Gate (or a stand-in answering .check(scope:, acknowledged:, force:));
    # - gate_scope / gate_force: :operation (UI) by default; a rake caller (phase 13) passes :rake and its force=1.
    # - script_text: callable (plan => String) giving the script bytes (default Plan#sql_text); script_prefix: an
    #   explicit file number (rake 'index='); script_name: the name instead of Operation#file_base (the former rake
    #   names); origin: extra keys of the Outbox origin (rake task name and args).
    def initialize(run:, data_root: Outbox.data_root, sql_runner: LocalDb::SqlRunner, gate: Drift::Gate, tmp_dir: TMP_DIR, # rubocop:disable Metrics/ParameterLists
                   gate_scope: :operation, gate_force: false, script_text: nil, script_prefix: nil, script_name: nil, origin: {})
      @run = run
      @gate_scope = gate_scope
      @gate_force = gate_force
      @data_root = Pathname.new(data_root)
      @sql_runner = sql_runner
      @gate = gate
      @tmp_dir = Pathname.new(tmp_dir)
      @script_text = script_text
      @script_prefix = script_prefix
      @script_name = script_name
      @origin = origin.to_h.stringify_keys
    end

    # The operation of the run (built once from its params; nil when the key is unknown).
    def operation
      @operation ||= run.operation&.tap { |op| op.progress_reporter = method(:report_progress) }
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
    rescue Maintenance::Cancelled
      refuse!(:cancelled, progress: nil)
    rescue StandardError => e
      Rails.logger.error("[Maintenance::Executor] run #{run.id}: #{e.class}: #{e.message}")
      Rails.logger.debug { e.backtrace&.first(15)&.join("\n") }
      fail!(["#{e.class}: #{e.message}".truncate(2000)])
    end

    # == progress (phase 13)

    # Stores the progress of a long plan on the run (throttled) and raises Maintenance::Cancelled when the operator
    # asked to cancel it.
    def report_progress(done, total, label)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      return if @progress_at && now - @progress_at < PROGRESS_INTERVAL && done.to_i < total.to_i

      @progress_at = now
      Ops.safely do
        run.update_columns(progress: { 'done' => done.to_i, 'total' => total.to_i, 'label' => label.to_s.truncate(200) }, # rubocop:disable Rails/SkipsModelValidations
                           updated_at: Time.current)
      end
      Notifier.ping(run)
      raise Maintenance::Cancelled if cancel_requested?
    end

    def cancel_requested?
      Ops.safely(false) { Ops::OperationRun.where(id: run.id).where.not(cancel_requested_at: nil).exists? }
    end

    # == preview

    def preview!
      return refuse!(:unknown_operation) unless operation

      plan = plan_now
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

      plan = plan_now
      return refuse!(:digest_changed, **plan_attributes(plan)) if plan.digest != parent.sql_digest
      return refuse!(:blocked, **plan_attributes(plan)) if plan.blocked?
      return refuse!(:empty, **plan_attributes(plan)) if plan.empty?

      apply_locally!(plan)
    end

    # The plan of the run (kept for the rake callers).
    def plan_now
      @plan = operation.plan
    end

    def apply_locally!(plan)
      blocks = ScriptBlocks.split(plan.sql_lines)
      blocks.size > 1 ? apply_blocks!(plan, blocks) : apply_whole!(plan)
    end

    # One transaction: run the script, then register it.
    def apply_whole!(plan)
      tmp_path = write_tmp(plan)
      result = @sql_runner.call(path: tmp_path)
      return local_apply_failed!(plan, result, tmp_path) unless result.success?

      register_applied!(plan, plan)
    end

    # Several transaction blocks (not atomic together): each one runs alone; tmp/maintenance/<run id>.sql holds the
    # blocks that ran so far (kept if the worker dies). A failure after the first block registers the blocks that ran.
    def apply_blocks!(plan, blocks)
      applied = []
      blocks.each_with_index do |lines, index|
        block_path = write_tmp(plan.with(sql_lines: lines), suffix: "-block-#{index + 1}")
        result = @sql_runner.call(path: block_path)
        FileUtils.rm_f(block_path)
        unless result.success?
          return local_apply_failed!(plan, result, @tmp_dir.join("#{run.id}.sql")) if applied.empty?

          return register_applied!(partial_plan(plan, applied, index, blocks.size), plan,
                                   partial: { 'applied_blocks' => index, 'total_blocks' => blocks.size, 'error' => result.stderr.to_s.strip.truncate(4000) })
        end
        applied.concat(lines)
        write_tmp(plan.with(sql_lines: applied))
      end
      register_applied!(plan, plan)
    end

    # The blocks that ran, behind a comment naming the partial apply.
    def partial_plan(plan, applied_lines, failed_index, total)
      note = "-- PARTIAL LOCAL APPLY (operation run #{run.id}): blocks 1-#{failed_index} of #{total} ran on the local DB; " \
             "block #{failed_index + 1} failed and nothing after it ran."
      plan.with(sql_lines: [note, *applied_lines])
    end

    def local_apply_failed!(plan, result, tmp_path)
      FileUtils.rm_f(tmp_path)
      fail!([I18n.t('maintenance.executor.local_apply_failed', error: result.stderr.to_s.strip.truncate(4000))], **plan_attributes(plan))
    end

    # The local DB changed with +script_plan+ (the whole +plan+, or its blocks that ran): register exactly that. When the
    # Outbox write fails, the SQL that ran stays in tmp/maintenance/<run id>.sql and the run says so.
    def register_applied!(script_plan, plan, partial: nil)
      tmp_path = write_tmp(script_plan)
      begin
        script = register!(script_plan, applied_locally: true, tmp_path:)
      rescue Outbox::Error => e
        return applied_unregistered!(plan, tmp_path, e, partial:)
      end
      FileUtils.rm_f(tmp_path)
      partial ? applied_partially!(plan, script, partial) : after_apply!(plan, script)
    end

    # Some blocks ran and were registered, then one failed: the run fails, the local DB and the Outbox agree.
    def applied_partially!(plan, script, partial) # rubocop:disable Metrics/AbcSize
      health_run = enqueue_health_run(plan)
      generation = DataFix::Pipeline.bump_db_generation! if operation.class.bumps_db_generation
      message = I18n.t('maintenance.executor.partial_apply', applied: partial['applied_blocks'], total: partial['total_blocks'],
                                                             block: partial['applied_blocks'] + 1, file: script.filename, error: partial['error'])
      run.finish!(status: 'failed', applied_locally: true, sql_script_id: script.persisted? ? script.id : nil, **plan_attributes(plan),
                  error_messages: [message],
                  summary: run.parent_run.summary_hash.merge('sql_rel_path' => script.rel_path, 'sql_filename' => script.filename,
                                                             'partial' => partial.except('error'), 'health_run_id' => health_run&.id,
                                                             'db_generation' => generation).compact)
      record_event('maintenance.apply_failed', 'error', script:)
      Outbox::Notifier.ping
      SeasonBoard::Notifier.ping
    end

    # The SQL ran locally but its Outbox registration failed: never lost, kept in tmp and named on the run.
    def applied_unregistered!(plan, tmp_path, error, partial: nil)
      enqueue_health_run(plan)
      DataFix::Pipeline.bump_db_generation! if operation.class.bumps_db_generation
      messages = [error.message]
      if partial
        messages.unshift(I18n.t('maintenance.executor.partial_apply_unregistered', applied: partial['applied_blocks'],
                                                                                   total: partial['total_blocks'], error: partial['error']))
      end
      run.finish!(status: 'failed', applied_locally: true, **plan_attributes(plan), error_messages: messages,
                  summary: run.parent_run.summary_hash.merge('unregistered_sql_path' => tmp_path.to_s, 'outbox_folder' => operation.outbox_folder,
                                                             'partial' => partial&.except('error')).compact)
      record_event('maintenance.apply_failed', 'error')
      SeasonBoard::Notifier.ping
    end

    # The local DB changed: the script MUST be registered. When the Writer fails, the temporary file is kept and named
    # in the error, so that the operator can register it by hand.
    def register!(plan, applied_locally:, tmp_path: nil) # rubocop:disable Metrics/AbcSize
      held_reason = applied_locally ? operation.held_reason : nil
      after_apply_hold = { 'held_after_local_apply' => operation.held_reason }.compact
      Outbox::Writer.write!(
        kind: operation.class.outbox_kind, name: @script_name || operation.file_base, sql: script_text(plan), folder: operation.outbox_folder,
        season_id: plan.season_id, applied_locally:, held: held_reason.present?, held_reason:, data_root: @data_root,
        prefix: @script_prefix,
        origin: { 'producer' => 'maintenance', 'operation_key' => run.operation_key, 'operation_run_id' => run.id,
                  'preview_run_id' => run.parent_run_id, 'health_finding_id' => run.health_finding_id }.compact.merge(after_apply_hold, @origin)
      )
    rescue StandardError => e
      raise e unless tmp_path

      raise Outbox::Error, I18n.t('maintenance.executor.outbox_failed', error: "#{e.class}: #{e.message}", path: tmp_path.to_s)
    end

    def after_apply!(plan, script) # rubocop:disable Metrics/AbcSize
      health_run = enqueue_health_run(plan)
      generation = DataFix::Pipeline.bump_db_generation! if operation.class.bumps_db_generation
      attributes = plan_attributes(plan)
      @after_apply_output = after_local_apply_output(plan)
      if @after_apply_output.present?
        attributes[:console] =
          Ops::OperationRun.cap([attributes[:console].presence, @after_apply_output].compact.join("\n"),
                                Ops::OperationRun::CONSOLE_LIMIT)
      end
      run.finish!(status: 'succeeded', applied_locally: true, sql_script_id: script.persisted? ? script.id : nil,
                  **attributes,
                  summary: run.parent_run.summary_hash.merge('sql_rel_path' => script.rel_path, 'sql_filename' => script.filename,
                                                             'health_run_id' => health_run&.id, 'db_generation' => generation).compact)
      link_finding!
      record_event('maintenance.applied', 'success', script:)
      Outbox::Notifier.ping
      SeasonBoard::Notifier.ping
    end

    # What Operation#after_local_apply printed and returned (never raises: the apply already succeeded).
    def after_local_apply_output(plan)
      text, console = OutputCapture.capture { operation.after_local_apply(plan) }
      [console.presence, text.presence].compact.join("\n").presence
    rescue StandardError => e
      Rails.logger.error("[Maintenance::Executor] after_local_apply: #{e.class}: #{e.message}")
      nil
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

      plan = plan_now
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
      parent.consuming_applies.where.not(id: run.id).exists?
    end

    def restore_in_progress?
      lock = '::DbRestore::Lock'.safe_constantize
      lock.respond_to?(:active?) && lock.active?
    end

    def gate_message(gate)
      gate.respond_to?(:summary) ? gate.summary : Array(gate.reasons).join(' • ')
    end

    # tmp/maintenance/<run id><suffix>.sql (same bytes as the Outbox script).
    def write_tmp(plan, suffix: '')
      FileUtils.mkdir_p(@tmp_dir)
      path = @tmp_dir.join("#{run.id}#{suffix}.sql")
      File.binwrite(path, script_text(plan))
      path
    end

    # The script bytes (Plan#sql_text unless the caller gave its own format).
    def script_text(plan)
      @script_text ? @script_text.call(plan) : plan.sql_text
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
