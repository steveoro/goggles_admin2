# frozen_string_literal: true

module Outbox
  #
  # = Outbox::Notifier
  #
  # Pings every open page (AppNotificationsChannel) when the Outbox changes (script registered or moved, push
  # progress), so that the Outbox page reloads its frame (outbox_controller.js) and the dashboard its zones
  # (live_frames_controller.js). Same payload pattern as SeasonBoard::Notifier: an empty 'html' with a
  # dedicated DOM id. Never raises.
  #
  class Notifier
    DOM_ID = 'outbox-ping'

    # Broadcasts the ping. Returns true on success, false otherwise.
    def self.ping
      ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id: DOM_ID, html: '' })
      true
    rescue StandardError => e
      Rails.logger.warn("[Outbox::Notifier] ping broadcast failed: #{e.class}: #{e.message}")
      false
    end
  end
end
