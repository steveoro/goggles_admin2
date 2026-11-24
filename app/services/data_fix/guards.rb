# frozen_string_literal: true

module DataFix
  #
  # = DataFix::Guards
  #
  # No-op-safe wrapper of the cross-phase write guards, so that the Data-Fix commit (09) and prepare (10) can call
  # them before or after the guards exist:
  # - DbRestore::Lock.active? (phase 14): a guided DB restore in progress blocks everything;
  # - Drift::Gate.check(scope:, acknowledged:, force:) (phase 08): :ok, :warn (needs the operator's acknowledgement)
  #   or :block.
  # A missing constant counts as :ok. A guard that raises counts as :warn (the operator can still acknowledge it).
  #
  # == Usage
  #   result = DataFix::Guards.check(:commit, acknowledged: params[:drift_ack] == '1')
  #   result.level      # => :ok | :warn | :block
  #   result.allowed?   # => false for :block, and for :warn without acknowledgement
  #
  module Guards
    SCOPES = %i[commit prepare].freeze

    # Outcome of the guards: +level+ (:ok, :warn, :block), +reasons+ (Strings), +verdict+ (the gate's own verdict,
    # when any) and +acknowledged+.
    Result = Data.define(:level, :reasons, :verdict, :acknowledged) do
      def ok? = level == :ok
      def warn? = level == :warn
      def block? = level == :block

      # True when the guarded write may run: :ok, or :warn acknowledged by the operator.
      def allowed? = ok? || (warn? && acknowledged)

      def needs_acknowledgement? = warn? && !acknowledged

      def message = reasons.join(' • ')

      def to_h
        { 'level' => level.to_s, 'reasons' => reasons, 'acknowledged' => acknowledged }
      end
    end

    module_function

    # == Params
    # - scope: :commit (09) or :prepare (10);
    # - acknowledged: the operator ticked the drift acknowledgement; force: passed through to the gate;
    # - gate / lock: injectable classes (specs); default: Drift::Gate / DbRestore::Lock when defined.
    def check(scope, acknowledged: false, force: false, gate: :default, lock: :default)
      raise ArgumentError, "unknown guard scope #{scope.inspect}" unless SCOPES.include?(scope.to_sym)

      lock_class = lock == :default ? '::DbRestore::Lock'.safe_constantize : lock
      return Result.new(level: :block, reasons: [restore_reason(lock_class)], verdict: :restore, acknowledged:) if lock_active?(lock_class)

      gate_class = gate == :default ? '::Drift::Gate'.safe_constantize : gate
      return Result.new(level: :ok, reasons: [], verdict: nil, acknowledged:) unless gate_class.respond_to?(:check)

      outcome = gate_class.check(scope: scope.to_sym, acknowledged:, force:)
      reasons = outcome.respond_to?(:messages) ? Array(outcome.messages) : Array(outcome.reasons).map(&:to_s)
      Result.new(level: normalize_level(outcome), reasons: reasons.map(&:to_s), verdict: outcome.verdict, acknowledged:)
    rescue ArgumentError
      raise
    rescue StandardError => e
      Rails.logger.error("[DataFix::Guards] #{scope} guard failed: #{e.class}: #{e.message}")
      Result.new(level: :warn, reasons: ["guard check failed: #{e.class}: #{e.message}".truncate(300)], verdict: :error, acknowledged:)
    end

    def lock_active?(lock_class)
      lock_class.respond_to?(:active?) && lock_class.active?
    end

    def restore_reason(lock_class)
      run = lock_class.respond_to?(:current_run) ? lock_class.current_run : nil
      if run
        "a DB restore is in progress (#{run.respond_to?(:id) ? "run #{run.id}" : run})"
      else
        'a DB restore is in progress'
      end
    end

    def normalize_level(outcome)
      level = outcome.level.to_s.to_sym
      %i[ok warn block].include?(level) ? level : :warn
    end
  end
end
