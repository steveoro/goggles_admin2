# frozen_string_literal: true

require 'digest'

#
# = DataFixPrepareJob
#
# Prepares ONE Data-Fix source unattended (phase 10): builds phases 1..up_to through DataFix::Pipeline#prepare!
# (missing phases, stale unedited ones), computes the verdicts and stores the stage ('ready_to_commit',
# 'needs_review', ...), so that the Season board and the inbox show "Ready to commit" or "Needs review at step N"
# without a click. It never commits and never pushes: the local commit (DataFixCommitJob) and the push
# (Outbox::PushJob) stay one operator click each (spec/automation_boundary_spec.rb).
#
# Enqueued only through SeasonBoard::Scheduler.prepare! (the planner, origin 'auto'; the board "Prepare" / "Retry"
# buttons, origin 'operator'), which writes the queued Ops::PipelineRun (+run_id+).
#
# == Rules
# - Never raises, no retries (no retry_on / discard_on): every error closes the run as 'failed', stores the
#   source stage 'failed' with the source SHA256 (the planner re-queues it only after the source changed).
# - Start guards, in order: the 'automation.auto_prepare' switch (origin 'auto' only), the ops DB, DataFix::Guards
#   (:prepare: Drift::Gate, later DbRestore::Lock), the source file still in results.new, no commit of the source
#   pending. A refused start ends the run 'refused' with its reason; a DB sync 'block' (red) refuses, a 'warn'
#   builds and notes the warning on the run.
# - Operator edits win: an automatic run (origin 'auto') refuses a source holding any edited phase (adopted
#   pre-existing files included); prepare! never rebuilds an edited phase; the harmonizer never writes an edited
#   phase 2 during an automatic build.
# - Lease: the whole run holds the pipeline_sources lease as 'job:<job id>' (TTL: the soft deadline plus
#   LEASE_MARGIN), released in ensure; a held lease refuses the run ('lease_busy').
# - Source resolution (DataFix::SourceResolver#resolve_working_source_path can rewrite the LT4 working copy, replace a
#   manifest copy, normalize categories and invalidate phases): an automatic run takes the lease and checks the edits
#   FIRST, on the working copy computed without side effects, and never runs those branches on a source that already
#   has phase files: such a source is refused ('source_needs_review', the operator opens it). A source without phase
#   files is resolved as the review pages do (nothing to lose); an operator run resolves first, as an interactive open.
# - Fail closed: an unreadable switch is off, an unreadable commit-pending check counts as pending, an unreadable
#   queued-commit check yields.
# - Soft deadline (DEADLINE, checked between phases): exceeded => 'failed' with reason 'deadline'.
# - Yield to commit: between phases, a queued Ops::CommitReport ends the run 'yielded' (the planner queues it again).
# - Source changed mid-run (SHA256 differs at the end): the verdicts are recomputed (stale) and the next planner pass
#   decides.
# - Progress: Import::Progress::Ops on the run row (about 1 write per second), SeasonBoard::Notifier pings at the
#   phase boundaries; never ImportStatusChannel.
# - A run ending 'done' enqueues PipelinePlannerJob (the next source); a refused, failed or yielded run does not.
# - Activity log (SeasonBoard::ActivityLog, kind :prepare, under the FIN id passed by the Scheduler, else the one stored
#   on the run's source row): every way out of #perform closes the entry (refusals before the run starts and a missing
#   ops DB included), and so does a run skipped by a DB restore (#skipped_by_db_restore: the run is closed 'refused',
#   reason 'db_restore', and the job is dropped as every job skipped by a restore; the planner queues it again later).
#   SeasonBoard::ActivityReconciler closes what a killed job could not.
#
class DataFixPrepareJob < ApplicationJob # rubocop:disable Metrics/ClassLength
  queue_as :pipeline
  # (Solid Queue: a lower value runs first; DataFixCommitJob uses 0)
  queue_with_priority 10

  # Not 'local_db_writer' (DataFixCommitJob, Maintenance::RunJob): both jobs share the single-thread 'pipeline'
  # worker, which serialises them anyway.
  limits_concurrency key: 'data_fix_pipeline', to: 1, duration: 1.hour

  # Soft deadline of a run, checked between phases. Benchmark (phase 10 step 1, RAILS_ENV=test on a production-size
  # DB copy): the largest season 262 source (1.3 MB LT4, 1 189 results) prepared in 18 s, a 3.7 MB national
  # championship (4 105 results, 1 108 relays) in 104 s, phase 3 (swimmers) dominating: 20 minutes stays well above
  # 3x the worst case.
  DEADLINE = 20.minutes
  # Lease expiry = deadline + margin.
  LEASE_MARGIN = 5.minutes
  MODES = SeasonBoard::Scheduler::PREPARE_MODES

  # Overridable in specs.
  class_attribute :deadline, default: DEADLINE

  # Ops::Event level per final run status (yielded runs record no event).
  EVENT_LEVELS = { 'done' => 'success', 'failed' => 'error', 'refused' => 'warning' }.freeze

  # Internal: the soft deadline passed between two phases.
  class DeadlineExceeded < StandardError; end

  # Internal: ends the run with +status+ ('refused', 'yielded') and +reason+.
  class Stop < StandardError
    attr_reader :status, :reason

    def initialize(status, reason)
      @status = status
      @reason = reason.to_s
      super("#{status}: #{reason}")
    end
  end

  # == Params
  # - source_path: the source (LT2/LT4/phase file; the canonical LT4 working copy is resolved here);
  # - season_id: board season (snapshot invalidation); origin: 'auto' | 'operator';
  # - up_to: last phase to build (5; 1 for result-free sources); mode: 'prepare' | 'rebuild_stale' |
  #   'refresh_new_entities'; phases: optional subset (e.g. [5] after a collision cleared);
  # - run_id: the queued Ops::PipelineRun (created here when missing); fin_event_id: the board row (ActivityLog).
  def perform(source_path:, season_id:, origin:, up_to: 5, mode: 'prepare', phases: nil, run_id: nil, fin_event_id: nil) # rubocop:disable Metrics/ParameterLists
    setup(source_path:, season_id:, origin:, mode:, run_id:, fin_event_id:)
    return unless start_run!

    check_start_guards!
    prepare!(up_to:, phases:)
  rescue Stop => e
    close!(e.status, reason: e.reason)
  rescue DeadlineExceeded
    close!('failed', reason: 'deadline')
  rescue DataFix::Pipeline::LeaseBusyError => e
    close!('refused', reason: "lease_busy: #{e.message}".truncate(250))
  rescue StandardError => e
    Rails.logger.error("[DataFixPrepareJob] #{@source_path}: #{e.class}: #{e.message}")
    Rails.logger.debug { e.backtrace&.first(15)&.join("\n") }
    close!('failed', reason: 'error', error: "#{e.class}: #{e.message}")
  ensure
    close!('failed', reason: 'interrupted') unless @closed
    after_run
  end

  private

  def setup(source_path:, season_id:, origin:, mode:, run_id:, fin_event_id:) # rubocop:disable Metrics/ParameterLists
    @source_path = source_path.to_s
    @season_id = Integer(season_id, exception: false)
    @origin = origin.to_s == 'auto' ? 'auto' : 'operator'
    @mode = MODES.include?(mode.to_s) ? mode.to_s : 'prepare'
    @run_id = run_id
    @fin_event_id = fin_event_id.presence&.to_s
    @closed = false
    @status = nil
    @phase = nil
  end

  # Moves the run to 'running' (creating it when missing). Without the ops DB nothing can be recorded: returns false.
  def start_run! # rubocop:disable Naming/PredicateMethod
    @run = Ops.safely { find_or_create_run if Ops.available? }
    unless @run
      Rails.logger.warn("[DataFixPrepareJob] #{@source_path}: refused, the ops DB is not available")
      @closed = true
      activity_finish(:failed, I18n.t('pipeline_automation.reasons.ops_unavailable'))
      return false
    end

    Ops.safely { @run.update!(status: 'running', started_at: Time.current, job_id:, origin: @origin) }
    @fin_event_id ||= run_fin_event_id
    activity_start
    true
  end

  # FIN id stored on the source row of the run (a job queued before 0.10.99 carries none), or nil.
  def run_fin_event_id
    Ops.safely { @run&.pipeline_source&.fin_event_id.presence&.to_s }
  end

  def find_or_create_run
    run = Ops::PipelineRun.find_by(id: @run_id) if @run_id
    run || Ops::PipelineRun.create!(subject_key: Ops::PipelineSource.base_for(@source_path), kind: 'prepare', origin: @origin,
                                    status: 'queued', message: @mode)
  end

  # Raises Stop('refused', reason) for the first failing guard.
  def check_start_guards!
    raise Stop.new('refused', 'automation_paused') if @origin == 'auto' && !DataFix::Automation.enabled?(:auto_prepare)

    guards = DataFix::Guards.check(:prepare)
    raise Stop.new('refused', "#{guards.verdict == :restore ? 'db_restore' : 'drift_red'}: #{guards.message}".truncate(250)) if guards.block?

    @drift_warning = guards.message.presence if guards.warn?
    raise Stop.new('refused', 'source_missing') unless File.exist?(@source_path) && results_new_path?(@source_path)
  end

  # True for a file inside a 'results.new' folder (never results.done / results.sent).
  def results_new_path?(path)
    Pathname.new(path).expand_path.each_filename.include?('results.new')
  end

  def prepare!(up_to:, phases:)
    @resolver = DataFix::SourceResolver.new
    @origin == 'auto' ? load_pipeline!(expected_working_path, must_exist: false) : load_pipeline!(resolved_working_path)
    raise Stop.new('refused', 'commit_pending') if commit_pending?

    resolve_fresh_automatic_source! if @origin == 'auto'
    @pipeline.hold_lease!(ttl: deadline + LEASE_MARGIN) do
      raise Stop.new('refused', 'edited') if refuse_edited?
      raise Stop.new('refused', 'source_needs_review') if @origin == 'auto' && destructive_resolution?

      build!(up_to:, phases:)
    end
    finish_prepare!
  end

  # The builds of the run (inside the lease).
  def build!(up_to:, phases:)
    up_to = [up_to.to_i, 1].min if @pipeline.result_free? # (a result-free source commits Phase 1 only)
    @start_sha = sha256(@working_path)
    @deadline_at = Time.current + deadline
    mark_source!(stage: 'preparing')
    run_mode!(up_to:, phases:)
  end

  # Builds the DataFix::Pipeline of +path+ (lease owner 'job:<job id>', progress on the run row) and attaches the run
  # to its source row. (+must_exist+ false: the LT4 working copy of a fresh LT2 source is created later.)
  def load_pipeline!(path, must_exist: true)
    raise Stop.new('refused', 'source_missing') if path.blank? || (must_exist && !File.exist?(path))

    @working_path = path
    @pipeline = DataFix::Pipeline.for(path, progress: Import::Progress::Ops.new(@run), actor: :auto, source_resolver: @resolver,
                                            lease_owner:)
    attach_source!
  end

  def lease_owner = "#{Ops::PipelineSource::JOB_LEASE_PREFIX}#{job_id}"

  # Operator run: the canonical working copy resolved as an interactive open of the review pages does.
  def resolved_working_path
    @resolver.resolve_working_source_path(@source_path)
  end

  # Automatic run: the canonical working copy the resolver would return, computed WITHOUT side effects (a phase file
  # leads to its source, an LT2 '<base>.json' to its '<base>-lt4.json').
  def expected_working_path
    path = @resolver.resolve_source_path(@source_path).to_s
    return path if path.end_with?('-lt4.json') || !File.exist?(path)

    @resolver.detect_layout_type(path) == 2 ? path.sub(/\.json\z/, '-lt4.json') : path
  end

  # Automatic run on a source WITHOUT phase files (nothing to lose): resolved as the review pages do (it may create the
  # LT4 working copy and normalize its categories), once nobody else holds the lease.
  def resolve_fresh_automatic_source!
    return if phase_files?
    raise DataFix::Pipeline::LeaseBusyError, "#{@pipeline.base} is being built" if leased_by_other?

    resolved = resolved_working_path.to_s
    load_pipeline!(resolved) unless resolved == @working_path && File.exist?(resolved)
  end

  def phase_files?
    DataFix::Pipeline::PHASES.any? { |phase| @pipeline.phase_exists?(phase) }
  end

  def leased_by_other?
    Ops.safely(true) { @pipeline.source_row&.reload&.leased_by_other?(lease_owner) || false }
  end

  # True when the resolver would rewrite the working copy of a source that already has phase files: no LT4 working
  # copy yet, an LT2 payload under the -lt4 name, a manifest copy superseded by published results, or result
  # categories to normalize. Any error counts as true (fail closed).
  def destructive_resolution?
    return false unless phase_files?
    return true unless File.exist?(@working_path) && @working_path.end_with?('-lt4.json')
    return true if @resolver.detect_layout_type_from_content(@working_path) == 2

    lt2_path = @resolver.paired_lt2_source_path(@working_path)
    (lt2_path && @resolver.manifest_copy_superseded?(@working_path, lt2_path)) || categories_need_normalization?
  rescue StandardError => e
    Rails.logger.warn("[DataFixPrepareJob] #{@working_path}: resolution check failed (#{e.class}: #{e.message}), refused")
    true
  end

  # The resolver's category normalization would rewrite the source (and invalidate phases 3-5).
  def categories_need_normalization?
    season = GogglesDb::Season.find_by(id: Ops::PipelineSource.season_id_for(@working_path))
    return false unless season # (the resolver skips it too)

    @resolver.lt4_result_categories_need_normalization?(@resolver.parsed_source_json(@working_path), PdfResults::CategoriesCache.cached_for(season))
  end

  # A commit of the source is queued or running (an unreadable check counts as pending: fail closed).
  def commit_pending?
    Ops.safely(true) { Ops::CommitReport.pending.for_base(@pipeline.base).exists? }
  end

  # An automatic run never touches a source holding operator edits (adopted pre-existing files included); a
  # matches refresh never runs on one either (it writes phases 2 and 3).
  def refuse_edited?
    (@origin == 'auto' || @mode == 'refresh_new_entities') && @pipeline.any_edited?
  end

  def run_mode!(up_to:, phases:)
    case @mode
    when 'refresh_new_entities'
      boundary!(2)
      @pipeline.refresh_new_entities!
    when 'rebuild_stale'
      phases.present? ? rebuild_phases!(Array(phases).map(&:to_i)) : @pipeline.prepare!(up_to:, deadline: @deadline_at, stop_if: method(:boundary))
    else
      @pipeline.prepare!(up_to:, phases:, deadline: @deadline_at, stop_if: method(:boundary))
    end
    stop = @pipeline.last_prepare_stop
    raise Stop.new('yielded', 'commit_queued') if stop == :yielded
    raise DeadlineExceeded if stop == :deadline
  end

  # Rebuilds the given (unedited) phases even when not stale (e.g. phase 5 after the colliding source was committed).
  def rebuild_phases!(phases)
    phases.sort.each do |phase|
      raise DeadlineExceeded if Time.current > @deadline_at

      boundary!(phase)
      next if @pipeline.edited?(phase)

      @pipeline.build_phase!(phase)
    end
  end

  # Phase boundary (prepare! stop_if callback): records the phase, pings the board, yields to a queued commit.
  def boundary(phase)
    boundary!(phase)
    :yielded if Ops.safely(true) { Ops::CommitReport.exists?(status: 'queued') } # (unreadable: yield, fail closed)
  end

  def boundary!(phase)
    @phase = phase
    Ops.safely { @run.update_columns(phase:, message: I18n.t('pipeline_automation.run.building', phase:), updated_at: Time.current) } # rubocop:disable Rails/SkipsModelValidations
    SeasonBoard::Notifier.ping
  end

  def finish_prepare!
    summary = @pipeline.summary
    if sha256(@working_path) != @start_sha
      summary = @pipeline.reload!.summary(refresh: true)
      return close!('done', reason: 'source_changed', stage: summary.stage)
    end

    mark_source!(prepared_at: Time.current, failed_source_sha256: nil)
    close!('done', stage: summary.stage)
  end

  # == Closing

  # Closes the run once (status: done | failed | refused | yielded), updates the source row, the activity log and the
  # event log. Never raises.
  # The activity entry is closed first, and each step runs on its own (#close_step): a failing step never leaves the
  # board row "queued" or "running".
  def close!(status, reason: nil, error: nil, stage: nil)
    return if @closed

    @closed = true
    @status = status
    unsuccessful = %w[failed refused].include?(status)
    message = close_step(status.to_s) { close_message(status, reason, stage) }
    activity_finish(unsuccessful ? :failed : :done, message)
    close_step { close_run(status, message, error || (reason if unsuccessful)) }
    close_step { fail_source!(error || reason) } if status == 'failed'
    close_step { release_stage! } if %w[refused yielded].include?(status)
    close_step { record_event(status, message) }
  end

  # Runs one closing step, logging (never raising) its error; returns its value, or +fallback+ on error.
  def close_step(fallback = nil)
    yield
  rescue StandardError => e
    Rails.logger.error("[DataFixPrepareJob] closing step failed: #{e.class}: #{e.message}")
    fallback
  end

  def close_run(status, message, error)
    Ops.safely { @run&.finish!(status:, error:) }
    Ops.safely { @run&.update_columns(message: message.truncate(250), phase: @phase) } # rubocop:disable Rails/SkipsModelValidations
  end

  def close_message(status, reason, stage)
    key = status == 'done' && reason.present? ? 'done_with_reason' : status
    text = I18n.t("pipeline_automation.run.#{key}", reason: reason_text(reason), stage: stage_text(stage), phase: @phase || '-')
    @drift_warning ? "#{text} (#{I18n.t('pipeline_automation.run.drift_warning', warning: @drift_warning)})" : text
  end

  def reason_text(reason)
    return '' if reason.blank?

    code, detail = reason.to_s.split(': ', 2)
    text = I18n.t("pipeline_automation.reasons.#{code}", default: code)
    detail ? "#{text}: #{detail}" : text
  end

  def stage_text(stage)
    stage.present? ? I18n.t("pipeline_automation.stages.#{stage}", default: stage.to_s) : ''
  end

  # Source row: the run is attached to it (pipeline_source_id) once the working copy is known.
  def attach_source!
    row = @pipeline.source_row
    return unless row

    Ops.safely { @run.update_columns(pipeline_source_id: row.id, subject_key: row.base) } # rubocop:disable Rails/SkipsModelValidations
    @fin_event_id = row.fin_event_id.presence if @fin_event_id.blank?
  end

  def mark_source!(**attributes)
    row = @pipeline&.source_row
    Ops.safely { row&.update_columns(**attributes, updated_at: Time.current) } # rubocop:disable Rails/SkipsModelValidations
  end

  def fail_source!(reason)
    row = @pipeline&.source_row || Ops.safely { Ops::PipelineSource.find_by(id: @run&.pipeline_source_id) }
    return unless row

    sha = @start_sha || sha256(@working_path || @source_path)
    Ops.safely do
      row.update_columns(stage: 'failed', failed_source_sha256: sha.presence, stage_reason: nil, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    end
    Rails.logger.warn("[DataFixPrepareJob] #{row.base}: prepare failed (#{reason})")
  end

  # A refused or yielded run leaves no 'preparing' stage behind: the stored verdicts decide again.
  def release_stage!
    row = @pipeline&.source_row
    return unless row && Ops.safely(false) { row.reload.stage == 'preparing' }

    Ops.safely { @pipeline.summary }
  end

  def sha256(path)
    path.present? && File.exist?(path) ? Digest::SHA256.file(path).hexdigest : ''
  rescue SystemCallError
    ''
  end

  # == DB restore

  # Called by ApplicationJob instead of #perform while a DB restore holds the lock (DbRestore::JobGuard has recorded the
  # skip): closes the queued run as 'refused' (reason 'db_restore') and its activity entry, so that the board row does
  # not stay "prepare queued". Reads the ops DB and the activity log only (never MySQL). Never raises.
  def skipped_by_db_restore
    options = arguments.first.is_a?(Hash) ? arguments.first.symbolize_keys : {}
    setup(**options.slice(:source_path, :season_id, :origin, :mode, :run_id, :fin_event_id).reverse_merge(
      source_path: nil, season_id: nil, origin: nil, mode: nil, run_id: nil, fin_event_id: nil
    ))
    @run = Ops.safely { Ops::PipelineRun.find_by(id: @run_id) if @run_id && Ops.available? }
    @fin_event_id ||= run_fin_event_id
    return unless @run || @fin_event_id # (nothing was queued for it: nothing to close)

    close!('refused', reason: 'db_restore')
    after_run
  rescue StandardError => e
    Rails.logger.warn("[DataFixPrepareJob] DB restore skip not recorded: #{e.class}: #{e.message}")
  end

  # == Activity log, events, follow-up

  def activity_start
    return unless @fin_event_id

    activity_log.start!(@fin_event_id, kind: :prepare, origin: @origin == 'auto' ? :auto : :manual)
  rescue StandardError => e
    Rails.logger.warn("[DataFixPrepareJob] activity log: #{e.class}: #{e.message}")
  end

  def activity_finish(status, message)
    return unless @fin_event_id

    activity_log.finish!(@fin_event_id, kind: :prepare, status:, message: message.to_s.truncate(200))
  rescue StandardError => e
    Rails.logger.warn("[DataFixPrepareJob] activity log: #{e.class}: #{e.message}")
  end

  def activity_log
    @activity_log ||= SeasonBoard::ActivityLog.new
  end

  def record_event(status, message)
    level = EVENT_LEVELS[status]
    return unless level

    Ops.record_event!(
      kind: "pipeline.prepare_#{status}", level:, actor: @origin == 'auto' ? 'job' : 'operator', season_id: @season_id,
      subject_type: 'source', subject_key: @working_path || @source_path,
      data: { 'run_id' => @run&.id, 'mode' => @mode, 'phase' => @phase, 'message' => message, 'fin_event_id' => @fin_event_id },
      link_path: Rails.application.routes.url_helpers.season_board_path
    )
  end

  # Board refresh, then the next planner pass after a successful run (never after a refused/failed/yielded one:
  # that would loop on the same source).
  def after_run
    SeasonBoard::Snapshot.invalidate!(@season_id) if @season_id
    SeasonBoard::Notifier.ping
    PipelinePlannerJob.enqueue_after(self.class.name) if @status == 'done'
  rescue StandardError => e
    Rails.logger.warn("[DataFixPrepareJob] after run: #{e.class}: #{e.message}")
  end
end
