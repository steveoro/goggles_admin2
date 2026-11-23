# frozen_string_literal: true

module DataFix
  #
  # = DataFix::StepperComponent
  #
  # Native Bootstrap 5 step tabs of the Data-Fix review pages (replaces the former data_fix/_step_tabs partial):
  # one tab per phase with its verdict (DataFix::Pipeline::Summary) and issue count, the rescan link (with a
  # confirmation) on the active tab, plus the banners of the active step: stale (an earlier step changed),
  # edited (incl. "edited (pre-existing)"), source changed under the operator's edits ("Rebuild (discard edits)").
  #
  # Keeps the 'ul.nav-tabs .nav-link' markup with the "Step N • Label" texts (one .nav-link per step).
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

    attr_reader :summary, :active_step, :file_path

    # == Params
    # - summary: DataFix::Pipeline::Summary or nil (plain tabs without verdicts);
    # - active_step: 1..5 (nil: no active tab); file_path: the source path;
    # - params_base: query params kept in the step links (default: the current request ones).
    def initialize(summary:, active_step:, file_path:, params_base: nil)
      super()
      @summary = summary
      @active_step = active_step&.to_i
      @file_path = file_path
      @params_base = params_base
    end

    def steps = STEPS

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
      issues = verdict.issues.reject { |issue| issue['level'] == 'info' }
      return text if issues.empty?

      "#{text}: #{issues.first(4).map { |issue| issue_label(issue) }.join(' • ')}"
    end

    def issue_label(issue)
      label = t("data_fix.verdicts.issues.#{issue['code']}", default: issue['code'].to_s.humanize)
      count = issue['count'].to_i
      count > 1 ? "#{label} (#{count})" : label
    end

    UNCOUNTED_LEVELS = %w[info stale].freeze

    def badge_count(verdict)
      count = verdict.issues.reject { |issue| UNCOUNTED_LEVELS.include?(issue['level']) }.sum { |issue| [issue['count'].to_i, 1].max }
      count.positive? ? count : nil
    end

    def active_step_entry
      STEPS[active_step - 1] if active_step
    end

    def active_verdict
      @active_verdict ||= verdict_for(active_step_entry) if active_step
    end

    # Badge of a verdict (status icon + issue count), or nil.
    def verdict_badge(verdict)
      return unless verdict

      content_tag(:span, class: "badge #{badge_css(verdict)}", title: badge_title(verdict), data: { verdict: verdict.status }) do
        safe_join([content_tag(:i, '', class: "fa-solid #{badge_icon(verdict)}", 'aria-hidden': 'true'), badge_count(verdict)].compact, ' ')
      end
    end

    def rescan_confirm(step)
      key = verdict_for(step)&.edited ? 'rescan_confirm_edited' : 'rescan_confirm'
      t("data_fix.stepper.#{key}", number: step[:number])
    end

    def stale_text(verdict)
      upstream = verdict.stale_reasons.pluck('what').uniq
      t('data_fix.stepper.stale', what: upstream.map { |what| t("data_fix.stepper.inputs.#{what.parameterize(separator: '_')}", default: what) }.join(', '))
    end

    def source_changed?
      summary&.source_changed == true
    end

    def source_changed_phases
      Array(summary&.source_details&.[]('phases')).join(', ')
    end
  end
end
