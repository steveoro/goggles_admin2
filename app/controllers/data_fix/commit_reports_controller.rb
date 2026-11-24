# frozen_string_literal: true

module DataFix
  # CommitReportsController: the persistent Phase 6 commit report (Ops::CommitReport), reopenable by id.
  #
  # - show: the page (native Bootstrap 5); its status frame polls while the report is queued / running;
  # - status: the status frame (outcome, stats, first error step, log, Outbox link);
  # - health: the lazy frame of the season health runs triggered after the commit (Health::SeasonRunJob), with the
  #   Fix links (phase 11, Maintenance::FixButtonComponent) of the open badge findings of the season and of the
  #   duplicate-result findings of the committed meeting, once the runs are over.
  class CommitReportsController < ApplicationController
    # Findings offering a Fix link on the report: season-wide badge checks, meeting-scoped result checks.
    BADGE_CHECKS = %w[badges.duplicate.sure badges.relay_category badges.duplicate.possible].freeze
    RESULT_CHECKS = %w[results.null_swimmers results.duplicates results.dup_mir_per_badge].freeze
    MAX_FIX_FINDINGS = 10

    before_action :set_report

    def show
      render 'data_fix/commit_reports/show'
    end

    def status
      render partial: 'data_fix/commit_reports/status', locals: { report: @report }
    end

    def health
      @health_runs = Ops.safely([]) { Ops::HealthRun.where(id: @report.health_run_ids.to_h.values).order(:group_key).to_a }
      findings = @health_runs.any?(&:pending?) ? [] : Ops.safely([]) { fix_findings }
      render partial: 'data_fix/commit_reports/health', locals: { report: @report, runs: @health_runs, findings: }
    end

    private

    # The open findings to fix after this commit: duplicate / NULL-swimmer results of the committed meeting first, then
    # the badge findings of the season (errors first), at most MAX_FIX_FINDINGS.
    def fix_findings
      return [] unless @report.season_id

      scope = Ops::HealthFinding.for_season(@report.season_id).unresolved.by_severity
      results = @report.meeting_id ? scope.where(check_key: RESULT_CHECKS, subject_id: @report.meeting_id).to_a : []
      (results + scope.where(check_key: BADGE_CHECKS).limit(MAX_FIX_FINDINGS).to_a).first(MAX_FIX_FINDINGS)
    end

    def set_report
      @report = Ops.safely { Ops::CommitReport.find_by(id: params[:id]) if Ops.available? }
      return if @report

      flash[:warning] = I18n.t('data_fix.commit_report.not_found')
      redirect_to(pull_result_files_path)
    end
  end
end
