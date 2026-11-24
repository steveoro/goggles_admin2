import { Controller } from '@hotwired/stimulus'

// Bootstrap 4 data-* attributes and their Bootstrap 5 names (dataset keys)
const ATTRS = { toggle: 'bsToggle', target: 'bsTarget', dismiss: 'bsDismiss', parent: 'bsParent', placement: 'bsPlacement' }
const OBSERVED = Object.keys(ATTRS).map((key) => `data-${key}`)
const SELECTOR = OBSERVED.map((name) => `[${name}]`).join(',')

/**
 * = goggles-db-partial - StimulusJS controller =
 *
 * Bound to the `.goggles-db-partial` wrapper around the goggles_db engine GoggleCup partials
 * (goggles_cup/_ranking.html.haml, goggles_cup/base_timings.html.haml), which are shared with goggles_main and
 * keep their Bootstrap 4 data attributes (e.g. the `data-toggle="collapse"` of the "base timings" link).
 *
 * Copies (never moves) `data-toggle`, `data-target`, `data-dismiss`, `data-parent` and `data-placement` to their
 * Bootstrap 5 `data-bs-*` names on the elements inside the wrapper, so that the Bootstrap 5 data API handles them.
 * A MutationObserver limited to the wrapper upgrades the elements added or changed later. Nothing outside the
 * wrapper is touched: the rest of the app uses native Bootstrap 5 markup.
 * The CSS counterpart is app/assets/stylesheets/compat/_goggles_db_partials.scss.
 *
 * == Targets / Values / Actions ==
 * (none: setup only)
 */
export default class extends Controller {
  connect () {
    this.upgradeTree(this.element)
    this.observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.type === 'attributes') this.upgrade(mutation.target)
        else mutation.addedNodes.forEach((node) => this.upgradeTree(node))
      }
    })
    this.observer.observe(this.element, { childList: true, subtree: true, attributes: true, attributeFilter: OBSERVED })
  }

  disconnect () {
    this.observer?.disconnect()
    this.observer = null
  }

  // Upgrades +node+ and its descendants
  upgradeTree (node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return
    if (node.matches(SELECTOR)) this.upgrade(node)
    node.querySelectorAll(SELECTOR).forEach((element) => this.upgrade(element))
  }

  // Sets the missing BS5 copies of the BS4 attributes of +element+ (a lone data-target is app data: left alone)
  upgrade (element) {
    const data = element.dataset
    for (const [key, bs5Key] of Object.entries(ATTRS)) {
      if (key === 'target' && !data.toggle) continue
      if (data[key] && !data[bs5Key]) data[bs5Key] = data[key]
    }
  }
}
