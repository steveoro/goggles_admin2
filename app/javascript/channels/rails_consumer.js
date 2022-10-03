// Action Cable provides the framework to deal with WebSockets in Rails.
// You can generate new channels where WebSocket features live using the `rails generate channel` command.

import { createConsumer } from '@rails/actioncable'

// This should create a consumer for the internal ActionCable websocket server:
export default createConsumer('/cable')
