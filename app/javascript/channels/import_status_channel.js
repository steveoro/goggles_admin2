import consumer from "channels/rails_consumer"

document.addEventListener('turbo:load', () => {
  // Subscribe to the channels only when the page is loaded &
  // the URL matches the data_fix or push controller:
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
        console.log('ImportStatusChannel received: ', data);

        // Make sure async msgs do not repeat or get processed twice out of sequence
        // (it may happen using the async adapter as ActionCable backend in dev env).
        // Also, in case the total changes (different data section), make it possible to update the progress:
        const progressBar = document.getElementById('di-progress')
        if (!progressBar) return

        let prevValue = parseInt(progressBar.dataset.value) || 0
        let prevTotal = parseInt(progressBar.dataset.total) || 100
        let currValue = data['progress']
        let currTotal = data['total']

        if (currValue && currTotal && (parseInt(currValue) > prevValue || parseInt(currTotal) != prevTotal)) {
          // Store overall progress to force sequential output in msgs by using the above check:
          progressBar.dataset.value = currValue
          progressBar.dataset.total = currTotal

          // Direct DOM manipulation to show modal and update progress
          const modal = document.getElementById('modal-progress')
          const backdrop = document.getElementById('modal-progress-backdrop')
          if (modal) {
            modal.classList.add('show')
            modal.style.display = 'block'
            if (backdrop) {
              backdrop.style.display = 'block'
            }
            document.body.classList.add('modal-open')
            const msgElement = document.getElementById('progress-msg')
            if (msgElement) {
              msgElement.textContent = `${data['msg']}: ${currValue}/${currTotal}`
            }
            const percent = (currValue * 100 / currTotal).toFixed(1)
            progressBar.setAttribute('aria-valuenow', percent)
            progressBar.style.width = `${percent}%`
            progressBar.textContent = `${percent}%`

            // Hide modal when progress reaches 100%
            if (parseInt(currValue) >= parseInt(currTotal)) {
              setTimeout(() => {
                modal.classList.remove('show')
                modal.style.display = 'none'
                if (backdrop) {
                  backdrop.style.display = 'none'
                }
                document.body.classList.remove('modal-open')
              }, 1000) // Wait 1 second before hiding
            }
          }
        }
        else {
          console.log(data['msg'])
        }
      }
    });
  }
})
