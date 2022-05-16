/*
 * Backend API + crawler server main start file.
 *
 * -- Note: --
 * Install all modules enlisted below with 'npm install <package-name> --save', except node.js itself:
 *  > sudo apt-get install nodejs
 */
const express = require('express')
// const mysql = require('mysql2') // (fast client for MySQL) TODO
const helmet = require("helmet")
const { WebSocketServer } = require('ws')
const app = express()

// Setup environment variables into process.env:
var dotenv = require('dotenv')
var dotenvExpand = require('dotenv-expand')
var myEnv = dotenv.config()
dotenvExpand.expand(myEnv)

// Local modules:
const apiRouter = require("./api")
const CrawlUtil = require('./utility') // Crawler utility functions
// ----------------------------------------------------------------------------

app.use(helmet());          // Middleware: handle CSRF, XSS, etc.
app.use(express.json()); // Middleware: parsing JSON req bodies

// Debug middleware function with no mount path:  executed for every request to the router
/*
app.use((req, _res, next) => {
  console.log('Time:', Date.now())
  console.log('REQ body:', req.body)
  console.log('REQ originalUrl:', req.originalUrl)
  console.log('REQ query:', req.query)
  console.log('REQ params:', req.params)
  next()
})
*/

// Middleware: handle invalid requests:
app.use((err, _, res, next) => {
  if (err.status == 400) {
    res.status(err.status).json({
      message: "Invalid JSON request"
    });
  };
  return next(err);
});

app.use(apiRouter); // Middleware: crawler API

// HTML fallback response:
// app.get('/', (_req, res) => {
//   res.send('Please send a valid JSON request to any supported endpoint.')
// })
// ----------------------------------------------------------------------------

// Server start:
// (`server` is a vanilla Node.js HTTP server. See:
//  https://www.npmjs.com/package/ws#multiple-servers-sharing-a-single-https-server)
const httpServer = app.listen(process.env.CRAWLER_PORT, () => {
  console.log(`*** Crawler backend server running ***`)
  console.log(`Environment....: ${process.env.NODE_ENV}`)
  console.log(`Listening on...: ${process.env.CRAWLER_HOST}:${process.env.CRAWLER_PORT}`)
  console.log(`Websocket on...: ${process.env.CRAWLER_PATH}`)
  console.log(`Resetting status file...`)
  CrawlUtil.updateStatus('Backend started, crawler not yet running', 'OK, idle')
})
// ----------------------------------------------------------------------------

const wss = new WebSocketServer({
  server: httpServer,
  path: process.env.CRAWLER_PATH
});

/**
 * Used in timer to broadcast crawler state to all connected clients.
 */
function heartbeat() {
  // DEBUG
  // console.log(`heartbeat()`);
  this.isAlive = true;
}
// ----------------------------------------------------------------------------

wss.on('connection', function connection(ws) {
  // DEBUG:
  // console.log(`on connection(): BEFORE handshake send`);
  ws.isAlive = true;
  // 1. ActionCable Handshake:
  ws.send(JSON.stringify({ type: 'welcome' }));

  ws.on('pong', heartbeat);

  ws.on('message', function message(data) {
    const parsedMessage = JSON.parse(data);
    // DEBUG:
    // console.log('received: %s', parsedMessage);
    if (parsedMessage.command === 'subscribe') {
      /*
         Note that the JSON response for a positive subscription to a specific channel
         with an ID ({command: "subscribe", identifier: ...}), should include that full ID
         in the stringified identifier sent out, as in:
         {
          "identifier": "{\"channel\":\"ChatChannel\",\"id\":42}",
          "type": "confirm_subscription"
         }
      */
      // Create a local property to store the subscribed channel:
      wss.actionCableChannelID = parsedMessage.identifier
      // Confirm subscription for any requested channel:
      ws.send(JSON.stringify({
        identifier: wss.actionCableChannelID,
        type: 'confirm_subscription'
      }));
    }

    /*
      Typical JSON action request message: (this requires a subparsing of the message.data)
      {
        command: 'message',
        identifier: '{"channel":"CrawlerSrvChannel"}',
        data: '{"action":"whatever"}'
      }
    */
    if (parsedMessage.command === 'message' && parsedMessage.data) {
      // DEBUG
      console.log('wss(message) - data: %s', parsedMessage.data);
      // TODO - (unused yet)
    }

    if (parsedMessage.command === 'unsubscribe') {
      ws.emit('close')
    }
  });
});
// ----------------------------------------------------------------------------

/*
 * Interval timer w/ ping-pong handshake used for current crawler status reporting.
 * The status is read from a JSON file (searched for in the running folder of the crawler server).
 *
 * For ping handshake, see:
 * - https://github.com/websockets/ws/blob/master/doc/ws.md#websocketpingdata-mask-callback
 * - https://docs.anycable.io/misc/action_cable_protocol#:~:text=Action%20Cable%20is%20a%20framework,protocol%20for%20client%2Dserver%20communication.
 */
const interval = setInterval(function ping() {
  // DEBUG
  // console.log(`Pinging clients...`);
  wss.clients.forEach(function each(ws) {
    if (ws.isAlive === false) {
      wss.actionCableChannelID = null // Clear channel ID
      return ws.terminate();
    }
    else {
      ws.ping(JSON.stringify({ type: 'ping', message: Date.now() }));
      // If the WebSocketServer has a stored channel ID, send the default status message to the client:
      if (wss.actionCableChannelID) {
        ws.send(JSON.stringify({
          identifier: wss.actionCableChannelID,
          message: JSON.stringify(CrawlUtil.readStatus())
        }));
      }
    }
    ws.isAlive = false;
  });
}, 1000);
// ----------------------------------------------------------------------------

wss.on('close', function close() {
  // DEBUG
  console.log(`on close()`);
  clearInterval(interval);
});
// ----------------------------------------------------------------------------

module.exports = app;

// TODO: connect to DB:
/*
// create the connection to database
const connection = mysql.createConnection({
  host: 'localhost',
  user: 'root',
  database: 'test'
});

// with placeholder
connection.query(
  'SELECT * FROM `table` WHERE `name` = ? AND `age` > ?',
  ['Page', 45],
  function (err, results) {
    console.log(results);
  }
);
*/
