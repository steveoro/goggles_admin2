import { Controller } from '@hotwired/stimulus'

/**
 * = FedernuotoWatch alert controller
 *
 * Attached to the sticky "FIN Riepilogo Eventi changed" alert (FedernuotoWatchAlertComponent).
 *
 * - connect(): the alert may be live-broadcasted (rendered outside of any user session), so its
 *   forms are rendered without CSRF tokens: this adds the current page token to each of them;
 * - dismiss(): removes the alert & acknowledges the change server-side (so that it won't be
 *   shown again on the next page loads).
 *
 * == Values:
 * - ackUrl: URL for the POST acknowledge request
 */
export default class extends Controller {
  static values = { ackUrl: String }

  connect() {
    const token = this.csrfToken()
    if (!token) return

    const param = this.csrfParam()
    this.element.querySelectorAll('form').forEach((form) => {
      if (form.querySelector(`input[name="${param}"]`)) return

      const input = document.createElement('input')
      input.type = 'hidden'
      input.name = param
      input.value = token
      form.appendChild(input)
    })
  }

  dismiss(event) {
    event.preventDefault()
    this.element.remove()
    if (!this.hasAckUrlValue) return

    fetch(this.ackUrlValue, {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'X-CSRF-Token': this.csrfToken() || '', Accept: 'application/json' }
    }).catch((error) => console.error('FedernuotoWatch: acknowledge failed', error))
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.content
  }

  csrfParam() {
    return document.querySelector('meta[name="csrf-param"]')?.content || 'authenticity_token'
  }
}
