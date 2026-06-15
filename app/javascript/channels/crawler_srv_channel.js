import consumer from "channels/node_consumer"

document.addEventListener('turbo:load', () => {
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

        const statusIcon = document.getElementById('crawler-status-icon')
        const statusText = document.getElementById('crawler-status')
        const detailText = document.getElementById('crawler-detail')
        const crawlerLog = document.getElementById('crawler_log')
        const progressBar = document.getElementById('crawler-progress')
        const progressRow = document.getElementById('crawler-progress-row')

        // ** STATUS received **
        if (parsedMessage.status) {
          // Status icon + terse state message update:
          if (statusIcon) {
            statusIcon.classList.remove('fa-question-circle-o')
            statusIcon.classList.add('fa-cog')
          }
          if (statusText) {
            statusText.innerHTML = parsedMessage.status
          }

          // Log display update (1-liner status + full log increase):
          if (parsedMessage.timestamp && parsedMessage.detail) {
            let logLine = `[${parsedMessage.timestamp}] ${parsedMessage.detail}`
            if (detailText) {
              detailText.innerHTML = logLine
            }
            // Full log container found?
            if (crawlerLog && crawlerLog.parentElement) {
              let log = crawlerLog.innerHTML.split('\n')
              if (log.length < 2 || (log.length >= 2 && log[log.length - 2] != logLine)) {
                crawlerLog.innerHTML += `${logLine}\n`
              }
            }
            if (parsedMessage.progress && progressBar) {
              var percent = (parsedMessage.progress * 100 / parsedMessage.total).toFixed(1)
              progressBar.setAttribute('aria-valuenow', percent)
              progressBar.style.width = `${percent}%`
              progressBar.textContent = `${percent}%`
              if (progressRow) {
                progressRow.classList.remove('d-none')
              }
            }
            else if (progressRow) {
              progressRow.classList.add('d-none')
            }
          }
          // Clear the log display whenever you receive either an null timestamp or an empty status detail:
          else if (detailText) {
            detailText.innerHTML = ''
          }

          // ** STATUS: DONE ** => update the list of retrieved calendars:
          if (parsedMessage.status.includes('done')) {
            // TODO
          }
        }

        // Status not yet received:
        else {
          if (statusIcon) {
            statusIcon.classList.remove('fa-cog')
            statusIcon.classList.add('fa-question-circle-o')
          }
          if (statusText) {
            statusText.innerHTML = 'connecting...'
          }
          if (detailText) {
            detailText.innerHTML = ''
          }
        }
      },
    });
  }
})
