# frozen_string_literal: true

#
# = AppNotificationsChannel
#
# App-wide realtime notifications, subscribed on every page regardless of the current URL
# (see app/javascript/channels/app_notifications_channel.js).
#
# Broadcast payload: { dom_id: String, html: String } (an empty html removes the element).
#
class AppNotificationsChannel < ApplicationCable::Channel
  # Stream name
  STREAM = 'AppNotificationsChannel'

  # Called when the consumer has successfully become a subscriber to this channel.
  def subscribed
    stream_from(STREAM)
  end
end
