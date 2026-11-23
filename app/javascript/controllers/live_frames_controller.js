import { Controller } from '@hotwired/stimulus'

/**
 * = live-frames - StimulusJS controller =
 *
 * Keeps a page made of Turbo frames (e.g. the dashboard zones) up to date (generalised from
 * season_board_controller.js, which keeps the Season board's own behaviour):
 * - on any "app-notification" document event (dispatched by app_notifications_channel.js for each
 *   AppNotificationsChannel broadcast: Season board pings, FIN watcher alerts, ...) every frame target
 *   is reloaded, debounced; set the pingIds value to react only to some DOM ids;
 * - as a fallback, while any frame shows something running (an element with data-live-busy="true"),
 *   every frame target is reloaded every `interval` ms: the Solid Cable database may be missing on the
 *   local setup, so broadcasts can't be relied upon.
 *
 * A frame is reloaded only after its first load (it has a src and is not loading already).
 *
 * == Values:
 * - interval: fallback polling period in ms (default 20000)
 * - pingIds: Array of notification DOM ids that trigger a reload (default: [] = any notification)
 *
 * == Targets:
 * - frame: the Turbo frames to reload
 */
const DEBOUNCE_DELAY = 500

export default class extends Controller {
  static targets = ['frame']
  static values = { interval: { type: Number, default: 20000 }, pingIds: { type: Array, default: [] } }

  connect () {
    this.onNotification = (event) => {
      const domId = event.detail && event.detail.dom_id
      if (this.pingIdsValue.length === 0 || this.pingIdsValue.includes(domId)) this.scheduleReload()
    }
    document.addEventListener('app-notification', this.onNotification)
    this.timer = setInterval(() => this.reloadIfBusy(), this.intervalValue)
  }

  disconnect () {
    document.removeEventListener('app-notification', this.onNotification)
    clearInterval(this.timer)
    clearTimeout(this.debounce)
  }

  scheduleReload () {
    clearTimeout(this.debounce)
    this.debounce = setTimeout(() => this.reload(), DEBOUNCE_DELAY)
  }

  reloadIfBusy () {
    if (document.hidden) return

    if (this.element.querySelector('[data-live-busy="true"]')) this.reload()
  }

  reload () {
    this.frameTargets.forEach((frame) => {
      if (!frame.src || frame.hasAttribute('busy') || typeof frame.reload !== 'function') return

      frame.reload()
    })
  }
}
