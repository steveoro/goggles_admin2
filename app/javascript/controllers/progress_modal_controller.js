import { Controller } from '@hotwired/stimulus'
import { Modal } from 'bootstrap'

const HIDE_DELAY = 2000 // (ms) after reaching the total

/**
 * = progress-modal - StimulusJS controller =
 *
 * Controls the progress modal display for long-running backend operations
 * (shared partial: app/views/goggles/_modal_progress.html.haml).
 *
 * Fed by ImportStatusChannel, which dispatches an `import-status` CustomEvent on the document
 * for each (de-duplicated) progress message: bind it with
 * `data-action="import-status@document->progress-modal#update"`.
 *
 * == Targets ==
 * @param {Element} 'data-progress-modal-target="modal"': Modal container element
 * @param {Element} 'data-progress-modal-target="message"': Message text element
 * @param {Element} 'data-progress-modal-target="progress"': Progress bar element
 *
 * == Actions ==
 * - <tt>update</tt>: sets message & progress from event.detail ({ msg, value, total }), shows the modal
 *   and hides it 2 seconds after the value reaches the total
 * - <tt>show</tt>: Display the modal
 * - <tt>hide</tt>: Hide the modal
 * - <tt>updateProgress</tt>: Update progress bar percentage (event.detail.value & .total)
 * - <tt>updateMessage</tt>: Update status message (event.detail.msg)
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['modal', 'message', 'progress']

  connect () {
    this.transitioning = false
    this.onTransitionStart = () => { this.transitioning = true }
    this.onTransitionEnd = () => { this.transitioning = false }
    this.transitionEvents('addEventListener')
  }

  // Disposes the modal instance; while a show/hide transition is running, Bootstrap's pending
  // callbacks still need it (they also run on detached nodes): dispose once it ends.
  disconnect () {
    clearTimeout(this.hideTimer)
    this.transitionEvents('removeEventListener')
    const element = this.hasModalTarget ? this.modalTarget : null
    const modal = element && Modal.getInstance(element)
    if (!modal) return
    if (!this.transitioning) {
      modal.dispose()
      return
    }
    const finish = () => {
      element.removeEventListener('shown.bs.modal', finish)
      element.removeEventListener('hidden.bs.modal', finish)
      modal.dispose()
    }
    element.addEventListener('shown.bs.modal', finish)
    element.addEventListener('hidden.bs.modal', finish)
  }

  /**
   * Handles an `import-status` event: updates message & progress, shows the modal and
   * schedules its hiding once the value reaches the total.
   * @param {CustomEvent} event - with detail: { msg, value, total }
   */
  update (event) {
    const { msg, value, total } = event.detail
    clearTimeout(this.hideTimer)
    this.updateMessage({ detail: { msg: `${msg}: ${value}/${total}` } })
    this.updateProgress(event)
    this.show()
    if (parseInt(value) >= parseInt(total)) {
      this.hideTimer = setTimeout(() => this.hide(), HIDE_DELAY)
    }
  }

  /**
   * Display the modal
   */
  show () {
    if (this.hasModalTarget) this.modal().show()
  }

  /**
   * Hide the modal
   */
  hide () {
    if (this.hasModalTarget) this.modal().hide()
  }

  /**
   * Update progress bar percentage
   * @param {Event} event - Custom event with detail.value and detail.total
   */
  updateProgress (event) {
    if (this.hasProgressTarget) {
      const { value, total } = event.detail
      const percent = total > 0 ? ((value / total) * 100).toFixed(1) : 0
      this.progressTarget.setAttribute('aria-valuenow', percent)
      this.progressTarget.style.width = `${percent}%`
      this.progressTarget.textContent = `${percent}%`
    }
  }

  /**
   * Update status message
   * @param {Event} event - Custom event with detail.msg
   */
  updateMessage (event) {
    if (this.hasMessageTarget) {
      this.messageTarget.textContent = event.detail.msg
    }
  }

  // ---------------------------------------------------------------------------

  modal () {
    return Modal.getOrCreateInstance(this.modalTarget, { backdrop: 'static', keyboard: false })
  }

  // Adds or removes (method) the listeners tracking the modal show/hide transitions.
  transitionEvents (method) {
    if (!this.hasModalTarget) return
    this.modalTarget[method]('show.bs.modal', this.onTransitionStart)
    this.modalTarget[method]('hide.bs.modal', this.onTransitionStart)
    this.modalTarget[method]('shown.bs.modal', this.onTransitionEnd)
    this.modalTarget[method]('hidden.bs.modal', this.onTransitionEnd)
  }
}
