// Action Cable provides the framework to deal with WebSockets in Rails.
// You can generate new channels where WebSocket features live using the `rails generate channel` command.

import { createConsumer } from '@rails/actioncable'

// Must match same values of 'crawler/.env':
export default createConsumer('http://localhost:7000/cable')
