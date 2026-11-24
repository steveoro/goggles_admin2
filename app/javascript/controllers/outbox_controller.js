import { Controller } from '@hotwired/stimulus'

/**
 * = Outbox controller
 *
 * Keeps the SQL Outbox page (the "outbox-scripts" Turbo frame) up to date and handles the row selection:
 * - on an "outbox-ping" notification (Outbox::Notifier, dispatched by app_notifications_channel.js as an
 *   "app-notification" document event) the frame is reloaded, debounced;
 * - as a fallback, while a push run is live (a marker element with data-outbox-busy="true" inside the frame)
 *   the frame is reloaded every `interval` ms (the Solid Cable database may be missing on the local setup);
 * - the row focused by the page URL (?focus=<filename>, data-outbox-focus="true") is scrolled into view once;
 * - the checked pending rows feed the "Push selected" link (the confirmation page, ids[]=...).
 *
 * The reload uses the current page URL plus `frame=1` (the server then renders only the frame, without the
 * layout), so the folder filter and the focus are preserved.
 *
 * == Values:
 * - interval: fallback polling period in ms (default 5000)
 * - pingId: dom_id of the ping notification (default 'outbox-ping')
 * - pushUrl: path of the push confirmation page
 *
 * == Targets:
 * - frame: the Turbo frame to reload; checkbox: the selection checkboxes; pushSelected: the "Push selected"
 *   link; count: its counter
 */
const DEBOUNCE_DELAY = 500

export default class extends Controller {
  static targets = ['frame', 'checkbox', 'pushSelected', 'count']
  static values = {
    interval: { type: Number, default: 5000 },
    pingId: { type: String, default: 'outbox-ping' },
    pushUrl: { type: String, default: '/outbox/push/new' }
  }

  connect () {
    this.onNotification = (event) => {
      if (event.detail && event.detail.dom_id === this.pingIdValue) this.scheduleReload()
    }
    document.addEventListener('app-notification', this.onNotification)
    this.timer = setInterval(() => this.reloadIfBusy(), this.intervalValue)
    this.scrolled = false
    this.scrollToFocus()
  }

  disconnect () {
    document.removeEventListener('app-notification', this.onNotification)
    clearInterval(this.timer)
    clearTimeout(this.debounce)
  }

  // (called again after each frame reload: the checkboxes are new elements)
  frameTargetConnected () {
    this.toggle()
  }

  checkboxTargetConnected () {
    this.toggle()
  }

  // Updates the "Push selected" link with the checked script ids.
  toggle () {
    if (!this.hasPushSelectedTarget) return

    const ids = this.checkboxTargets.filter((box) => box.checked).map((box) => box.value)
    const url = new URL(this.pushUrlValue, window.location.origin)
    ids.forEach((id) => url.searchParams.append('ids[]', id))
    this.pushSelectedTarget.href = url.pathname + url.search
    this.pushSelectedTarget.classList.toggle('disabled', ids.length === 0)
    this.pushSelectedTarget.setAttribute('aria-disabled', ids.length === 0 ? 'true' : 'false')
    if (this.hasCountTarget) this.countTarget.textContent = ids.length > 0 ? `(${ids.length})` : ''
  }

  scrollToFocus () {
    if (this.scrolled) return

    const row = this.element.querySelector('[data-outbox-focus="true"]')
    if (!row) return

    this.scrolled = true
    const details = row.closest('details')
    if (details) details.open = true
    row.scrollIntoView({ block: 'center' })
  }

  scheduleReload () {
    clearTimeout(this.debounce)
    this.debounce = setTimeout(() => this.reload(), DEBOUNCE_DELAY)
  }

  reloadIfBusy () {
    if (document.hidden || !this.hasFrameTarget) return

    if (this.frameTarget.querySelector('[data-outbox-busy="true"]')) this.reload()
  }

  reload () {
    if (!this.hasFrameTarget) return
    // (never drop the operator's selection under their cursor)
    if (this.checkboxTargets.some((box) => box.checked)) return

    const url = new URL(window.location.href)
    url.searchParams.set('frame', '1')
    url.searchParams.set('_', Date.now())
    this.frameTarget.src = url.toString()
  }
}
