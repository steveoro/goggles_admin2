import consumer from "./node_consumer"

$(document).on('turbolinks:load', () => {
  // Subscribe to the channels only when the page is loaded &
  // the URL matches the crawler server controller:
  if (document.location.href.includes('/pull')) {
    consumer.subscriptions.create("CrawlerSrvChannel", {
      // Called when the subscription is ready for use on the server
      connected() {
        // DEBUG:
        // console.log(`CrawlerSrvChannel connected()`);
      },

      // Called when the subscription has been terminated by the server
      disconnected() {
        // DEBUG:
        // console.log(`CrawlerSrvChannel disconnected()`);
      },

      // Called when there's incoming data on the websocket for this channel
      received(data) {
        // DEBUG:
        // console.log(`CrawlerSrvChannel received: ${data}`);
        const parsedMessage = JSON.parse(data);

        // ** STATUS received **
        if (parsedMessage.status) {
          // Status icon + terse state message update:
          $('#crawler-status-icon').removeClass('fa-question-circle-o')
          $('#crawler-status-icon').addClass('fa-cog')
          $('#crawler-status').html(parsedMessage.status)

          // Log display update (1-liner status + full log increase):
          if (parsedMessage.timestamp && parsedMessage.detail) {
            let logLine = `[${parsedMessage.timestamp}] ${parsedMessage.detail}`
            $('#crawler-detail').html(logLine)
            // Full log container found?
            if ($('#crawler_log').parent().html()) {
              let log = $('#crawler_log').html().split('\n')
              if (log.length < 2 || (log.length >= 2 && log[log.length - 2] != logLine)) {
                $('#crawler_log').append(`${logLine}\n`)
              }
            }
            if (parsedMessage.progress) {
              var percent = (parsedMessage.progress * 100 / parsedMessage.total).toFixed(1)
              $('#crawler-progress').attr('aria-valuenow', percent)
              $('#crawler-progress').attr('style', `width: ${percent}%`)
              $('#crawler-progress').text(`${percent}%`)
              $('#crawler-progress-row').removeClass('d-none')

            }
            else {
              $('#crawler-progress-row').addClass('d-none')
            }
          }
          // Clear the log display whenever you receive either an null timestamp or an empty status detail:
          else {
            $('#crawler-detail').html('');
          }

          // ** STATUS: DONE ** => update the list of retrieved calendars:
          if (parsedMessage.status.includes('done')) {
            // TODO
          }
        }

        // Status not yet received:
        else {
          $('#crawler-status-icon').removeClass('fa-cog')
          $('#crawler-status-icon').addClass('fa-question-circle-o')
          $('#crawler-status').html('connecting...');
          $('#crawler-detail').html('');
        }
      },
    });
  }
})
