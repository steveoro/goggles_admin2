import { Controller } from '@hotwired/stimulus'
import { Tooltip } from 'bootstrap'

const SELECTOR = '[data-bs-toggle="tooltip"]'
const AUTO_HIDE_DELAY = 4000 // (ms)

/**
 * = tooltips - StimulusJS controller =
 *
 * Bound to the layout's <body>: a single delegated Bootstrap 5 Tooltip handles every
 * `[data-bs-toggle="tooltip"]` element, including content inserted later (Turbo frames & streams,
 * cable payloads, modals), with no re-initialization needed.
 * (BS4 `data-toggle="tooltip"` markup gets its BS5 attributes from bs4_compat.js.)
 *
 * - Each tooltip hides itself 4 seconds after being shown.
 * - Before a Turbo cache snapshot or a frame render, the per-element tooltip instances are disposed
 *   (restoring their `title`) and any tooltip left on screen is removed.
 *
 * == Targets / Values / Actions ==
 * (none: setup only)
 */
export default class extends Controller {
  connect () {
    this.tooltip = new Tooltip(this.element, { selector: SELECTOR })
    this.hideTimers = new WeakMap()
    this.onShown = this.onShown.bind(this)
    this.onBeforeCache = this.onBeforeCache.bind(this)
    this.onBeforeFrameRender = this.onBeforeFrameRender.bind(this)
    this.element.addEventListener('shown.bs.tooltip', this.onShown)
    document.addEventListener('turbo:before-cache', this.onBeforeCache)
    document.addEventListener('turbo:before-frame-render', this.onBeforeFrameRender)
  }

  disconnect () {
    this.element.removeEventListener('shown.bs.tooltip', this.onShown)
    document.removeEventListener('turbo:before-cache', this.onBeforeCache)
    document.removeEventListener('turbo:before-frame-render', this.onBeforeFrameRender)
    this.cleanup(this.element)
    this.tooltip?.dispose()
    this.tooltip = null
  }

  // Auto-hides the tooltip just shown (BS5 tooltip events bubble up to the body).
  onShown (event) {
    const trigger = event.target
    clearTimeout(this.hideTimers.get(trigger))
    this.hideTimers.set(trigger, setTimeout(() => Tooltip.getInstance(trigger)?.hide(), AUTO_HIDE_DELAY))
  }

  onBeforeCache () {
    this.cleanup(this.element)
  }

  onBeforeFrameRender (event) {
    this.cleanup(event.target)
  }

  // Disposes the tooltip instances found inside scope and removes any tooltip node still on screen.
  cleanup (scope) {
    scope.querySelectorAll(SELECTOR).forEach((element) => Tooltip.getInstance(element)?.dispose())
    document.querySelectorAll('.tooltip').forEach((node) => node.remove())
  }
}
