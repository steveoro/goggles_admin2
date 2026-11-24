# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::PlanReportComponent
  #
  # The report of one Ops::OperationRun: status, outcome (ready / blocked / nothing to do / refused / failed / applied
  # with its Outbox script / interrupted: its worker died, see Ops::OperationRun#interrupted?, with the "check the local
  # DB first" warning and the New dry run link), warnings, errors, summary facts, the Data-Fix reviews in progress of
  # the season, the captured console output (ANSI escapes stripped for display) and the SQL preview with its digest.
  # Phase 13: the progress bar and the Cancel button of a pending long run (Ops::OperationRun#progress_percent,
  # #cancellable?), and the 'inspected' outcome of a read-only inspector (Maintenance::Inspector: nothing to apply).
  #
  class PlanReportComponent < ViewComponent::Base
    STATUS_CSS = { 'queued' => 'bg-info-subtle text-info-emphasis', 'running' => 'text-bg-info', 'succeeded' => 'text-bg-success',
                   'failed' => 'text-bg-danger', 'refused' => 'text-bg-warning' }.freeze
    MODE_CSS = { 'preview' => 'text-bg-secondary', 'apply' => 'text-bg-danger', 'script_only' => 'text-bg-secondary' }.freeze

    def self.status_css(status) = STATUS_CSS.fetch(status.to_s, status.to_s == 'interrupted' ? 'text-bg-danger' : 'text-bg-secondary')
    def self.mode_css(mode) = MODE_CSS.fetch(mode.to_s, 'text-bg-secondary')

    def initialize(run:)
      super()
      @run = run
    end

    protected

    attr_reader :run

    def summary = run.summary_hash

    # Facts shown as a definition list (internal keys left out).
    def facts
      summary.except('confirmation', 'typed_token', 'empty', 'statements', 'health_group', 'subjects', 'file_base',
                     'reviews_in_progress', 'follow_ups', 'sql_rel_path', 'sql_filename', 'health_run_id', 'db_generation')
    end

    def fact_label(key) = t("maintenance.facts.#{key}", default: key.to_s.humanize)

    def scalar?(value) = !value.is_a?(Hash) && !value.is_a?(Array)

    def fact_value(value)
      case value
      when true then t('maintenance.facts.yes')
      when false then t('maintenance.facts.no')
      when nil, '' then '-'
      else value.to_s
      end
    end

    def json(value) = JSON.pretty_generate(value)

    def reviews = Array(summary['reviews_in_progress'])

    def console_text = Maintenance::OutputCapture.html(run.console)

    def outcome
      @outcome ||= compute_outcome
    end

    # 'interrupted' or the stored status (memoized: one queue lookup per render).
    def display_status
      @display_status ||= outcome == :interrupted ? 'interrupted' : run.status
    end

    # The form of a new dry run with the same params (and finding).
    def new_dry_run_path
      query = if run.health_finding_id
                { finding_id: run.health_finding_id }
              else
                run.params_hash.merge('origin' => run.origin == 'rake' ? 'ui' : run.origin)
              end
      helpers.new_operation_path(key: run.operation_key, **query.symbolize_keys)
    end

    def compute_outcome # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      return :interrupted if run.interrupted?
      return :pending if run.pending?
      return :refused if run.refused?
      return (run.sql_script_id ? :applied_partially : :applied_unregistered) if run.applied_with_failure?
      return :failed if run.failed?
      return (run.script_only? ? :script_written : :applied) unless run.preview?
      return :blocked if run.blocked?
      return :inspected if run.operation_class&.inspector?
      return :empty if run.empty_plan?

      :ready
    end

    def outcome_css
      { interrupted: 'alert-danger', pending: 'alert-info', refused: 'alert-warning', failed: 'alert-danger', applied: 'alert-success', script_written: 'alert-info',
        blocked: 'alert-danger', empty: 'alert-secondary', ready: 'alert-primary', inspected: 'alert-secondary',
        applied_partially: 'alert-danger', applied_unregistered: 'alert-danger' }.fetch(outcome)
    end

    def outcome_text # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      case outcome
      when :interrupted then t(run.running? ? 'maintenance.run.interrupted_running' : 'maintenance.run.interrupted_queued')
      when :pending then t(run.queued? ? 'maintenance.run.queued_text' : 'maintenance.run.running_text')
      when :refused then t('maintenance.run.refused', reason: t("maintenance.refusals.#{run.refusal_reason}", default: run.refusal_reason.to_s))
      when :failed then t('maintenance.run.failed')
      when :applied then t('maintenance.run.applied', file: summary['sql_filename'].presence || '-')
      when :script_written then t('maintenance.run.script_written', file: summary['sql_filename'].presence || '-')
      when :inspected then t('maintenance.run.inspector')
      when :applied_partially
        partial = summary['partial'].to_h
        t('maintenance.run.applied_partially', applied: partial['applied_blocks'], total: partial['total_blocks'],
                                               file: summary['sql_filename'].presence || '-')
      when :applied_unregistered
        t('maintenance.run.applied_unregistered', path: run.unregistered_sql_path || '-', folder: summary['outbox_folder'] || 'misc')
      else t("maintenance.run.#{outcome}")
      end
    end

    def outbox_link?
      %i[applied script_written applied_partially].include?(outcome) && summary['sql_filename'].present?
    end

    def statements_count = summary['statements'].to_i

    # The progress of a pending long run ({ 'done', 'total', 'label' } and its percentage), nil otherwise.
    def progress
      return unless run.pending? && outcome == :pending

      hash = run.progress_hash
      hash&.merge('percent' => run.progress_percent.to_i)
    end

    def time(value) = value ? l(value.localtime, format: :short) : '-'
  end
end
