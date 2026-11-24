# frozen_string_literal: true

module SystemStatus
  #
  # = SystemStatus::Result
  #
  # Outcome of a SystemStatus::Probe:
  # - key: probe key (Symbol); label: translated short label (e.g. 'API');
  # - level: one of LEVELS (:ok, :warn, :error, :unknown);
  # - detail: translated one-line detail (tooltip), or nil;
  # - checked_at: time of the underlying data (snapshot time for snapshot probes), or nil when never checked;
  # - action: optional Hash { label:, path:, http_method: } suggesting where to go (or what to run) to fix or inspect
  #   the issue; http_method is :get (default, a link) or :post (a button, e.g. "Start crawler": the top bar pill
  #   then links to the dashboard System zone instead, where the button is).
  #
  class Result < Data.define(:key, :label, :level, :detail, :checked_at, :action)
    # Supported levels, best first.
    LEVELS = %i[ok warn error unknown].freeze

    def initialize(key:, label:, level:, detail: nil, checked_at: nil, action: nil) # rubocop:disable Metrics/ParameterLists
      level = level.to_sym
      raise ArgumentError, "unsupported level: #{level.inspect}" unless LEVELS.include?(level)

      super
    end

    def ok? = level == :ok
    def unknown? = level == :unknown

    # Path of the action (nil without one).
    def action_path
      action.is_a?(Hash) ? action[:path].presence : nil
    end

    # True when the action is run with a POST (a button), false for a link or without action.
    def post_action?
      action_path.present? && action[:http_method].to_s == 'post'
    end
  end
end
