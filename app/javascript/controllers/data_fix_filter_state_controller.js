import { Controller } from '@hotwired/stimulus'

/**
 * Stimulus controller for TurboFilterStateComponent.
 * Handles auto-submit GET requests for filter state changes, per-page changes,
 * and debounced search query input. Preserves q input exactly as typed (no trimming).
 * Deselects "none" radio when q is present to allow explicit clearing.
 */
export default class extends Controller {
  static targets = ['form', 'q', 'perPage', 'state']

  static values = {
    qMinLength: { type: Number, default: 3 },
    debounceMs: { type: Number, default: 300 }
  }

  connect () {
    this._debounceTimer = null
  }

  disconnect () {
    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer)
      this._debounceTimer = null
    }
  }

  handleStateChange () {
    // Clear q only when explicitly clicking "none"
    if (this.currentFilterState() === 'none' && this.hasQTarget) {
      this.qTarget.value = ''
    }

    this.submitForm()
  }

  handlePerPageChange () {
    this.submitForm()
  }

  handleQInput () {
    // Deselect "none" radio when q is present (even if < minLength)
    if (this.hasQTarget && this.qTarget.value.length > 0) {
      const noneRadio = this.stateTargets.find((node) => node.value === 'none')
      if (noneRadio) {
        noneRadio.checked = false
      }
    }

    if (this._debounceTimer) {
      clearTimeout(this._debounceTimer)
    }

    this._debounceTimer = setTimeout(() => {
      this.submitForm()
    }, this.debounceMsValue)
  }

  submitForm () {
    if (!this.hasFormTarget) {
      return
    }

    this.normalizeQField()
    this.formTarget.requestSubmit()
  }

  normalizeQField () {
    if (!this.hasQTarget) {
      return
    }

    // Preserve q exactly as typed (no trimming)
    // Server-side handles minLength filtering
  }

  currentFilterState () {
    const checked = this.stateTargets.find((node) => node.checked)
    return checked ? checked.value : 'none'
  }
}
