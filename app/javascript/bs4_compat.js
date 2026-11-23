/**
 * = Bootstrap 4 → 5 compatibility shim (temporary) =
 *
 * Copies (never moves) the Bootstrap 4 data-* attributes to their Bootstrap 5 names, so the BS5
 * data API - which reads the attributes at click time - keeps working on markup that hasn't been
 * converted yet. Imported first by application.js; removed together with the CSS counterpart
 * (app/assets/stylesheets/compat/_bs4.scss) once every page group uses native BS5 markup.
 *
 * - data-toggle / data-dismiss / data-parent / data-placement → data-bs-*;
 * - data-target → data-bs-target only next to a data-toggle: a lone data-target is app data
 *   (e.g. `.verify-team-btn`, read by an inline handler through `dataset.target`);
 * - data-title → data-bs-title only on tooltips;
 * - data-toggle="buttons" (BS4 button plugin, gone in BS5) is never copied.
 *
 * The BS4 attributes are left untouched. A single MutationObserver upgrades any element added or
 * changed later (Turbo frames & streams, cable payloads, innerHTML renders).
 * When a BS4 attribute changes, its BS5 copy follows only while it still holds the copied value.
 */
const ATTRS = { toggle: 'bsToggle', dismiss: 'bsDismiss', parent: 'bsParent', placement: 'bsPlacement' }
const OBSERVED = ['data-toggle', 'data-target', 'data-dismiss', 'data-parent', 'data-placement', 'data-title']
const SELECTOR = OBSERVED.map((name) => `[${name}]`).join(',')

// dataset key of a "data-*" attribute name (e.g. 'data-toggle' → 'toggle')
const datasetKey = (attrName) => attrName.slice(5)

// BS5 dataset key to which a BS4 dataset key is copied on this element (null when not copied)
function bs5KeyFor(dataset, key) {
  if (ATTRS[key]) return ATTRS[key]
  if (key === 'target' && dataset.toggle) return 'bsTarget'
  if (key === 'title' && dataset.toggle === 'tooltip') return 'bsTitle'
  return null
}

function upgrade(element) {
  const data = element.dataset
  for (const key of Object.keys(ATTRS).concat(['target', 'title'])) {
    const bs5Key = bs5KeyFor(data, key)
    if (bs5Key && data[key] && data[key] !== 'buttons' && !data[bs5Key]) data[bs5Key] = data[key]
  }
}

function upgradeTree(node) {
  if (node.nodeType !== Node.ELEMENT_NODE) return
  if (node.matches(SELECTOR)) upgrade(node)
  node.querySelectorAll(SELECTOR).forEach(upgrade)
}

// Refreshes the BS5 copy of a changed BS4 attribute when the copy still holds the old value
function syncChanged(element, attrName, oldValue) {
  const key = datasetKey(attrName)
  const bs5Key = bs5KeyFor(element.dataset, key)
  if (bs5Key && oldValue !== null && element.dataset[bs5Key] === oldValue) {
    const value = element.dataset[key]
    if (value === undefined || value === 'buttons') delete element.dataset[bs5Key]
    else element.dataset[bs5Key] = value
  }
  upgrade(element)
}

const observer = new MutationObserver((mutations) => {
  for (const mutation of mutations) {
    if (mutation.type === 'attributes') syncChanged(mutation.target, mutation.attributeName, mutation.oldValue)
    else mutation.addedNodes.forEach(upgradeTree)
  }
})

upgradeTree(document.documentElement)
observer.observe(document.documentElement, {
  childList: true, subtree: true, attributes: true, attributeOldValue: true, attributeFilter: OBSERVED
})
