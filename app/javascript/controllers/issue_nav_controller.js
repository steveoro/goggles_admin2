import { Controller } from '@hotwired/stimulus'
import { Collapse } from 'bootstrap'

const TYPING_TAGS = ['INPUT', 'TEXTAREA', 'SELECT']
const CURRENT_CLASS = 'issue-nav-current'

/**
 * = issue-nav - StimulusJS controller =
 *
 * Next / previous issue navigation of the Data-Fix review pages (DataFix::IssueNavComponent).
 *
 * The cards needing the operator carry a `data-issue="<code>"` marker (DataFix::IssueMarkers) and a DOM id.
 * Next / Previous (buttons, or the `j` / `k` keys, ignored while typing in a field, with a modifier key or with a
 * modal open) scroll to the following / preceding marker, expand its collapsed panel and focus it. Past the last
 * (first) marker of the page they follow `nextUrl` (`prevUrl`): another page of the step, with the anchor of its
 * first (last) issue card, or `#issue-first` / `#issue-last`. On connect, such an anchor focuses its card.
 *
 * The markers are read again on every move: a card saved in place (Turbo stream) drops its marker.
 *
 * == Values ==
 * - selector: CSS selector of the markers (default '[data-issue]');
 * - total: issues of the whole step (all pages); offset: issues on the pages before this one;
 * - prevUrl / nextUrl: where the previous / next issue outside this page is ('' when none);
 * - positionLabel / totalLabel / noneLabel: i18n texts (templates with '__CURRENT__', '__TOTAL__').
 *
 * == Targets ==
 * - position: "issue x / total" text; previous / next: the buttons (disabled when there is nowhere to go).
 */
export default class extends Controller {
  static targets = ['position', 'previous', 'next']

  static values = {
    selector: { type: String, default: '[data-issue]' },
    total: { type: Number, default: 0 },
    offset: { type: Number, default: 0 },
    prevUrl: { type: String, default: '' },
    nextUrl: { type: String, default: '' },
    positionLabel: { type: String, default: '__CURRENT__ / __TOTAL__' },
    totalLabel: { type: String, default: '__TOTAL__' },
    noneLabel: { type: String, default: '-' }
  }

  connect () {
    this.initialCount = this.markers().length
    this.currentId = null
    this.refresh()
    this.focusFromHash()
  }

  // --- Actions ---

  next (event) {
    event?.preventDefault()
    const markers = this.markers()
    const current = this.currentElement()
    const following = current
      ? markers.find((marker) => marker !== current && this.follows(current, marker))
      : markers.find((marker) => marker.getBoundingClientRect().top > 1)
    if (following) {
      this.focus(following)
    } else if (this.nextUrlValue) {
      this.visit(this.nextUrlValue)
    }
  }

  previous (event) {
    event?.preventDefault()
    const markers = this.markers()
    const current = this.currentElement()
    const preceding = current
      ? [...markers].reverse().find((marker) => marker !== current && this.follows(marker, current))
      : [...markers].reverse().find((marker) => marker.getBoundingClientRect().top < -1)
    if (preceding) {
      this.focus(preceding)
    } else if (this.prevUrlValue) {
      this.visit(this.prevUrlValue)
    }
  }

  // keydown@window: j = next, k = previous
  keydown (event) {
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey) return
    if (this.typing(event.target) || document.body.classList.contains('modal-open')) return

    if (event.key === 'j') {
      event.preventDefault()
      this.next()
    } else if (event.key === 'k') {
      event.preventDefault()
      this.previous()
    }
  }

  // --- Internals ---

  markers () {
    return Array.from(document.querySelectorAll(this.selectorValue)).filter((element) => element.id)
  }

  currentElement () {
    return this.currentId ? document.getElementById(this.currentId) : null
  }

  // True when +later+ comes after +earlier+ in document order.
  follows (earlier, later) {
    return Boolean(earlier.compareDocumentPosition(later) & Node.DOCUMENT_POSITION_FOLLOWING)
  }

  focus (element) {
    document.querySelectorAll(`.${CURRENT_CLASS}`).forEach((other) => other.classList.remove(CURRENT_CLASS))
    this.currentId = element.id
    element.classList.add(CURRENT_CLASS)
    this.expand(element)
    if (!element.hasAttribute('tabindex')) element.setAttribute('tabindex', '-1')
    element.focus({ preventScroll: true })
    element.scrollIntoView({ block: 'start', behavior: 'auto' })
    if (window.history?.replaceState) window.history.replaceState(window.history.state, '', `#${element.id}`)
    this.refresh()
  }

  // Shows the collapsed panel of a card (Bootstrap 5 Collapse API, so that its toggle stays in sync).
  expand (element) {
    const panel = element.querySelector('[data-issue-panel]') || element.querySelector('.collapse')
    if (panel && !panel.classList.contains('show')) Collapse.getOrCreateInstance(panel, { toggle: false }).show()
  }

  focusFromHash () {
    const hash = decodeURIComponent(window.location.hash.replace(/^#/, ''))
    if (!hash) return

    const markers = this.markers()
    let target = null
    if (hash === 'issue-first') {
      target = markers[0]
    } else if (hash === 'issue-last') {
      target = markers[markers.length - 1]
    } else {
      target = document.getElementById(hash)
    }
    // (on the next frame: Turbo restores the scroll position after the controllers connect)
    if (target && target.matches(this.selectorValue)) window.requestAnimationFrame(() => this.focus(target))
  }

  visit (url) {
    if (window.Turbo) {
      window.Turbo.visit(url)
    } else {
      window.location.assign(url)
    }
  }

  typing (target) {
    if (!target || !target.tagName) return false
    return TYPING_TAGS.includes(target.tagName) || target.isContentEditable
  }

  refresh () {
    const markers = this.markers()
    const total = Math.max(this.totalValue - (this.initialCount - markers.length), markers.length)
    const current = this.currentElement()
    const index = current ? markers.indexOf(current) : -1
    if (this.hasPositionTarget) {
      if (index >= 0) {
        this.positionTarget.textContent = this.positionLabelValue.replace('__CURRENT__', this.offsetValue + index + 1).replace('__TOTAL__', total)
      } else {
        this.positionTarget.textContent = total > 0 ? this.totalLabelValue.replace('__TOTAL__', total) : this.noneLabelValue
      }
    }
    const nowhere = markers.length === 0
    if (this.hasPreviousTarget) this.previousTarget.disabled = nowhere && !this.prevUrlValue
    if (this.hasNextTarget) this.nextTarget.disabled = nowhere && !this.nextUrlValue
  }
}
