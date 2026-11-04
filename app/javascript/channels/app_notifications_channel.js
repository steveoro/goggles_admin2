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
 * - otherwise the alert is prepended to the flash messages container;
 * - non-sticky alerts fade out automatically.
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

function buildElement(html, domId) {
  const template = document.createElement('template')
  template.innerHTML = html.trim()
  const element = template.content.firstElementChild
  if (element && domId) element.id = domId
  return element
}

function scheduleAutoHide(element) {
  if (element.classList.contains('flash-sticky')) return

  setTimeout(() => {
    element.style.transition = 'opacity 0.6s'
    element.style.opacity = '0'
    setTimeout(() => element.remove(), 700)
  }, AUTO_HIDE_DELAY)
}

consumer.subscriptions.create('AppNotificationsChannel', {
  received(data) {
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
    } else {
      flashContainer().prepend(element)
    }
    scheduleAutoHide(element)
  }
})
