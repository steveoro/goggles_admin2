import { Controller } from "@hotwired/stimulus"

/**
 * Collapse All Controller
 * Toggles collapse state for multiple Bootstrap collapse elements
 *
 * The `show` class is toggled directly (fast even on hundreds of panels; Bootstrap 5 reads the
 * collapse state from the class), while each panel's triggers (`[data-bs-toggle="collapse"]` with a
 * matching `data-bs-target` or `href`) get their `.collapsed` class & `aria-expanded` synced.
 *
 * Usage:
 *   <div data-controller="collapse-all">
 *     <button data-action="collapse-all#toggle" data-collapse-all-target="button">Toggle</button>
 *     <div id="collapse-1" class="collapse show">...</div>
 *     <div id="collapse-2" class="collapse show">...</div>
 *   </div>
 *
 * Values:
 *   data-collapse-all-selector-value: CSS selector for collapse elements (default: '[id^="result-collapse-"]')
 *   data-collapse-all-expand-label-value: button label when collapsed (default: 'Expand All Results')
 *   data-collapse-all-collapse-label-value: button label when expanded (default: 'Collapse All Results')
 */
export default class extends Controller {
  static targets = ["button"]
  static values = {
    selector: { type: String, default: '[id^="result-collapse-"]' },
    collapsed: { type: Boolean, default: false },
    expandLabel: { type: String, default: 'Expand All Results' },
    collapseLabel: { type: String, default: 'Collapse All Results' }
  }

  connect() {
    this.updateButtonState()
  }

  toggle() {
    this.collapsedValue = !this.collapsedValue
    const expanded = !this.collapsedValue
    const triggersByTarget = this.collapseTriggersByTarget()

    document.querySelectorAll(this.selectorValue).forEach(element => {
      element.classList.toggle('show', expanded)
      const triggers = element.id ? triggersByTarget.get(`#${element.id}`) : null
      if (!triggers) return

      triggers.forEach(trigger => {
        trigger.classList.toggle('collapsed', !expanded)
        trigger.setAttribute('aria-expanded', expanded ? 'true' : 'false')
      })
    })

    this.updateButtonState()
  }

  updateButtonState() {
    if (!this.hasButtonTarget) return
    if (!this.buttonTarget.querySelector('i')) return

    const icon = document.createElement('i')
    icon.className = this.collapsedValue ? 'fa fa-expand' : 'fa fa-compress'
    const label = this.collapsedValue ? this.expandLabelValue : this.collapseLabelValue
    this.buttonTarget.replaceChildren(icon, document.createTextNode(` ${label}`))
  }

  // Maps each '#id' target to its collapse triggers (single DOM pass).
  collapseTriggersByTarget() {
    const map = new Map()
    document.querySelectorAll('[data-bs-toggle="collapse"]').forEach(trigger => {
      const target = trigger.getAttribute('data-bs-target') || trigger.getAttribute('href')
      if (!target || !target.startsWith('#')) return

      if (!map.has(target)) map.set(target, [])
      map.get(target).push(trigger)
    })
    return map
  }
}
