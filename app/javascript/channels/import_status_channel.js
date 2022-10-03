import consumer from "./rails_consumer"

$(document).on('turbolinks:load', () => {
  // Subscribe to the channels only when the page is loaded &
  // the URL matches the crawler server controller:
  if (document.location.href.includes('/data_fix') ||
      document.location.href.includes('/push')) {
    consumer.subscriptions.create("ImportStatusChannel", {
      // Called when the subscription is ready for use on the server
      connected() {
        // DEBUG:
        console.log(`ImportStatusChannel connected()`);
      },

      // Called when the subscription has been terminated by the server
      disconnected() {
        // DEBUG:
        console.log(`ImportStatusChannel disconnected()`);
      },

      // Called when there's incoming data on the websocket for this channel
      received(data) {
        // DEBUG:
        // console.log('ImportStatusChannel received: ', data);

        // Make sure async msgs do not repeat or get processed twice out of sequence
        // (it may happen using the async adapter as ActionCable backend in dev env).
        // Also, in case the total changes (different data section), make it possible to update the progress:
        let prevValue = $('#di-progress').data('value')
        let prevTotal = $('#di-progress').data('total')
        let currValue = data['progress']
        let currTotal = data['total']

        if (currValue && currTotal && (parseInt(currValue) > prevValue || parseInt(currTotal) != prevTotal)) {
          // Store overall progress to force sequential output in msgs by using the above check:
          $('#di-progress').data('value', currValue)
          $('#di-progress').data('total', currTotal)
          $('#modal-progress').modal('show')
          var msg = `${data['msg']}: ${currValue}/${currTotal}`
          console.log(msg)
          $('#progress-msg').text(msg)

          var percent = (currValue * 100 / currTotal).toFixed(1)
          $('#di-progress').attr('aria-valuenow', percent)
          $('#di-progress').text(`${percent}%`)
          $('#di-progress').attr('style', `width: ${percent}%`)
        }
        else {
          console.log(data['msg'])
        }
      }
    });
  }
})
