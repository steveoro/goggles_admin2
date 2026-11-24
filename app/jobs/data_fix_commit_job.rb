# frozen_string_literal: true

#
# = DataFixCommitJob
#
# Runs the Phase 6 commit of one queued Ops::CommitReport (DataFix::CommitRunner) on the single-thread 'pipeline'
# worker and stores the outcome on the report (reopenable at GET data_fix/commit_reports/:id).
#
# - Enqueued ONLY by DataFix::CommitsController#commit_phase6 (an operator click): never by a scheduler, a planner,
#   a callback or another job; there is no bulk commit (spec-asserted).
# - No retries (no retry_on / discard_on): a commit is never re-run by itself. Never raises: any error closes the
#   report as failed.
# - Moves the report queued -> running with a conditional update, so a duplicate perform commits once; refuses a
#   report not queued or without a requesting operator.
# - Re-runs the guards (DataFix::Guards, with the acknowledgement stored by the POST in the report preflight) and
#   Import::CommitPreflight before committing.
# - limits_concurrency key 'local_db_writer' (shared with Maintenance::RunJob in apply mode: both write the local
#   primary DB); the explicit group makes the key really shared (Solid Queue prefixes the key with the group, which
#   defaults to the job class name); priority 0 (before any prepare job of phase 10 on the same worker).
#
class DataFixCommitJob < ApplicationJob
  queue_as :pipeline
  queue_with_priority 0

  limits_concurrency key: 'local_db_writer', group: 'local_db_writer', to: 1, duration: 1.hour

  def perform(commit_report_id:)
    report = Ops.safely { Ops::CommitReport.find_by(id: commit_report_id) }
    return unless report
    return refuse(report, I18n.t('data_fix.commit.job_refused_user')) if report.requested_by_user_id.blank?
    return unless claim(report)

    run(report)
  rescue StandardError => e
    Rails.logger.error("[DataFixCommitJob] report #{commit_report_id}: #{e.class}: #{e.message}")
    Rails.logger.debug { e.backtrace&.first(15)&.join("\n") }
    Ops.safely { report&.finish!(status: 'failed', error_message: I18n.t('data_fix.commit.job_failed', error: "#{e.class}: #{e.message}").truncate(4.kilobytes)) }
  end

  private

  # Takes the report (queued -> running). A report in any other state is left as it is (a duplicate perform).
  def claim(report) # rubocop:disable Naming/PredicateMethod
    return true if report.claim!(job_id:)

    Rails.logger.warn("[DataFixCommitJob] report #{report.id} not queued (#{report.status}): refused")
    false
  end

  def refuse(report, message)
    report.queued? ? report.refuse!(message) : Rails.logger.warn("[DataFixCommitJob] #{message} (report #{report.id})")
  end

  def run(report) # rubocop:disable Metrics/AbcSize
    preflight = report.preflight.to_h
    guards = DataFix::Guards.check(:commit, acknowledged: preflight['drift_ack'] == true)
    return report.refuse!(I18n.t('data_fix.commit.job_refused_guard', reason: guards.message)) unless guards.allowed?

    pipeline = DataFix::Pipeline.for(report.source_path, progress: Import::Progress::Null.new, actor: :auto)
    check = Import::CommitPreflight.new(pipeline:, create_anyway: preflight['create_anyway'] == true).call
    unless check.ok?
      return report.refuse!(I18n.t('data_fix.commit.job_refused_preflight', errors: check.errors.map { |row| row[:message] || row[:code] }.join(' • ')))
    end

    progress = Import::Progress::Ops.new(report)
    outcome = DataFix::CommitRunner.new(source_path: report.source_path, file_path: preflight['file_path'], progress:,
                                        actor_user_id: report.requested_by_user_id).call
    store_outcome(report, outcome)
  end

  def store_outcome(report, outcome) # rubocop:disable Metrics/AbcSize
    report.finish!(
      status: outcome.commit_state, stats: (outcome.stats || {}).to_h.deep_stringify_keys,
      error_message: outcome.error_message&.truncate(4.kilobytes), archive_error: outcome.archive_error&.truncate(4.kilobytes),
      first_error_phase: outcome.first_error_phase, season_id: outcome.season_id.is_a?(Integer) ? outcome.season_id : report.season_id,
      done_dir: outcome.done_dir, meeting_id: outcome.meeting_id, sql_script_id: outcome.script_id,
      sql_rel_path: outcome.script.respond_to?(:rel_path) ? outcome.script.rel_path : outcome.sql_filename,
      log_rel_path: rel_path(outcome.log_full_path, report.source_path), health_run_ids: outcome.health_run_ids,
      db_generation_after: outcome.db_generation_after, progress_current: nil, progress_total: nil, progress_message: nil
    )
  end

  # Path relative to the crawler data root of the source (absolute when outside it).
  def rel_path(path, source_path)
    return nil if path.blank?

    relative = Outbox.relative_path(path, data_root: Outbox.data_root_for(source_path))
    relative.start_with?('..') ? path.to_s : relative
  end
end
