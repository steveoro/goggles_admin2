# frozen_string_literal: true

module FedernuotoWatch
  #
  # = FedernuotoWatch::Notifier
  #
  # Live-pushes the watcher alerts to every connected browser, whatever page is currently open,
  # through AppNotificationsChannel.
  #
  # Each payload carries the rendered alert HTML and its DOM ID: the client assigns the ID to the
  # alert root element, replacing any existing element with the same ID or prepending it to the
  # flash messages container; an empty 'html' removes the element.
  #
  # NOTE: the HTML is rendered outside of any user session, so it must never embed CSRF tokens
  #       (the alert forms get the token from the page meta tag on connect; see
  #       federnuoto_watch_controller.js).
  #
  class Notifier
    # Broadcasts the sticky change alert.
    def broadcast_change(change)
      broadcast(FedernuotoWatch::ALERT_DOM_ID, render(FedernuotoWatchAlertComponent.new(change:)))
    end

    # Removes the change alert from any open page.
    def clear_change
      broadcast(FedernuotoWatch::ALERT_DOM_ID, '')
    end

    # Broadcasts a transient info message (auto-hidden by the client).
    def broadcast_info(message)
      broadcast_flash(:info, message)
    end

    # Broadcasts a transient error message.
    def broadcast_error(message)
      broadcast_flash(:error, message)
    end

    private

    def broadcast_flash(symbol, message)
      html = render(FlashAlertComponent.new(symbol:, title: I18n.t('federnuoto_watch.title'), body: message))
      broadcast(FedernuotoWatch::INFO_DOM_ID, html)
    end

    def render(component)
      ApplicationController.render(component, layout: false)
    end

    def broadcast(dom_id, html)
      ActionCable.server.broadcast(AppNotificationsChannel::STREAM, { dom_id:, html: })
    end
  end
end
