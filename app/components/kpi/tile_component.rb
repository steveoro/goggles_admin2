# frozen_string_literal: true

module Kpi
  #
  # = Kpi::TileComponent
  #
  # One dashboard KPI counter: label, value (with its own "as of" time) and a link to its grid.
  # A counter that was never fetched never shows a number: it shows its state instead ("unreachable",
  # "sign in to refresh", "unavailable", "no data yet"). A known value whose last refresh failed keeps the value
  # and adds the state as a note.
  #
  class TileComponent < ViewComponent::Base
    # Value-less states (i18n 'dashboard.kpis.states.<state>') and their text colour.
    STATE_CSS = { unreachable: 'text-danger-emphasis', sign_in: 'text-warning-emphasis', unavailable: 'text-warning-emphasis',
                  no_data: 'text-body-secondary' }.freeze

    attr_reader :key, :value, :state

    # == Params:
    # - key: counter key ('users', 'import_queues', 'issues', 'api_uses');
    # - label: translated label; icon: Font Awesome icon name; path: its grid page (nil: no link);
    # - value: Integer or nil (never fetched); fetched_at: Time of the value, or nil;
    # - state: nil when the value is current, else one of STATE_CSS keys (shown instead of a missing value,
    #   or as a note next to a known one).
    def initialize(key:, label:, icon:, value:, fetched_at: nil, state: nil, path: nil) # rubocop:disable Metrics/ParameterLists
      super()
      @key = key.to_s
      @label = label
      @icon = icon
      @value = value
      @fetched_at = fetched_at
      @state = state&.to_sym
      @path = path
    end

    protected

    def value? = !@value.nil?

    def formatted_value
      helpers.number_with_delimiter(@value)
    end

    def state_text
      t("dashboard.kpis.states.#{@state}") if @state
    end

    def state_css
      STATE_CSS.fetch(@state, 'text-body-secondary')
    end

    def as_of_text
      t('dashboard.kpis.value_as_of', time: l(@fetched_at.localtime, format: :short)) if @fetched_at
    end

    def wrapper_tag
      @path ? :a : :div
    end

    def wrapper_options
      options = { id: "kpi-tile-#{@key.dasherize}", class: 'card h-100 kpi-tile text-decoration-none',
                  data: { kpi_key: @key, kpi_state: @state || 'ok' } }
      if @path
        options[:href] = @path
        options[:data] = options[:data].merge(turbo_frame: '_top')
      end
      options
    end
  end
end
