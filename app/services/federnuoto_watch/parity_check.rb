# frozen_string_literal: true

module FedernuotoWatch
  #
  # = FedernuotoWatch::ParityCheck
  #
  # The automatic follow-up of the pending FIN change alert (0.10.103), run at the end of every PipelinePlannerJob pass
  # (with the master switch on) and after every FedernuotoWatchJob check that did not fail:
  #
  # - with the automation master switch on and FedernuotoWatch::Parity reached, the change is acknowledged
  #   (FedernuotoWatch::Acknowledge, actor :auto, reason 'parity', or 'nothing_to_crawl' when no row was actionable),
  #   guarded by the snapshot digest read here;
  # - otherwise the progress is stored (FedernuotoWatch::Progress) and, when it changed, the alert is broadcast again
  #   to every open tab with the new progress lines, or removed from them when it becomes hidden (nothing actionable
  #   yet, see Progress.alert_shown?: the change stays pending).
  #
  # With the master switch off, or without the ops DB, nothing is ever acknowledged here: the operator dismisses the
  # alert. When the parity cannot be computed, the check fails, or the automatic acknowledge is refused (its trace could
  # not be written), the progress is dropped and the plain alert shows again (Progress.reset!). Read-only besides the
  # watcher state (the acknowledge), the progress snapshot and the ops events. Never raises.
  #
  class ParityCheck
    STATUSES = %i[none unknown pending acknowledged stale error].freeze

    # status: one of STATUSES; parity: the Parity::Result (or nil).
    Outcome = Data.define(:status, :parity)

    def self.call(...)
      new(...).call
    end

    # == Params
    # - season: the board season; store / notifier: StateStore / Notifier;
    # - parity: object responding to #call(change) with a Parity::Result (default: a Parity for the season).
    def initialize(season: SeasonBoard::Builder.latest_season, store: StateStore.new, notifier: Notifier.new, parity: nil)
      @season = season
      @store = store
      @notifier = notifier
      @parity = parity
    end

    def call
      state = @store.read
      change = state['change'].presence
      return Outcome.new(status: :none, parity: nil) unless change.is_a?(Hash) && change['detected_at'].present?

      result = (@parity || Parity.new(season: @season, store: @store)).call(change)
      return reset(:unknown) unless result
      return acknowledge(state, result) if may_acknowledge?(result)

      publish(state, change, result)
      Outcome.new(status: :pending, parity: result)
    rescue StandardError => e
      Rails.logger.error("[FedernuotoWatch::ParityCheck] #{e.class}: #{e.message}")
      reset(:error)
    end

    private

    # The parity is reached, with the automation on and the ops DB there (its trace is written first, see Acknowledge).
    def may_acknowledge?(result)
      result.automation && result.reached? && Ops.available?
    end

    def acknowledge(state, result)
      reason = result.actionable? ? 'parity' : 'nothing_to_crawl'
      ack = Acknowledge.call(actor: :auto, reason:, expected_digest: state['digest'], parity: result, store: @store, notifier: @notifier)
      return Outcome.new(status: :acknowledged, parity: result) if ack.acknowledged?

      reset(:stale, result)
    end

    # The plain alert again (the progress dropped), with the outcome +status+ (never raises).
    def reset(status, result = nil)
      Progress.reset!(store: @store, notifier: @notifier)
      Outcome.new(status:, parity: result)
    end

    # Stores the progress; when it changed, broadcasts the refreshed alert (shown) or removes it from the tabs (hidden).
    def publish(state, change, result)
      payload = result.progress_payload(digest: state['digest'])
      previous = Progress.read(state['digest'])
      Progress.store!(payload)
      return if previous && previous.except('checked_at') == payload.except('checked_at')

      if Progress.alert_shown?(change, payload)
        @notifier.broadcast_change(change, digest: state['digest'], progress: payload)
      elsif Progress.alert_shown?(change, previous)
        @notifier.clear_change
      end
    end
  end
end
