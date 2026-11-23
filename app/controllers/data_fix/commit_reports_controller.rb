# frozen_string_literal: true

module DataFix
  # CommitReportsController: the persistent Phase 6 commit report (Ops::CommitReport), reopenable by id.
  #
  # - show: the page (native Bootstrap 5); its status frame polls while the report is queued / running;
  # - status: the status frame (outcome, stats, first error step, log, Outbox link);
  # - health: the lazy frame of the season health runs triggered after the commit (Health::SeasonRunJob).
  class CommitReportsController < ApplicationController
    before_action :set_report

    def show
      render 'data_fix/commit_reports/show'
    end

    def status
      render partial: 'data_fix/commit_reports/status', locals: { report: @report }
    end

    def health
      @health_runs = Ops.safely([]) { Ops::HealthRun.where(id: @report.health_run_ids.to_h.values).order(:group_key).to_a }
      render partial: 'data_fix/commit_reports/health', locals: { report: @report, runs: @health_runs }
    end

    private

    def set_report
      @report = Ops.safely { Ops::CommitReport.find_by(id: params[:id]) if Ops.available? }
      return if @report

      flash[:warning] = I18n.t('data_fix.commit_report.not_found')
      redirect_to(pull_result_files_path)
    end
  end
end
