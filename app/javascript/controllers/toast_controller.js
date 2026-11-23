import { Controller } from '@hotwired/stimulus'
import { Toast } from 'bootstrap'

const AUTO_HIDE_DELAY = 5000 // (ms)

/**
 * = toast - StimulusJS controller =
 *
 * One instance per flash message rendered as a Bootstrap 5 `.toast` (see FlashAlertComponent).
 * Shows the toast as soon as it connects; non-sticky, non-error toasts hide themselves after 5 seconds.
 * Errors and sticky payloads never auto-hide (`data-toast-autohide-value="false"`).
 * The element is removed from the DOM once hidden.
 *
 * == Values ==
 * - autohide: Boolean (default true)
 * - delay: Number, in ms (default 5000)
 */
export default class extends Controller {
  static values = {
    autohide: { type: Boolean, default: true },
    delay: { type: Number, default: AUTO_HIDE_DELAY }
  }

  connect() {
    this.onHidden = () => this.element.remove()
    this.element.addEventListener('hidden.bs.toast', this.onHidden)
    this.toast = Toast.getOrCreateInstance(this.element, {
      autohide: this.autohideValue,
      delay: this.delayValue
    })
    this.toast.show()
  }

  // A toast disposed during its show/hide transition (e.g. a Turbo visit right after the page load)
  // would make Bootstrap's transition callback hit a null element: dispose it when the transition ends.
  disconnect() {
    this.element.removeEventListener('hidden.bs.toast', this.onHidden)
    const toast = this.toast
    this.toast = null
    if (!toast) return

    if (this.element.classList.contains('showing')) {
      // (deferred: Bootstrap still uses the instance right after triggering 'shown')
      const disposeLater = () => setTimeout(() => toast.dispose(), 0)
      this.element.addEventListener('shown.bs.toast', disposeLater, { once: true })
      this.element.addEventListener('hidden.bs.toast', disposeLater, { once: true })
    } else {
      toast.dispose()
    }
  }
}
