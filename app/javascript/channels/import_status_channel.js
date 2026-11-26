import consumer from 'channels/rails_consumer'

/**
 * = ImportStatusChannel consumer
 *
 * Progress of the operator's own long requests (Import::Progress::Cable, interactive requests only: background jobs
 * never broadcast here). Subscribed once for the whole browsing session (Turbo Drive keeps this module alive across
 * visits, as app_notifications_channel.js), every message is dispatched as an "import-status" document event
 * (detail: the payload) for the progress strip under the top bar (Shell::ProgressStripComponent,
 * progress_strip_controller.js), which orders and filters the messages by op & seq.
 *
 * Payloads: { op, seq, scope, msg, progress, total } (a tick), { op, state: 'done' } (end of the operation).
 */
consumer.subscriptions.create('ImportStatusChannel', {
  received(data) {
    if (!data) return

    document.dispatchEvent(new CustomEvent('import-status', { detail: data }))
  }
})
