# frozen_string_literal: true

module Dashboard
  #
  # = Dashboard::StatusRowComponent
  #
  # One row of the dashboard System zone for a SystemStatus::Result: level icon and label, level badge, detail,
  # "as of" time and the result action (a link, or a button for a POST action such as "Start crawler").
  #
  class StatusRowComponent < ViewComponent::Base
    LEVEL_ICON = Shell::StatusPillComponent::LEVEL_ICON
    LEVEL_TEXT_CSS = { ok: 'text-success', warn: 'text-warning-emphasis', error: 'text-danger', unknown: 'text-body-secondary' }.freeze
    LEVEL_BADGE_CSS = Shell::StatusPillComponent::LEVEL_CSS

    # == Params:
    # - result: a SystemStatus::Result.
    def initialize(result:)
      super()
      @result = result
    end

    protected

    attr_reader :result

    def level_text
      t("shell.status.levels.#{result.level}")
    end

    def as_of_text
      return unless result.checked_at

      t('shell.status.as_of', time: l(result.checked_at.localtime, format: :short))
    end

    def action_css
      result.post_action? ? 'btn btn-sm btn-outline-primary' : 'btn btn-sm btn-outline-secondary'
    end
  end
end
