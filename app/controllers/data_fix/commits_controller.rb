# frozen_string_literal: true

module DataFix
  # CommitsController: Phase 6 commit summary, the Commit click (queues DataFixCommitJob) and the archive retry.
  #
  # The commit itself runs in DataFixCommitJob (DataFix::CommitRunner) on the 'pipeline' worker; its outcome is
  # stored in an Ops::CommitReport, shown (and reopenable) by DataFix::CommitReportsController#show.
  # #commit_phase6 is the ONLY enqueue site of DataFixCommitJob (spec-asserted).
  class CommitsController < BaseController
    # (retry_archive takes the archived source path as is: no working-copy resolution)
    skip_before_action :set_source_path, only: :retry_archive

    # GET data_fix/commit_summary?file_path=: how the meeting was matched, existing / new counts per entity, the new
    # teams and swimmers, a fresh preflight, the guards and one Commit button (same POST as the Step 5 button).
    def summary
      load_summary
      render 'data_fix/commit_summary'
    end

    # POST data_fix/commit_phase6 (Commit button of the summary and of Step 5): overwrite confirmation, synchronous
    # gates, guards (DataFix::Guards: block => refused, warn => the summary asks for the acknowledgement) and
    # preflight; then creates the queued Ops::CommitReport, enqueues DataFixCommitJob and opens the report.
    def commit_phase6
      file_path = @file_path
      source_path = @source_path

      phase5_path = source_resolver.default_phase_path_for(source_path, 5)
      overwrite_meta = (PhaseFileManager.new(phase5_path).meta&.dig('individual_result_overwrite') if File.exist?(phase5_path))
      overwrite_candidates = Array(overwrite_meta&.dig('snapshot', 'candidates'))
      overwrite_selected_count = overwrite_candidates.count { |candidate| candidate['selected'] == true }
      if overwrite_meta&.dig('enabled') == true && overwrite_selected_count.positive? && params[:confirm_overwrite].to_s != '1'
        flash[:alert] = I18n.t('data_import.data_fix.individual_result_overwrite_confirmation_required')
        redirect_to(review_results_path(file_path: source_path, phase5_v2: 1)) && return
      end

      runner = DataFix::CommitRunner.new(source_path:, file_path:, source_resolver:)
      if (refusal = runner.precheck)
        flash[refusal.flash_key] = refusal.message
        redirect_to(step_path_for(refusal.step, file_path:, **refusal.step_params)) && return
      end

      unless Ops.available?
        flash[:error] = I18n.t('data_fix.commit.refused_ops')
        redirect_to(data_fix_commit_summary_path(file_path: source_path)) && return
      end

      acknowledged = params[:drift_ack].to_s == '1'
      @guards = DataFix::Guards.check(:commit, acknowledged:)
      if @guards.block?
        flash[:error] = I18n.t('data_fix.commit.refused_guard', reason: @guards.message)
        redirect_to(data_fix_commit_summary_path(file_path: source_path, guard: 'block')) && return
      end
      return render_summary(:unprocessable_content) if @guards.needs_acknowledgement?

      create_anyway = params[:create_anyway].to_s == '1'
      preflight = Import::CommitPreflight.new(pipeline:, create_anyway:).call
      unless preflight.ok?
        flash.now[:error] = I18n.t('data_fix.commit.refused_preflight')
        return render_summary(:unprocessable_content, preflight:)
      end

      # (Ops.safely retries once on a busy SQLite DB)
      report = Ops.safely { create_report!(source_path:, file_path:, preflight:, acknowledged:, create_anyway:) }
      unless report
        flash[:error] = I18n.t('data_fix.commit.not_queued', error: 'ops DB busy')
        redirect_to(data_fix_commit_summary_path(file_path: source_path)) && return
      end

      enqueue_commit!(report)
      redirect_to(data_fix_commit_report_path(report))
    end

    # POST data_fix/refresh_matches (commit summary): re-resolves the nil-id teams and swimmers against the local DB
    # (DataFix::Pipeline#refresh_new_entities!), then shows the summary again.
    def refresh_matches
      counts = pipeline.refresh_new_entities!
      redirect_to(data_fix_commit_summary_path(file_path: @source_path),
                  notice: I18n.t('data_fix.pipeline.matches_refreshed', teams: counts[:teams], swimmers: counts[:swimmers]))
    rescue DataFix::Pipeline::LeaseBusyError
      redirect_to(data_fix_commit_summary_path(file_path: @source_path), flash: { warning: I18n.t('data_fix.pipeline.lease_busy') })
    end

    # Phase 6, "committed, archiving failed": runs the archiving step again (idempotent: moves only the files still
    # in results.new, purges the staging rows left, appends the log section), updates the report and shows it again.
    # Never commits anything.
    def retry_archive
      source_path = params[:file_path].to_s
      unless retryable_source?(source_path)
        flash[:warning] = I18n.t('data_import.errors.invalid_request')
        redirect_to(pull_result_files_path) && return
      end

      report = retry_report_for(source_path)
      outcome = DataFix::CommitRunner.new(source_path:).retry_archive!
      report&.finish!(status: outcome[:commit_state], archive_error: outcome[:archive_error], done_dir: outcome[:done_dir],
                      season_id: outcome[:season_id].is_a?(Integer) ? outcome[:season_id] : report.season_id)
      redirect_to(report ? data_fix_commit_report_path(report) : pull_result_files_path)
    end

    private

    def load_summary(preflight: nil)
      @summary = pipeline.summary
      @preflight = preflight || Import::CommitPreflight.new(pipeline:, create_anyway: params[:create_anyway].to_s == '1').call
      @guards ||= DataFix::Guards.check(:commit, acknowledged: params[:drift_ack].to_s == '1')
      @commit_summary = DataFix::CommitSummary.new(pipeline:, summary: @summary)
      @ops_available = Ops.available?
      @guard_blocked = params[:guard] == 'block' || @guards.block?
    end

    def render_summary(status, preflight: nil)
      load_summary(preflight:)
      render('data_fix/commit_summary', status:)
    end

    def step_path_for(step, file_path:, **extra)
      case step
      when 1 then review_sessions_path(file_path:, phase_v2: 1, **extra)
      else review_results_path(file_path:, phase5_v2: 1, **extra)
      end
    end

    def create_report!(source_path:, file_path:, preflight:, acknowledged:, create_anyway:)
      Ops::CommitReport.create!(
        pipeline_source: pipeline.source_row, season_id: Ops::PipelineSource.season_id_for(source_path).nonzero?,
        source_base: pipeline.base, source_path:, status: 'queued', requested_by_user_id: current_user.id,
        requested_at: Time.current,
        preflight: preflight.to_h.merge('drift_ack' => acknowledged, 'create_anyway' => create_anyway, 'file_path' => file_path,
                                        'guards' => @guards.to_h),
        summary: DataFix::CommitSummary.new(pipeline:, summary: pipeline.summary).to_h
      )
    end

    # The ONLY enqueue site of DataFixCommitJob (an operator click).
    def enqueue_commit!(report)
      job = DataFixCommitJob.perform_later(commit_report_id: report.id)
      if job
        report.update_column(:job_id, job.job_id) # rubocop:disable Rails/SkipsModelValidations
      else
        report.refuse!(I18n.t('data_fix.commit.not_queued', error: 'enqueue refused'))
      end
    rescue StandardError => e
      report.refuse!(I18n.t('data_fix.commit.not_queued', error: "#{e.class}: #{e.message}"))
    end

    # Report to update on an archive retry: the given id, else the last report of the source.
    def retry_report_for(source_path)
      Ops.safely do
        next unless Ops.available?

        Ops::CommitReport.find_by(id: params[:commit_report_id]) ||
          Ops::CommitReport.where(source_path:).recent.first ||
          Ops::CommitReport.create!(source_base: Ops::PipelineSource.base_for(source_path), source_path:,
                                    season_id: Ops::PipelineSource.season_id_for(source_path).nonzero?,
                                    status: 'committed_archive_failed', requested_by_user_id: current_user.id,
                                    requested_at: Time.current, sql_rel_path: params[:sql_filename].presence,
                                    sql_script_id: params[:script_id].presence&.to_i)
      end
    end

    # A retry is allowed only for a JSON source path under a results.new folder.
    def retryable_source?(source_path)
      source_path.end_with?('.json') && File.expand_path(source_path, Rails.root).include?("/#{Outbox::NEW_DIR}/")
    end
  end
end
