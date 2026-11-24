# frozen_string_literal: true

module DataFix
  #
  # = DataFix::StepperComponent
  #
  # Native Bootstrap 5 step tabs of the Data-Fix review pages (#data-fix-stepper, replaced in place by the Turbo
  # stream of a Step 2/3 card save): one tab per phase with its verdict (DataFix::Pipeline::Summary) and issue count,
  # the active step's actions in a dropdown ("Rebuild from the source", with a confirmation naming the edits it
  # discards), and the banners of the active step:
  # - being prepared (a DataFixPrepareJob holds the source lease: #data-fix-being-prepared, with the run progress);
  # - crawl retry needed (#data-fix-retry-needed);
  # - source changed under the operator's edits ("Rebuild (discard edits)", #data-fix-source-changed);
  # - stale (an earlier step changed: #data-fix-step-stale, "Rebuild" = POST data_fix/rebuild_phase, with a
  #   confirmation and force only when the phase holds edits);
  # - edited / adopted notes.
  #
  # Keeps the 'ul.nav-tabs .nav-link' markup with the "Step N • Label" texts (one .nav-link per step); below the md
  # breakpoint the inactive tabs collapse to their number.
  #
  # == Usage
  #   = render(DataFix::StepperComponent.new(summary: pipeline_summary, active_step: 2, file_path: @file_path))
  #
  class StepperComponent < ViewComponent::Base
    STEPS = [
      { number: 1, key: 'sessions', path: :review_sessions_path, flag: :phase_v2 },
      { number: 2, key: 'teams', path: :review_teams_path, flag: :phase2_v2 },
      { number: 3, key: 'swimmers', path: :review_swimmers_path, flag: :phase3_v2 },
      { number: 4, key: 'events', path: :review_events_path, flag: :phase4_v2 },
      { number: 5, key: 'results', path: :review_results_path, flag: :phase5_v2 }
    ].freeze
    V2_FLAGS = STEPS.pluck(:flag).freeze

    STATUS_CSS = {
      'clean' => 'text-bg-success', 'review' => 'text-bg-warning', 'blocked' => 'text-bg-danger',
      'stale' => 'text-bg-info', 'failed' => 'text-bg-danger', 'unbuilt' => 'bg-body-secondary text-body-secondary border'
    }.freeze
    STATUS_ICONS = {
      'clean' => 'fa-check', 'review' => 'fa-eye', 'blocked' => 'fa-ban', 'stale' => 'fa-clock-rotate-left',
      'failed' => 'fa-triangle-exclamation', 'unbuilt' => 'fa-circle'
    }.freeze
    UNCOUNTED_LEVELS = %w[info stale].freeze
    DOM_ID = 'data-fix-stepper'

    attr_reader :summary, :active_step, :file_path, :retry_needed, :prepare_run, :edit_marker

    # == Params
    # - summary: DataFix::Pipeline::Summary or nil (plain tabs without verdicts);
    # - active_step: 1..5 (nil: no active tab); file_path: the source path;
    # - params_base: query params kept in the step links (default: the current request ones);
    # - retry_needed: the source asks for a crawl retry;
    # - being_prepared: true, or the pending Ops::PipelineRun (kind 'prepare'), while a prepare job holds the lease;
    # - edit_marker: the '_meta.operator_edit' Hash of the active phase ({ 'at', 'actions' }), named by the
    #   confirmations of the rebuilds that discard it.
    def initialize(summary:, active_step:, file_path:, params_base: nil, retry_needed: false, being_prepared: false, edit_marker: nil) # rubocop:disable Metrics/ParameterLists
      super()
      @summary = summary
      @active_step = active_step&.to_i
      @file_path = file_path
      @params_base = params_base
      @retry_needed = retry_needed == true
      @being_prepared = being_prepared.present? && being_prepared != false
      @prepare_run = being_prepared if being_prepared.respond_to?(:progress)
      @edit_marker = edit_marker.is_a?(Hash) ? edit_marker : nil
    end

    def being_prepared? = @being_prepared

    def label_for(step)
      t('data_fix.steps.label', number: step[:number], name: t("data_fix.steps.#{step[:key]}"))
    end

    def verdict_for(step)
      summary&.[](step[:number])
    end

    def step_path(step, extra = {})
      base = (@params_base || helpers.request.query_parameters).to_h.symbolize_keys.except(*V2_FLAGS, :rescan, :file_path)
      helpers.public_send(step[:path], base.merge(file_path:, step[:flag] => 1).merge(extra))
    end

    def badge_css(verdict) = STATUS_CSS.fetch(verdict.status, 'text-bg-secondary')
    def badge_icon(verdict) = STATUS_ICONS.fetch(verdict.status, 'fa-circle')

    def badge_title(verdict)
      text = t("data_fix.verdicts.statuses.#{verdict.status}")
      return "#{text}: #{stale_what(verdict)}" if verdict.stale? && verdict.stale_reasons.any?

      issues = verdict.issues.reject { |issue| issue['level'] == 'info' }
      return text if issues.empty?

      "#{text}: #{issues.first(4).map { |issue| issue_label(issue) }.join(' • ')}"
    end

    def issue_label(issue)
      label = t("data_fix.verdicts.issues.#{issue['code']}", default: issue['code'].to_s.humanize)
      count = issue['count'].to_i
      count > 1 ? "#{label} (#{count})" : label
    end

    def badge_count(verdict)
      count = verdict.issues.reject { |issue| UNCOUNTED_LEVELS.include?(issue['level']) }.sum { |issue| [issue['count'].to_i, 1].max }
      count.positive? ? count : nil
    end

    # Toggle of the active step's actions menu (Popper 'fixed': the scrolling tab list doesn't clip the menu).
    def step_menu_attributes(step)
      { type: 'button', id: "data-fix-step-menu-#{step[:number]}", title: t('data_fix.stepper.actions'),
        data: { bs_toggle: 'dropdown', bs_popper_config: '{"strategy":"fixed"}' }, aria: { expanded: 'false' } }
    end

    def active_step_entry
      STEPS[active_step - 1] if active_step&.between?(1, STEPS.size)
    end

    def active_verdict
      @active_verdict ||= verdict_for(active_step_entry) if active_step_entry
    end

    # Badge of a verdict (status icon + issue count), or nil.
    def verdict_badge(verdict)
      return unless verdict

      content_tag(:span, class: "badge #{badge_css(verdict)}", title: badge_title(verdict), data: { verdict: verdict.status }) do
        safe_join([content_tag(:i, '', class: "fa-solid #{badge_icon(verdict)}", 'aria-hidden': 'true'),
                   badge_count(verdict), content_tag(:span, badge_title(verdict), class: 'visually-hidden')].compact, ' ')
      end
    end

    # Confirmation of "Rebuild from the source" (rescan) of +step+: names the operator edits it would discard.
    def rescan_confirm(step)
      verdict = verdict_for(step)
      return t('data_fix.stepper.rescan_confirm', number: step[:number]) unless verdict&.edited

      edits = edits_summary if step[:number] == active_step
      return t('data_fix.stepper.rescan_confirm_edits', number: step[:number], edits:) if edits.present?

      t('data_fix.stepper.rescan_confirm_edited', number: step[:number])
    end

    # "team saved ×3, team deleted (2026-11-24 10:12)" from the edit marker of the active phase, or nil.
    def edits_summary
      actions = Array(edit_marker&.dig('actions'))
      return if actions.empty?

      text = actions.tally.map do |action, count|
        label = t("data_fix.stepper.edit_actions.#{action}", default: action.to_s.humanize)
        count > 1 ? "#{label} ×#{count}" : label
      end.join(', ')
      at = edit_marker['at'].presence && Time.zone.parse(edit_marker['at'].to_s)
      at ? "#{text} (#{l(at, format: :short)})" : text
    rescue ArgumentError
      text
    end

    def stale_what(verdict)
      upstream = verdict.stale_reasons.pluck('what').uniq
      upstream.map { |what| t("data_fix.stepper.inputs.#{what.to_s.parameterize(separator: '_')}", default: what.to_s) }.join(', ')
    end

    def stale_text(verdict)
      t('data_fix.stepper.stale', what: stale_what(verdict))
    end

    # Params of the stale banner "Rebuild" POST (data_fix/rebuild_phase): force only for an edited phase.
    def rebuild_params
      { file_path:, phase: active_step, force: (active_verdict&.edited ? '1' : nil) }.compact
    end

    def rebuild_confirm = (rescan_confirm(active_step_entry) if active_verdict&.edited)

    def source_changed? = summary&.source_changed == true
    def source_changed_phases = Array(summary&.source_details&.[]('phases')).join(', ')

    # "Phase 3 • matching swimmers (12/40)" of the running prepare job, or nil.
    def prepare_progress_text
      return if prepare_run.nil?

      text = [(t('data_fix.stepper.prepare_phase', number: prepare_run.phase) if prepare_run.phase.present?), prepare_run.message.presence]
             .compact.join(' • ')
      text = "#{text} (#{prepare_run.progress.to_i}/#{prepare_run.total})".strip if prepare_run.total.to_i.positive?
      text.presence
    end

    def prepare_percent
      return if prepare_run.nil? || prepare_run.total.to_i <= 0

      ((prepare_run.progress.to_f / prepare_run.total) * 100).round.clamp(0, 100)
    end
  end
end
