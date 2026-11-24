# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::FixButtonComponent
  #
  # The "Fix" buttons of a data health finding (one per operation of Maintenance::Registry.for_finding), or one button
  # for an explicit operation and params (commit report links, follow-up suggestions). Each opens the prefilled
  # operation form (OperationsController#new): the dry run always comes first. Renders nothing when the operations
  # are disabled (ops setting 'operations.enabled') or when no operation applies.
  #
  # == Params
  # - finding: Ops::HealthFinding (its Fix buttons); or operation_key + params (one button);
  # - origin: 'health' (default with a finding), 'commit_report', 'ui'; compact: small icon buttons (grid rows);
  # - label: button text override.
  #
  class FixButtonComponent < ViewComponent::Base
    ICON = 'fa-screwdriver-wrench'

    # A button: path, label, operation key.
    Button = Data.define(:path, :label, :operation_key)

    def initialize(finding: nil, operation_key: nil, params: {}, origin: nil, compact: false, label: nil) # rubocop:disable Metrics/ParameterLists
      super()
      @finding = finding
      @operation_key = operation_key
      @params = params.to_h
      @origin = origin
      @compact = compact
      @label = label
    end

    def render?
      Maintenance.enabled? && buttons.any?
    end

    def call
      safe_join(buttons.map { |button| button_link(button) }, ' ')
    end

    protected

    attr_reader :compact

    def buttons
      @buttons ||= @finding ? finding_buttons : explicit_buttons
    end

    private

    def finding_buttons
      Maintenance::Registry.for_finding(@finding).map do |klass|
        Button.new(path: helpers.new_operation_path(key: klass.key, finding_id: @finding.id), label: @label || klass.fix_label,
                   operation_key: klass.key)
      end
    end

    def explicit_buttons
      klass = Maintenance::Registry.find(@operation_key)
      return [] unless klass

      query = @params.stringify_keys.slice(*klass.param_names.map(&:to_s)).merge('origin' => @origin).compact
      [Button.new(path: helpers.new_operation_path(key: klass.key, **query.symbolize_keys), label: @label || klass.fix_label,
                  operation_key: klass.key)]
    end

    def button_link(button)
      options = { class: "btn #{'btn-sm' if compact} btn-outline-danger".squish,
                  title: compact ? button.label : t('maintenance.fix_button.title'),
                  data: { turbo_frame: '_top', health_action: 'fix', operation_key: button.operation_key } }
      link_to(button.path, **options) do
        icon = content_tag(:i, '', class: "fa-solid #{ICON}", 'aria-hidden' => 'true')
        text = compact ? content_tag(:span, button.label, class: 'visually-hidden') : " #{button.label}"
        safe_join([icon, text])
      end
    end
  end
end
