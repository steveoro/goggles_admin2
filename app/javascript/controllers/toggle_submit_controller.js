import { Controller } from '@hotwired/stimulus'

// The switch that submitted last (its DOM id) and until when its replacement may take the focus back (ms):
// a turbo stream replacing the form drops the keyboard focus to <body>.
const REFOCUS_WINDOW = 10000
let refocus = { id: null, until: 0 }

/**
 * = toggle-submit - StimulusJS controller =
 *
 * Companion of Switch::ToggleFormComponent: a stored boolean shown as a Bootstrap switch inside a small POST form.
 *
 * - On change, the form is submitted at once (`requestSubmit()`, so Turbo handles it like a click on a submit
 *   button); the switch is disabled while the request is in flight (after the submit started: a disabled checkbox
 *   would not be posted).
 * - When the submit ends (`turbo:submit-end` on the form), the switch is enabled again; when the submit failed (network
 *   error, or an error status), the switch is also put back to its previous state and refocused.
 * - A Turbo Stream response usually replaces the whole form: the new switch takes the keyboard focus back when the
 *   old one had it (and nothing else took it meanwhile). A redirect is followed by Turbo like any other submission.
 * - The server-rendered position and disabled state (values `checked` / `disabled`) are put back on connect and before
 *   Turbo caches the page: a page restored from the cache (Back) never shows a stuck, disabled switch or a position
 *   that was never stored.
 *
 * == Targets
 * - input: the checkbox (role="switch")
 *
 * == Values
 * - checked: Boolean, the server-rendered position; disabled: Boolean, the server-rendered disabled state
 *
 * == Actions
 * - change->toggle-submit#submit (on the checkbox)
 */
export default class extends Controller {
  static targets = ['input']
  static values = { checked: Boolean, disabled: Boolean }

  connect () {
    this.pending = false
    this.restoreServerState()
    this.onSubmitEnd = (event) => this.submitEnded(event)
    this.onBeforeCache = () => this.restoreServerState()
    this.element.addEventListener('turbo:submit-end', this.onSubmitEnd)
    document.addEventListener('turbo:before-cache', this.onBeforeCache)
    if (this.hasInputTarget && refocus.id === this.inputTarget.id && Date.now() <= refocus.until) {
      refocus = { id: null, until: 0 }
      this.focusIfLost()
    }
  }

  disconnect () {
    this.element.removeEventListener('turbo:submit-end', this.onSubmitEnd)
    document.removeEventListener('turbo:before-cache', this.onBeforeCache)
  }

  submit () {
    if (!this.hasInputTarget || this.pending) return

    this.previous = !this.inputTarget.checked
    this.pending = true
    refocus = { id: this.inputTarget.id, until: Date.now() + REFOCUS_WINDOW }
    this.element.setAttribute('aria-busy', 'true')
    if (typeof this.element.requestSubmit === 'function') {
      this.element.requestSubmit()
    } else {
      this.element.submit()
    }
    // (the form data has been collected by now)
    this.inputTarget.disabled = true
  }

  submitEnded (event) {
    const success = Boolean(event.detail && event.detail.success)
    this.pending = false
    this.element.removeAttribute('aria-busy')
    if (!this.hasInputTarget) return

    this.inputTarget.disabled = this.disabledValue
    if (!success) {
      this.inputTarget.checked = this.previous
      refocus = { id: null, until: 0 }
    }
    // (on success the replacement, if any, refocuses itself when it connects)
    this.focusIfLost()
  }

  // Back to the server-rendered position (not while a request of this switch is in flight on the live page).
  restoreServerState () {
    this.element.removeAttribute('aria-busy')
    if (!this.hasInputTarget) return

    this.inputTarget.checked = this.checkedValue
    this.inputTarget.disabled = this.disabledValue
  }

  // Focuses the switch when the keyboard focus was lost (on <body>, or on a removed element).
  focusIfLost () {
    if (!this.hasInputTarget || this.inputTarget.disabled || !this.element.isConnected) return

    const active = document.activeElement
    if (!active || active === document.body || !active.isConnected) this.inputTarget.focus()
  }
}
