import consumer from 'channels/rails_consumer'

/**
 * = AppNotificationsChannel consumer
 *
 * App-wide notifications (e.g. the FIN "Riepilogo Eventi" watcher alerts), subscribed once
 * for the whole browsing session (Turbo Drive keeps this module alive across visits), so that
 * any page currently shown gets the alert.
 *
 * Payload: { dom_id: String, html: String }
 * - the element with the same DOM ID gets replaced (or removed, when html is empty);
 * - sticky payloads (root element with the "flash-sticky" class) go to #sticky-alerts, which
 *   turbo-stream flash updates never touch;
 * - any other payload is prepended to #flash-messages as a toast (toast_controller shows it,
 *   auto-hides it and removes it);
 * - every payload is also dispatched as an "app-notification" document event (detail: the payload),
 *   so that page controllers can react to it (e.g. the Season board "season-board-ping", which has
 *   an empty html and no matching element, so it's a no-op here).
 */
const AUTO_HIDE_DELAY = 8000

function flashContainer() {
  let container = document.getElementById('flash-messages')
  if (container) return container

  const parent = document.getElementById('flash-messages-container') || document.body
  container = document.createElement('div')
  container.id = 'flash-messages'
  parent.prepend(container)
  return container
}

function stickyContainer() {
  return document.getElementById('sticky-alerts') || document.querySelector('.app-content') || document.body
}

function buildElement(html, domId) {
  const template = document.createElement('template')
  template.innerHTML = html.trim()
  const element = template.content.firstElementChild
  if (element && domId) element.id = domId
  return element
}

// Fallback for non-toast, non-sticky payloads only (toasts are handled by toast_controller)
function scheduleAutoHide(element) {
  if (element.classList.contains('flash-sticky') || element.classList.contains('toast')) return

  setTimeout(() => {
    element.style.transition = 'opacity 0.6s'
    element.style.opacity = '0'
    setTimeout(() => element.remove(), 700)
  }, AUTO_HIDE_DELAY)
}

consumer.subscriptions.create('AppNotificationsChannel', {
  received(data) {
    document.dispatchEvent(new CustomEvent('app-notification', { detail: data }))
    if (!data || !data.dom_id) return

    const existing = document.getElementById(data.dom_id)
    if (!data.html) {
      if (existing) existing.remove()
      return
    }

    const element = buildElement(data.html, data.dom_id)
    if (!element) return

    if (existing) {
      existing.replaceWith(element)
    } else if (element.classList.contains('flash-sticky')) {
      stickyContainer().prepend(element)
    } else {
      flashContainer().prepend(element)
    }
    scheduleAutoHide(element)
  }
})
