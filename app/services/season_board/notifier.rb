# frozen_string_literal: true

module SeasonBoard
  #
  # = SeasonBoard::Notifier
  #
  # Pings every open page (through AppNotificationsChannel) whenever the Season board activity
  # changes (crawl/extraction queued, started or finished), so that the board can reload its frame.
  #
  # The payload uses an empty 'html' with a dedicated DOM id: the generic client handler simply
  # removes a (non-existent) element, while the board listens for that DOM id.
  #
  # Never raises: a broadcast failure (e.g. missing Solid Cable database in a local setup)
  # must never fail the job or the request that triggered it.
  #
  class Notifier
    DOM_ID = 'season-board-ping'

    # Broadcasts the ping. Returns true on success, false otherwise.
    def self.ping
      ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id: DOM_ID, html: '' })
      true
    rescue StandardError => e
      Rails.logger.warn("[SeasonBoard::Notifier] ping broadcast failed: #{e.class}: #{e.message}")
      false
    end
  end
end
