# frozen_string_literal: true

module DataFix
  # Reusable Turbo GET filter component with 3-state radio button group and search query input.
  # Auto-submits on filter state change, per-page change, and debounced q input.
  # Preserves q input exactly as typed (no trimming). Deselects "none" when q is present.
  class TurboFilterStateComponent < ViewComponent::Base
    FILTER_STATES = %w[none review diff_key].freeze

    def initialize(options = {}) # rubocop:disable Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
      super()
      @target_url = options[:target_url]
      @hidden_params = options[:hidden_params] || {}
      @per_page_param_name = options[:per_page_param_name]
      @per_page_value = options[:per_page_value]
      @filter_state = FILTER_STATES.include?(options[:filter_state].to_s) ? options[:filter_state].to_s : 'none'
      @q = options[:q].to_s
      @filter_label = options[:filter_label] || 'Filter'
      @q_placeholder = options[:q_placeholder] || 'Search...'
      @review_help_text = options[:review_help_text]
      @per_page_options = options[:per_page_options] || [50, 100, 150]
      @q_min_length = options[:q_min_length] || 3
      @debounce_ms = options[:debounce_ms] || 300
      @form_class = options[:form_class] || 'form-inline'
      @dom_id_prefix = "turbo-filter-state-#{@per_page_param_name.to_s.dasherize}"
    end

    def render?
      @target_url.present? && @per_page_param_name.present?
    end

    protected

    # Returns true if the radio button should be checked.
    # Deselects "none" when q is present to allow explicit clearing.
    def checked_filter_state?(value)
      return false if value == 'none' && @q.present?

      @filter_state == value
    end
  end
end
