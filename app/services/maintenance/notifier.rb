# frozen_string_literal: true

module Maintenance
  #
  # = Maintenance::Notifier
  #
  # Pings every open page (AppNotificationsChannel) when an operation run changes state, so that its run page reloads
  # its status frame (live-frames, ping id 'operation-run-<id>') and the operations list its history. Same payload
  # pattern as Health::Notifier: an empty 'html' with a dedicated DOM id. Never raises.
  #
  class Notifier
    DOM_ID = 'operation-ping'

    # DOM id pinged for one run.
    def self.dom_id_for(run) = "operation-run-#{run.respond_to?(:id) ? run.id : run}"

    # Broadcasts the generic ping and the run one. Returns true on success, false otherwise.
    def self.ping(run = nil)
      ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id: DOM_ID, html: '' })
      ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id: dom_id_for(run), html: '' }) if run
      true
    rescue StandardError => e
      Rails.logger.warn("[Maintenance::Notifier] ping broadcast failed: #{e.class}: #{e.message}")
      false
    end
  end
end
