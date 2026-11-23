# frozen_string_literal: true

module Health
  #
  # = Health::Notifier
  #
  # Pings every open page (AppNotificationsChannel) when a health run starts or finishes, so that the health
  # pages and the dashboard card reload their frames (same pattern as SeasonBoard::Notifier: an empty 'html'
  # with a dedicated DOM id). Never raises.
  #
  class Notifier
    DOM_ID = 'health-ping'

    # Broadcasts the ping. Returns true on success, false otherwise.
    def self.ping
      ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id: DOM_ID, html: '' })
      true
    rescue StandardError => e
      Rails.logger.warn("[Health::Notifier] ping broadcast failed: #{e.class}: #{e.message}")
      false
    end
  end
end
