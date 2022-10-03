# frozen_string_literal: true

#
# = ImportStatusChannel
#
# Realtime updates for any data-import related status message.
# (Except for any crawler status messages, which have a dedicated, stand-alone NodeJS server
#  that does exactly just that.)
#
#   - version:  7-0.4.08
#   - author:   Steve A.
#
class ImportStatusChannel < ApplicationCable::Channel
  # Called when the consumer has successfully become a subscriber to this channel.
  def subscribed
    stream_from("ImportStatusChannel")
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end
