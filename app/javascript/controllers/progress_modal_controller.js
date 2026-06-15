import { Controller } from '@hotwired/stimulus'

/**
 * = progress-modal - StimulusJS controller =
 *
 * Controls the progress modal display for long-running backend operations.
 *
 * Used by ImportStatusChannel to show real-time progress updates during
 * data import/commit operations.
 *
 * == Targets ==
 * @param {Element} 'data-progress-modal-target="modal"': Modal container element
 * @param {Element} 'data-progress-modal-target="message"': Message text element
 * @param {Element} 'data-progress-modal-target="progress"': Progress bar element
 *
 * == Actions ==
 * - <tt>show</tt>: Display the modal
 * - <tt>hide</tt>: Hide the modal
 * - <tt>updateProgress</tt>: Update progress bar percentage
 * - <tt>updateMessage</tt>: Update status message
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['modal', 'message', 'progress']

  /**
   * Display the modal
   */
  show() {
    if (this.hasModalTarget) {
      this.modalTarget.classList.add('show')
      this.modalTarget.style.display = 'block'
      document.body.classList.add('modal-open')
    }
  }

  /**
   * Hide the modal
   */
  hide() {
    if (this.hasModalTarget) {
      this.modalTarget.classList.remove('show')
      this.modalTarget.style.display = 'none'
      document.body.classList.remove('modal-open')
    }
  }

  /**
   * Update progress bar percentage
   * @param {Event} event - Custom event with detail.value and detail.total
   */
  updateProgress(event) {
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
  updateMessage(event) {
    if (this.hasMessageTarget) {
      this.messageTarget.textContent = event.detail.msg
    }
  }
}
