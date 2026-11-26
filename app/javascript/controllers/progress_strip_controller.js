import { Controller } from '@hotwired/stimulus'

const FINISHED_MEMORY = 20 // (finished operations remembered)

// Operations already ended by their 'done', kept across the Turbo visits (this module outlives them), so that a late
// tick (messages may arrive out of order) never shows the strip again. Import::Progress::Cable never reuses an op
// after its 'done'.
const finishedOps = []

function rememberFinished (op) {
  if (!op || finishedOps.includes(op)) return
  finishedOps.push(op)
  if (finishedOps.length > FINISHED_MEMORY) finishedOps.shift()
}

/**
 * = progress-strip - StimulusJS controller =
 *
 * The progress strip under the top bar (Shell::ProgressStripComponent, rendered once by the layout): the live
 * progress of the operator's own long requests. Fed by ImportStatusChannel (channels/import_status_channel.js),
 * which dispatches every message as an `import-status` document event; bound with
 * `data-action="import-status@document->progress-strip#update turbo:before-cache@document->progress-strip#reset"`.
 *
 * Messages (Import::Progress::Cable, one `op` per operation):
 * - a tick `{ op, seq, scope, msg, progress, total }`: shows the panel (message, scope, count, bar); a new `op`
 *   starts over, an older or repeated `seq` of the current op is ignored, so is any tick of a finished op;
 * - the end `{ op, state: 'done' }`: hides the panel when it shows that op (another op keeps it).
 * The panel also hides after `silenceDelay` ms without a message (a safety net for a lost 'done'; 0: never), with its
 * close button (for the rest of that op) and before Turbo caches the page (so Back never restores it); a page, fresh
 * or restored, starts hidden; disconnect only clears the timer. It is an overlay letting the clicks through: never
 * modal.
 * The always-rendered live region (`status` target) gets "scope: message" whenever that text changes.
 *
 * == Targets ==
 * - panel: the visible strip (toggled with `hidden`); status: the polite live region;
 * - message, scope, count: texts; progress: the `.progress` wrapper (aria-valuenow); bar: the `.progress-bar`
 *
 * == Values ==
 * - silenceDelay: Number, ms (rendered from Shell::ProgressStripComponent::SILENCE_DELAY)
 *
 * == Actions ==
 * - update (import-status@document), reset (turbo:before-cache@document), dismiss (close button)
 */
export default class extends Controller {
  static targets = ['panel', 'status', 'message', 'scope', 'count', 'progress', 'bar']
  static values = { silenceDelay: Number }

  connect () {
    this.defaultMessage = this.hasMessageTarget ? this.messageTarget.textContent : ''
    this.reset()
  }

  // Clean-up only (the timer and the operation): the element leaves the page, its state doesn't matter any more. What
  // Turbo caches is hidden by the turbo:before-cache reset (the snapshot is cloned after this disconnect).
  disconnect () {
    this.forget()
  }

  /**
   * Handles an `import-status` event (detail: the ImportStatusChannel payload).
   * @param {CustomEvent} event
   */
  update (event) {
    const data = event.detail || {}
    const op = data.op || null
    if (data.state === 'done') {
      this.finish(op)
      return
    }
    if (op && finishedOps.includes(op)) return

    const seq = Number.parseInt(data.seq, 10)
    if (op !== this.op) {
      this.start(op)
    } else if (Number.isFinite(seq) && seq <= this.seq) {
      return
    }
    if (Number.isFinite(seq)) this.seq = seq
    this.armSilenceTimer()
    if (this.dismissed) return

    this.render(data)
    this.setHidden(false)
  }

  // Hides the panel and forgets the current operation.
  reset () {
    this.forget()
    this.setHidden(true)
    this.render({})
  }

  // (close button) Hides the panel for the rest of the current operation.
  dismiss () {
    this.dismissed = true
    this.setHidden(true)
  }

  // ---------------------------------------------------------------------------

  forget () {
    clearTimeout(this.silenceTimer)
    this.silenceTimer = null
    this.op = null
    this.seq = 0
    this.dismissed = false
  }

  start (op) {
    this.op = op
    this.seq = 0
    this.dismissed = false
  }

  finish (op) {
    rememberFinished(op)
    if (op && this.op && op !== this.op) return // (another operation is shown)

    this.reset()
  }

  armSilenceTimer () {
    clearTimeout(this.silenceTimer)
    this.silenceTimer = null
    if (this.silenceDelayValue > 0) this.silenceTimer = setTimeout(() => this.reset(), this.silenceDelayValue)
  }

  setHidden (hidden) {
    if (this.hasPanelTarget) this.panelTarget.hidden = hidden
    if (hidden && this.hasStatusTarget) this.setText(this.statusTarget, '')
  }

  // Sets the texts and the bar from a tick (an empty object: the initial state).
  render ({ msg, scope, progress, total }) {
    const current = Number(progress) || 0
    const max = Number(total) || 0
    const percent = max > 0 ? Math.min(100, Math.max(0, Math.round((current / max) * 100))) : 0
    const message = msg ? String(msg) : this.defaultMessage
    const scopeText = scope ? String(scope) : ''

    if (this.hasMessageTarget) this.setText(this.messageTarget, message)
    if (this.hasScopeTarget) {
      this.setText(this.scopeTarget, scopeText)
      this.scopeTarget.hidden = !scopeText
    }
    if (this.hasCountTarget) this.setText(this.countTarget, max > 0 ? `${current}/${max}` : '')
    if (this.hasProgressTarget) this.progressTarget.setAttribute('aria-valuenow', String(percent))
    if (this.hasBarTarget) this.barTarget.style.width = `${percent}%`
    // (the live region: only the scope and the message, so the count updates are not read one by one)
    if (this.hasStatusTarget && msg) this.setText(this.statusTarget, [scopeText, message].filter(Boolean).join(': '))
  }

  // (only on change: an identical text must not be announced again)
  setText (element, text) {
    if (element.textContent !== text) element.textContent = text
  }
}
