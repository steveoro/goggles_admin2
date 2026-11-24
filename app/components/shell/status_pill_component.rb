# frozen_string_literal: true

module Shell
  #
  # = Shell::StatusPillComponent
  #
  # One top bar status pill for a SystemStatus::Result: level icon + label, with a tooltip carrying
  # the detail and the "as of" time. Links to the result action, when present; a POST action (a button, e.g.
  # "Start crawler") is never run from the top bar: the pill links to the dashboard System zone, where it is.
  #
  class StatusPillComponent < ViewComponent::Base
    LEVEL_CSS = { ok: 'text-bg-success', warn: 'text-bg-warning', error: 'text-bg-danger', unknown: 'text-bg-secondary' }.freeze
    LEVEL_ICON = { ok: 'fa-circle-check', warn: 'fa-triangle-exclamation', error: 'fa-circle-xmark',
                   unknown: 'fa-circle-question' }.freeze
    # DOM id of the dashboard System zone (POST actions are run from there).
    DASHBOARD_SYSTEM_ANCHOR = 'dashboard-system'

    # == Params:
    # - result: a SystemStatus::Result.
    def initialize(result:)
      super()
      @result = result
    end

    protected

    attr_reader :result

    def css_classes
      "badge rounded-pill app-status-pill #{LEVEL_CSS.fetch(result.level)}"
    end

    def tooltip_text
      parts = ["#{result.label}: #{t("shell.status.levels.#{result.level}")}"]
      parts << result.detail if result.detail.present?
      parts << t('shell.status.as_of', time: I18n.l(result.checked_at.localtime, format: :short)) if result.checked_at
      parts << action_label if action_path
      parts.join(' · ')
    end

    def action_path
      return if result.action_path.blank?

      result.post_action? ? helpers.root_path(anchor: DASHBOARD_SYSTEM_ANCHOR) : result.action_path
    end

    def action_label
      result.post_action? ? t('shell.status.on_dashboard', action: result.action[:label]) : result.action[:label]
    end

    def html_attributes
      {
        id: "status-pill-#{result.key}", class: css_classes,
        'aria-label' => "#{result.label}: #{t("shell.status.levels.#{result.level}")}",
        data: { bs_toggle: 'tooltip', bs_placement: 'bottom', bs_title: tooltip_text, status_level: result.level,
                turbo_frame: action_path ? '_top' : nil }
      }
    end
  end
end
