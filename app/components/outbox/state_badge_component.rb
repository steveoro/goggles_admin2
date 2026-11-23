# frozen_string_literal: true

module Outbox
  #
  # = Outbox::StateBadgeComponent
  #
  # The state of an Ops::SqlScript as a badge with its explanation as tooltip ("sent, not verified",
  # "executed, outcome not reported", ...), plus the held reason and the warnings (changed after push,
  # not a single transaction) as small extra badges.
  #
  class StateBadgeComponent < ViewComponent::Base
    STATE_CSS = {
      'pending' => 'text-bg-warning', 'held' => 'text-bg-secondary', 'pushing' => 'text-bg-primary',
      'in_doubt' => 'text-bg-danger', 'sent' => 'text-bg-info', 'executed_unreported' => 'text-bg-success',
      'legacy_sent' => 'bg-body-tertiary text-body-emphasis border', 'archived' => 'bg-body-tertiary text-body-secondary border',
      'discarded' => 'bg-body-tertiary text-body-secondary border', 'missing' => 'text-bg-danger'
    }.freeze

    # == Params:
    # - script: the Ops::SqlScript; details: false to show the state badge only.
    def initialize(script:, details: true)
      super()
      @script = script
      @details = details
    end

    protected

    attr_reader :script

    def details? = @details
    def css = STATE_CSS.fetch(script.state, 'text-bg-secondary')
    def tooltip = t("outbox.state_tooltips.#{script.state}", default: '')
    def held_reason = script.held_reason.presence && t("outbox.held_reasons.#{script.held_reason}", default: script.held_reason)
  end
end
