import { Controller } from '@hotwired/stimulus'
import { Modal } from 'bootstrap'

// Elements Bootstrap's scrollbar helper pads while a modal is open (+ the body):
const FIXED_CONTENT = '.fixed-top, .fixed-bottom, .is-fixed, .sticky-top'
const ADJUSTED_STYLES = ['overflow', 'padding-right', 'margin-right']

// Restores the inline styles changed by Bootstrap's scrollbar helper (it saves the original
// values as data-bs-<property> attributes), as its own reset would.
function resetScrollbarAdjustments () {
  for (const element of [document.body, ...document.querySelectorAll(FIXED_CONTENT)]) {
    for (const property of ADJUSTED_STYLES) {
      const savedValue = element.getAttribute(`data-bs-${property}`)
      if (savedValue === null) {
        if (element === document.body || property !== 'overflow') element.style.removeProperty(property)
      } else {
        element.removeAttribute(`data-bs-${property}`)
        element.style.setProperty(property, savedValue)
      }
    }
  }
}

/**
 * = StimulusJS controller for auto-opening Bootstrap 5 modals =
 *
 * Bound to a ".modal" element that gets injected into the page via a Turbo Stream response:
 * as soon as the controller connects, the modal is shown.
 *
 * This replaces the legacy rails-ujs `.js.erb` pattern that used to call
 * `$('#some-modal').modal()` after an AJAX DOM replacement.
 *
 * == Usage ==
 * Add `data-controller="modal"` to the `.modal` root element rendered inside
 * the Turbo Stream target, e.g.:
 *
 *   .modal.fade{ id: 'file-actions-modal', 'data-controller' => 'modal' }
 *
 * Any element with `data-bs-dismiss="modal"` closes it as usual (Bootstrap data API).
 * Tooltips inside the modal need no setup (delegated by the layout's tooltips controller).
 *
 * @author Steve A.
 */
export default class extends Controller {
  /**
   * Shows the bound modal when connected to the DOM.
   */
  connect () {
    this.transitioning = false
    this.onTransitionStart = () => { this.transitioning = true }
    this.onTransitionEnd = () => { this.transitioning = false }
    this.element.addEventListener('show.bs.modal', this.onTransitionStart)
    this.element.addEventListener('hide.bs.modal', this.onTransitionStart)
    this.element.addEventListener('shown.bs.modal', this.onTransitionEnd)
    this.element.addEventListener('hidden.bs.modal', this.onTransitionEnd)
    Modal.getOrCreateInstance(this.element).show()
  }

  /**
   * Disposes the modal when the controller is disconnected (e.g. element removed by a subsequent
   * Turbo Stream replacement). dispose() instead of hide(), which would animate on a detached node
   * and reset the body state later, possibly under the next modal.
   * While a show/hide transition is running, Bootstrap's pending callbacks still need the instance:
   * the teardown then waits for the transition to end (those callbacks also run on detached nodes).
   */
  disconnect () {
    const element = this.element
    element.removeEventListener('show.bs.modal', this.onTransitionStart)
    element.removeEventListener('hide.bs.modal', this.onTransitionStart)
    element.removeEventListener('shown.bs.modal', this.onTransitionEnd)
    element.removeEventListener('hidden.bs.modal', this.onTransitionEnd)
    if (!this.transitioning) {
      this.teardown(element)
      return
    }
    const finish = () => {
      element.removeEventListener('shown.bs.modal', finish)
      element.removeEventListener('hidden.bs.modal', finish)
      this.teardown(element)
    }
    element.addEventListener('shown.bs.modal', finish)
    element.addEventListener('hidden.bs.modal', finish)
  }

  // Disposes the instance; when the modal was still open, clears the backdrop & body state too.
  teardown (element) {
    const wasShown = element.classList.contains('show')
    Modal.getInstance(element)?.dispose()
    if (!wasShown) return

    document.querySelectorAll('.modal-backdrop').forEach((backdrop) => backdrop.remove())
    document.body.classList.remove('modal-open')
    resetScrollbarAdjustments()
  }
}
