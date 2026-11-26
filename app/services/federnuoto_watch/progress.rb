# frozen_string_literal: true

module FedernuotoWatch
  #
  # = FedernuotoWatch::Progress
  #
  # What the automation is doing about the pending FIN change (0.10.103): the FedernuotoWatch::Parity payload
  # (Result#progress_payload) of the last FedernuotoWatch::ParityCheck, stored in the ops DB (Ops::Snapshot KEY) so the
  # layout renders the alert's progress lines without a board build. A payload belongs to the snapshot of its 'digest':
  # .read ignores it once the watcher stored a newer snapshot.
  #
  # Also the one rule for "the alert is shown" (.alert_shown?), shared by the alert, the "Needs you" item and the status
  # probe: a pending change, unless ALL of these hold: the automation master switch is on right now (a live read, fail
  # closed), the payload belongs to the current snapshot, it is less than MAX_AGE old (every planner pass refreshes it),
  # and it found nothing actionable in the change (rows without a link waiting for the 'Eventi' calendar crawl, or a
  # notice about to be logged). Otherwise the plain alert shows. .reset! drops the payload and shows the alert again in
  # every tab (a switch toggled, a parity check that failed). Never raises.
  #
  module Progress
    KEY = 'fin_watch:progress'
    SOURCE = 'FedernuotoWatch::ParityCheck'
    # A payload older than this never hides the alert (PipelinePlannerJob refreshes it every 15 minutes).
    MAX_AGE = 30.minutes

    module_function

    # Stores the payload (a Hash with a 'digest'); returns true when stored.
    def store!(payload)
      Ops.safely(false) do
        next false unless Ops.available?

        Ops::Snapshot.write!(KEY, payload, source: SOURCE)
        true
      end
    end

    # The stored payload of the snapshot +digest+ (a Hash), or nil.
    def read(digest)
      return nil if digest.blank?

      payload = Ops.safely { Ops::Snapshot.read(KEY)&.payload if Ops.available? }
      payload.is_a?(Hash) && payload['digest'] == digest ? payload : nil
    end

    # Drops the stored payload (the change was acknowledged). Returns true when one was there.
    def clear!
      Ops.safely(false) { Ops.available? && Ops::Snapshot.where(key: KEY).delete_all.positive? }
    end

    # Drops the stored payload and, when there was one and a change is pending, broadcasts the plain alert to every tab
    # (it may have been hidden). Never raises; returns true when the alert was broadcast.
    def reset!(store: StateStore.new, notifier: Notifier.new)
      return false unless clear!

      state = store.read
      change = state['change'].presence
      return false unless alert_shown?(change, nil)

      notifier.broadcast_change(change, digest: state['digest'])
      true
    rescue StandardError => e
      Rails.logger.warn("[FedernuotoWatch::Progress] reset not broadcast: #{e.class}: #{e.message}")
      false
    end

    # True when the alert of the pending +change+ is shown (see the module notes); +progress+: the payload read for its
    # snapshot (or nil).
    def alert_shown?(change, progress, now: Time.current)
      return false unless change.is_a?(Hash) && change['detected_at'].present?

      !hides?(progress, now)
    end

    # True when the payload hides the alert (see the module notes).
    def hides?(progress, now)
      return false unless progress.is_a?(Hash) && progress['automation'] == true && progress['actionable'].to_i.zero?

      checked_at = Time.zone.parse(progress['checked_at'].to_s)
      checked_at.present? && checked_at > now - MAX_AGE && DataFix::Automation.enabled?
    rescue ArgumentError
      false
    end

    # [change, progress] of the store's pending change, the progress read for its snapshot (nil when nothing is pending).
    def for_store(store = StateStore.new)
      state = store.read
      change = state['change'].presence
      return [nil, nil] unless change.is_a?(Hash)

      [change, read(state['digest'])]
    end
  end
end
