# frozen_string_literal: true

#
# = CrawlerSrvChannel
#
# Realtime updates from the Rails app. (*CURRENTLY UNUSED*)
#
# The actual CrawlerSrv realtime updates are generated & broadcasted by the
# backend NodeJS server running on localhost:7000 (which handles also the Crawler server API endpoints).
#
#   - version:  7-0.3.52
#   - author:   Steve A.
#
class CrawlerSrvChannel < ApplicationCable::Channel
  def subscribed
    # stream_from "some_channel"
  end

  def unsubscribed
    # Any cleanup needed when channel is unsubscribed
  end
end
