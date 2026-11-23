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
  # - action: optional Hash { label:, path: } suggesting where to go to fix or inspect the issue.
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
  end
end
