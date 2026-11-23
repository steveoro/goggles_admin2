# frozen_string_literal: true

module Drift
  #
  # = Drift::V0Status
  #
  # Current drift v0 verdict for an API base URL: the last Drift::LatestUpdatesCheck snapshot
  # ('drift_v0:<url>', remote facts) plus the LIVE count of the unacknowledged remote writes
  # (Ops::RemoteWrite.unacknowledged, a local ops DB read). Never calls the network; never raises.
  #
  # Used by SystemStatus::DriftV0Probe, the /remote_writes page and (dashboard) the Drift inbox source.
  #
  # == Levels (+level+) and their +reasons+ (Array of Symbols, most relevant first)
  # - :warn  => :missing (recent remote rows missing locally) and/or :remote_writes (successful remote writes
  #             since the last "Acknowledge"); remote writes give :warn even when the remote check failed;
  # - :ok    => [:ok] every recent remote ID exists locally and no unacknowledged remote write;
  # - :unknown => [:never] no check yet, [:stale] last check older than STALE_AFTER, [:ops_unavailable], or the
  #             check status: [:no_credentials], [:unreachable], [:unauthorized], [:unsupported], [:error].
  # (:error is reserved for phase 08.)
  #
  class V0Status
    LEVELS = %i[ok warn unknown].freeze
    # DriftCheckJob runs every 30 minutes: older snapshots are reported as stale.
    STALE_AFTER = 75.minutes

    attr_reader :base_url, :payload, :checked_at, :remote_writes, :now, :level, :reasons

    class << self
      # Verdict for +base_url+ (default: the configured API).
      def for(base_url = APIProxy.configured_base_url, now: Time.current)
        url = LatestUpdatesCheck.normalize_url(base_url)
        return new(base_url: url, payload: nil, checked_at: nil, remote_writes: 0, now:, ops_available: false) unless Ops.available?

        snapshot = LatestUpdatesCheck.read(url)
        writes = Ops.safely(0) { Ops::RemoteWrite.unacknowledged(url).count }
        new(base_url: url, payload: snapshot&.payload, checked_at: snapshot&.taken_at, remote_writes: writes, now:)
      end
    end

    # == Params:
    # - payload: the drift_v0 snapshot payload (Hash) or nil; checked_at: its time;
    # - remote_writes: number of unacknowledged remote writes; now: reference time;
    # - ops_available: false when the ops DB is not ready.
    def initialize(base_url:, payload:, checked_at:, remote_writes:, now: Time.current, ops_available: true) # rubocop:disable Metrics/ParameterLists
      @base_url = base_url
      @payload = payload.is_a?(Hash) ? payload : nil
      @checked_at = checked_at
      @remote_writes = remote_writes.to_i
      @now = now
      @level, @reasons = ops_available ? evaluate : [:unknown, [:ops_unavailable]]
    end

    def ok? = level == :ok
    def warn? = level == :warn
    def unknown? = level == :unknown

    # Remote check status ('ok', 'no_credentials', ...), or nil without a snapshot.
    def status
      payload&.dig('status')
    end

    # { 'table' => [IDs] } of the recent remote rows missing locally (last check).
    def missing
      payload&.dig('missing').is_a?(Hash) ? payload['missing'] : {}
    end

    def missing_count
      missing.values.sum { |ids| Array(ids).size }
    end

    def error
      payload&.dig('error')
    end

    def acknowledged_at
      Ops.safely { Ops::RemoteWrite.acknowledged_at }
    end

    # Translated one-line texts for the reasons ('shell.status.drift_v0.<reason>').
    def details
      reasons.map { |reason| detail_for(reason) }
    end

    private

    def evaluate
      return [:warn, warnings] if warnings.any?
      return [:unknown, [:never]] if payload.nil?
      return [:unknown, [:stale]] unless fresh?
      return [:unknown, [status_reason]] unless status == 'ok'

      [:ok, [:ok]]
    end

    # :missing (fresh successful check only) and/or :remote_writes.
    def warnings
      @warnings ||= [
        (:missing if fresh? && status == 'ok' && missing_count.positive?),
        (:remote_writes if remote_writes.positive?)
      ].compact
    end

    def fresh?
      checked_at.present? && checked_at >= now - STALE_AFTER
    end

    def status_reason
      reason = status.to_s.to_sym
      %i[no_credentials unreachable unauthorized unsupported].include?(reason) ? reason : :error
    end

    def detail_for(reason)
      key = "shell.status.drift_v0.#{reason}"
      case reason
      when :missing
        tables = missing.map { |table, ids| "#{table}: #{Array(ids).size}" }.join(', ')
        I18n.t(key, count: missing_count, tables:)
      when :remote_writes then I18n.t(key, count: remote_writes)
      when :stale then I18n.t(key, time: checked_at ? I18n.l(checked_at.localtime, format: :short) : '-')
      when :unreachable, :error then I18n.t(key, error: error.to_s.truncate(120))
      else I18n.t(key)
      end
    end
  end
end
