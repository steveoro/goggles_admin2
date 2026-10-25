import { Controller } from '@hotwired/stimulus'

/**
 * = calendar-selection - StimulusJS controller =
 *
 * Wrapper for JS methods used for meeting-row selection on the calendar
 * meetings page (PullController#calendar_meetings).
 *
 * == Targets ==
 * @param {String} 'data-calendar-selection-target': 'selector'
 *                 A row checkbox (one per selectable meeting row). Carries
 *                 'data-has-url' and 'data-manifest-state' attributes.
 *
 * @param {String} 'data-calendar-selection-target': 'counter'
 *                 Badge showing the number of currently selected rows.
 *
 * @param {String} 'data-calendar-selection-target': 'submit'
 *                 The form submit button (enabled only when selection > 0).
 *
 * @param {String} 'data-calendar-selection-target': 'row'
 *                 A table row (carries 'data-manifest-state' for filtering).
 *
 * == Actions ==
 * - toggleAll            => toggles every enabled checkbox (all/none)
 * - selectWithUrl        => selects only rows having a meeting URL
 * - selectNewManifests   => selects only crawlable rows w/o an extracted manifest
 * - onChange             => refreshes counter & submit state on checkbox change
 * - toggleDoneVisibility => shows/hides rows w/ an already-extracted manifest
 */
export default class extends Controller {
  static targets = ['selector', 'counter', 'submit', 'row']

  connect() {
    this.onChange()
  }

  /** Toggles all enabled checkboxes on/off ("all/none" button). */
  toggleAll() {
    const enabled = this.selectorTargets.filter(cb => !cb.disabled)
    const shouldCheck = enabled.some(cb => !cb.checked)
    enabled.forEach(cb => { cb.checked = shouldCheck })
    this.onChange()
  }

  /** Selects only the rows having a meeting URL. */
  selectWithUrl() {
    this.selectorTargets.forEach(cb => {
      cb.checked = !cb.disabled && cb.dataset.hasUrl === 'true'
    })
    this.onChange()
  }

  /** Selects only crawlable rows with no manifest on disk. */
  selectNewManifests() {
    this.selectorTargets.forEach(cb => {
      cb.checked = !cb.disabled && cb.dataset.manifestState === 'none'
    })
    this.onChange()
  }

  /** Refreshes the selection counter and the submit button state. */
  onChange() {
    const count = this.selectorTargets.filter(cb => cb.checked && !cb.disabled).length
    if (this.hasCounterTarget) {
      this.counterTarget.textContent = count
    }
    if (this.hasSubmitTarget) {
      this.submitTarget.disabled = (count === 0)
    }
  }

  /** Toggles visibility of rows whose manifest was already extracted. */
  toggleDoneVisibility(event) {
    const hide = event.target.checked
    this.rowTargets.forEach(row => {
      if (row.dataset.manifestState === 'done') {
        row.classList.toggle('d-none', hide)
      }
    })
  }
}
