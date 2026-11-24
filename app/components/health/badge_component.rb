# frozen_string_literal: true

module Health
  #
  # = Health::BadgeComponent
  #
  # Bootstrap 5 badge for a data health severity, finding status or run status (theme-aware colours).
  #
  # == Usage
  #   = render(Health::BadgeComponent.new(kind: :severity, value: 'error'))
  #
  class BadgeComponent < ViewComponent::Base
    CSS = {
      severity: { 'error' => 'text-bg-danger', 'warning' => 'text-bg-warning', 'info' => 'text-bg-info' },
      status: { 'open' => 'text-bg-primary', 'acknowledged' => 'text-bg-secondary',
                'ignored' => 'bg-body-secondary text-body-secondary border', 'resolved' => 'text-bg-success' },
      run: { 'queued' => 'bg-info-subtle text-info-emphasis', 'running' => 'text-bg-info', 'succeeded' => 'text-bg-success',
             'failed' => 'text-bg-danger', 'skipped' => 'bg-success-subtle text-success-emphasis' }
    }.freeze
    LABEL_SCOPES = { severity: 'health.severities', status: 'health.statuses', run: 'health.run_statuses' }.freeze

    def initialize(kind:, value:)
      super()
      @kind = kind.to_sym
      @value = value.to_s
    end

    def call
      content_tag(:span, t("#{LABEL_SCOPES.fetch(@kind)}.#{@value}", default: @value),
                  class: "badge #{CSS.fetch(@kind).fetch(@value, 'text-bg-secondary')}", data: { health_badge: "#{@kind}-#{@value}" })
    end
  end
end
