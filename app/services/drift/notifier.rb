# frozen_string_literal: true

module Drift
  #
  # = Drift::Notifier
  #
  # Pings every open page (AppNotificationsChannel) after a DB sync check, so that /db_sync and the dashboard
  # reload their frames (live_frames_controller.js). Same payload pattern as Outbox::Notifier. Never raises.
  #
  class Notifier
    DOM_ID = 'db-sync-ping'

    # Broadcasts the ping. Returns true on success, false otherwise.
    def self.ping
      ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id: DOM_ID, html: '' })
      true
    rescue StandardError => e
      Rails.logger.warn("[Drift::Notifier] ping broadcast failed: #{e.class}: #{e.message}")
      false
    end
  end
end
