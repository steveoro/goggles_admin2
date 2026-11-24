# frozen_string_literal: true

module Drift
  #
  # = Drift::Gate
  #
  # The DB sync gate run before an action that writes the local DB or sends SQL to the server
  # (contract: docs/plans/contracts.md, "Drift and restore"; docs/db_sync.md).
  #
  # == Usage
  #   result = Drift::Gate.check(scope: :push, acknowledged: params[:drift_ack] == '1')
  #   result.level      # => :ok | :warn | :block
  #   result.allowed?   # => ok; or warn && acknowledged; or (scope :rake only) force
  #   result.verdict    # => the Ops::DbFingerprint used (nil without the ops DB)
  #   result.reasons    # => [{ code:, table:, local:, remote: }, ...]
  #
  # The verdict is the last stored check for the configured API when it is at most FRESH_FOR old; otherwise a fresh
  # light check (max ids only, one GET with the background JWT, short timeouts) is taken and stored (trigger 'gate').
  #
  # == Levels by scope
  #   verdict  | :commit :operation :prepare | :push :board_write | :rake
  #   green    | :ok                         | :ok                | :ok
  #   amber    | :warn                       | :warn              | :warn
  #   unknown  | :warn                       | :warn              | :warn
  #   red      | :block                      | :warn              | :block (allowed with force: true, e.g. force=1)
  # (Unknown = API unreachable, no credentials, an API without the 'db_fingerprint' capability, no ops DB.)
  #
  # Never raises: an unexpected error gives a :warn result with reason 'error'.
  #
  class Gate
    SCOPES = %i[commit push prepare operation board_write rake].freeze
    BLOCK_ON_RED = %i[commit operation prepare rake].freeze
    # The last check is reused when younger than this; otherwise a fresh light check is taken.
    FRESH_FOR = 10.minutes

    Result = Data.define(:scope, :level, :verdict, :reasons, :acknowledged, :forced) do
      def ok? = level == :ok
      def warn? = level == :warn
      def block? = level == :block

      # ok; or warn && acknowledged; or forced (rake only).
      def allowed?
        ok? || (warn? && acknowledged) || forced
      end

      # True when the action needs the operator's tick (warn, not ticked yet).
      def needs_acknowledgement? = warn? && !acknowledged

      # 'green' | 'amber' | 'red' | 'unknown' (unknown without a stored check).
      def verdict_name
        verdict&.verdict || 'unknown'
      end

      # One translated line per reason ('db_sync.reasons.<code>').
      def messages
        reasons.map { |reason| Drift::ReasonText.call(reason) }
      end

      # Short translated summary (flash text), e.g. "DB sync red: laps: remote max id 120 > local 100".
      def summary
        head = I18n.t('db_sync.gate.summary', verdict: I18n.t("db_sync.verdicts.#{verdict_name}"))
        [head, messages.first(3).join(' · ').presence].compact.join(': ')
      end
    end

    class << self
      # == Params:
      # - scope: one of SCOPES; acknowledged: the operator's tick for a warning;
      # - force: rake only (force=1), lets a red verdict through; tables: subset of Drift::Tables for the fresh check.
      def check(scope:, acknowledged: false, force: false, tables: nil, now: Time.current)
        scope = scope.to_sym
        raise ArgumentError, "Unknown Drift::Gate scope #{scope.inspect}" unless SCOPES.include?(scope)

        fingerprint = verdict_for(tables:, now:)
        build(scope, fingerprint, acknowledged: acknowledged ? true : false, force: scope == :rake && force ? true : false, now:)
      rescue ArgumentError
        raise
      rescue StandardError => e
        Rails.logger.warn("[Drift::Gate] #{e.class}: #{e.message}")
        Result.new(scope:, level: :warn, verdict: nil, reasons: [reason_hash('error', remote: e.message.truncate(200))],
                   acknowledged: acknowledged ? true : false, forced: false)
      end

      # The Ops::DbFingerprint the gate decides on (last one when fresh, else a new light check), or nil.
      def verdict_for(tables: nil, now: Time.current)
        return unless Ops.available?

        base_url = APIProxy.configured_base_url.to_s.strip.delete_suffix('/')
        last = Ops::DbFingerprint.latest(base_url)
        return last if last && last.taken_at >= now - FRESH_FOR

        Drift::Check.call(trigger: 'gate', mode: 'light', tables:, base_url:)
      end

      # Level for a +verdict+ name in +scope+.
      def level_for(scope, verdict)
        case verdict.to_s
        when 'green' then :ok
        when 'red' then BLOCK_ON_RED.include?(scope.to_sym) ? :block : :warn
        else :warn
        end
      end

      private

      def build(scope, fingerprint, acknowledged:, force:, now:)
        reasons = if fingerprint
                    fingerprint.reason_list(now:)
                  else
                    [reason_hash(Ops.available? ? 'error' : 'ops_unavailable')]
                  end
        verdict = fingerprint&.verdict || 'unknown'
        Result.new(scope:, level: level_for(scope, verdict), verdict: fingerprint, reasons:, acknowledged:, forced: force)
      end

      def reason_hash(code, table: nil, local: nil, remote: nil)
        { code:, table:, local:, remote: }
      end
    end
  end
end
