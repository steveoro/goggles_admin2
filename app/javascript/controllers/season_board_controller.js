import { Controller } from '@hotwired/stimulus'

/**
 * = Season board controller
 *
 * Keeps the Season board rows (the "season-board-rows" Turbo frame) up to date:
 * - on a "season-board-ping" notification (dispatched by app_notifications_channel.js as an
 *   "app-notification" document event) the frame is reloaded, debounced;
 * - as a fallback, as long as the page shows queued/running activity (a marker element with
 *   data-season-board-busy="true" inside the frame) the frame is reloaded every `interval` ms,
 *   since the Solid Cable database may be missing on the local setup and broadcasts can't be
 *   relied upon.
 *
 * The reload uses the current page URL, so the filter toggles (query params) are preserved.
 *
 * == Values:
 * - interval: fallback polling period in ms (default 20000)
 * - pingId: dom_id of the ping notification (default 'season-board-ping')
 *
 * == Targets:
 * - frame: the Turbo frame to reload
 */
const DEBOUNCE_DELAY = 500

export default class extends Controller {
  static targets = ['frame']
  static values = { interval: { type: Number, default: 20000 }, pingId: { type: String, default: 'season-board-ping' } }

  connect() {
    this.onNotification = (event) => {
      if (event.detail && event.detail.dom_id === this.pingIdValue) this.scheduleReload()
    }
    document.addEventListener('app-notification', this.onNotification)
    this.timer = setInterval(() => this.reloadIfBusy(), this.intervalValue)
  }

  disconnect() {
    document.removeEventListener('app-notification', this.onNotification)
    clearInterval(this.timer)
    clearTimeout(this.debounce)
  }

  scheduleReload() {
    clearTimeout(this.debounce)
    this.debounce = setTimeout(() => this.reload(), DEBOUNCE_DELAY)
  }

  reloadIfBusy() {
    if (document.hidden || !this.hasFrameTarget) return

    if (this.frameTarget.querySelector('[data-season-board-busy="true"]')) this.reload()
  }

  reload() {
    if (!this.hasFrameTarget) return

    // The cache-busting param makes sure that Turbo loads the frame even if its src didn't change:
    const url = new URL(window.location.href)
    url.searchParams.set('_', Date.now())
    this.frameTarget.src = url.toString()
  }
}
