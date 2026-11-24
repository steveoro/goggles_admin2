import { Controller } from '@hotwired/stimulus'
import { Modal } from 'bootstrap'

const MAX_PAGES = 8 // (navigation entries listed while typing; all of them for an empty query)
const SEARCH_DELAY = 200 // (ms of typing pause before the local search request)
// Focus targets where Ctrl/Cmd+K belongs to the field (TomSelect and CodeMirror included):
const EDITABLE = 'input, textarea, [contenteditable]:not([contenteditable="false"]), .ts-wrapper, .ts-dropdown, .cm-editor'

// Lower case, accents removed (so "citta" matches "Città").
function normalize (text) {
  return (text || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase()
}

function insideEditable (node) {
  return node instanceof Element && (node.isContentEditable || node.closest(EDITABLE) !== null)
}

/**
 * = palette - StimulusJS controller (phase 15) =
 *
 * The command palette (Shell::PaletteComponent, a Bootstrap modal without fade):
 * - Ctrl+K / Cmd+K (window) opens it, or closes it when open; ignored while the focus is in an input, a textarea,
 *   a contenteditable, TomSelect or CodeMirror, or while another dialog is open; the top bar trigger opens it too;
 * - typing matches the navigation entries (the Shell::Navigation items, embedded JSON) in the browser and, from
 *   `minChars` characters, asks the local search (`searchUrl`: meetings, teams, swimmers, Data-Fix sessions, at most 20);
 * - ↑/↓ move the selection, Enter opens it (Turbo visit), Esc closes (Bootstrap); a click opens a result
 *   (a modifier click keeps the browser's own behaviour, e.g. a new tab).
 *
 * == Targets ==
 * - input: the combobox; list: the listbox of results; empty: the "nothing matches" line; status: the live status line
 *
 * == Values ==
 * - entries: Array of { key, group, group_label, icon, label, context, path, keywords };
 * - searchUrl: the local search endpoint (blank: no search, e.g. API-offline session); minChars: shortest query
 *
 * == Actions ==
 * - hotkey (keydown@window), filter (input), navigate (keydown on the input), pick (click on the list)
 */
export default class extends Controller {
  static targets = ['input', 'list', 'empty', 'status']
  static values = { entries: Array, searchUrl: String, minChars: { type: Number, default: 2 } }

  connect () {
    this.modal = Modal.getOrCreateInstance(this.element)
    this.items = []
    this.selected = -1
    this.serial = 0
    this.timer = null
    this.onShow = () => this.reset()
    this.onShown = () => this.inputTarget.focus()
    this.onHidden = () => this.cancelSearch()
    this.onBeforeCache = () => this.modal.hide()
    this.element.addEventListener('show.bs.modal', this.onShow)
    this.element.addEventListener('shown.bs.modal', this.onShown)
    this.element.addEventListener('hidden.bs.modal', this.onHidden)
    document.addEventListener('turbo:before-cache', this.onBeforeCache)
  }

  disconnect () {
    this.cancelSearch()
    this.element.removeEventListener('show.bs.modal', this.onShow)
    this.element.removeEventListener('shown.bs.modal', this.onShown)
    this.element.removeEventListener('hidden.bs.modal', this.onHidden)
    document.removeEventListener('turbo:before-cache', this.onBeforeCache)
    this.modal.hide()
    this.modal.dispose()
  }

  // (keydown@window) Ctrl/Cmd+K
  hotkey (event) {
    if (event.key?.toLowerCase() !== 'k' || !(event.ctrlKey || event.metaKey) || event.altKey || event.shiftKey) return

    if (this.isOpen()) {
      event.preventDefault()
      this.modal.hide()
      return
    }
    if (insideEditable(event.target) || this.otherDialogOpen()) return

    event.preventDefault()
    this.modal.show()
  }

  // (input) local matches at once, the search after a pause
  filter () {
    const query = this.inputTarget.value.trim()
    this.cancelSearch()
    this.render(this.matchingPages(query), [])
    if (this.searchUrlValue && query.length >= this.minCharsValue) {
      this.timer = setTimeout(() => this.search(query), SEARCH_DELAY)
    }
  }

  // (keydown on the input) ↑ ↓ Enter
  navigate (event) {
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
      event.preventDefault()
      this.select(this.selected + (event.key === 'ArrowDown' ? 1 : -1))
    } else if (event.key === 'Enter' && !event.isComposing) {
      event.preventDefault()
      const item = this.items[this.selected]
      if (item) this.go(item.path)
    }
  }

  // (click on the list) opens the clicked result
  pick (event) {
    const link = event.target.closest('a[data-palette-index]')
    if (!link || event.ctrlKey || event.metaKey || event.shiftKey || event.button !== 0) return

    event.preventDefault()
    this.go(link.getAttribute('href'))
  }

  // -- internals --

  isOpen () {
    return this.element.classList.contains('show')
  }

  otherDialogOpen () {
    return Array.from(document.querySelectorAll('.modal.show, .offcanvas.show')).some((node) => node !== this.element)
  }

  reset () {
    this.inputTarget.value = ''
    this.cancelSearch()
    this.render(this.matchingPages(''), [])
  }

  go (path) {
    this.modal.hide()
    if (window.Turbo) {
      window.Turbo.visit(path)
    } else {
      window.location.assign(path)
    }
  }

  // Navigation entries matching every word of the query (label first, then group, context and keywords)
  matchingPages (query) {
    const entries = this.entriesValue.map((entry) => ({
      kind: 'page', label: entry.label, detail: entry.context, kind_label: entry.group_label, icon: entry.icon, path: entry.path
    }))
    const words = normalize(query).split(/\s+/).filter(Boolean)
    if (words.length === 0) return entries

    const scored = []
    this.entriesValue.forEach((entry, index) => {
      const label = normalize(entry.label)
      const haystack = normalize([entry.label, entry.group_label, entry.context, ...(entry.keywords || [])].join(' '))
      if (!words.every((word) => haystack.includes(word))) return

      let score = 3
      if (label.startsWith(words[0])) score = 0
      else if (label.split(/\s+/).some((part) => part.startsWith(words[0]))) score = 1
      else if (label.includes(words[0])) score = 2
      scored.push({ score, index })
    })
    return scored.sort((a, b) => a.score - b.score || a.index - b.index).slice(0, MAX_PAGES).map(({ index }) => entries[index])
  }

  search (query) {
    const serial = ++this.serial
    this.setStatus(this.statusTarget.dataset.searching)
    this.abort = new AbortController()
    const url = `${this.searchUrlValue}?q=${encodeURIComponent(query)}`
    fetch(url, { headers: { Accept: 'application/json' }, signal: this.abort.signal })
      .then((response) => (response.ok ? response.json() : { results: [] }))
      .then((json) => {
        if (serial !== this.serial) return

        this.setStatus('')
        this.render(this.matchingPages(query), json.results || [], true)
      })
      .catch(() => { if (serial === this.serial) this.setStatus('') })
  }

  cancelSearch () {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    if (this.abort) this.abort.abort()
    this.abort = null
    this.serial++
    this.setStatus('')
  }

  setStatus (text) {
    if (this.hasStatusTarget && this.searchUrlValue) this.statusTarget.textContent = text || ''
  }

  // Lists the pages then the search results; keeps the selection on a page when the results arrive later
  render (pages, results, keepSelection = false) {
    const previous = keepSelection ? this.items[this.selected] : null
    this.items = pages.concat(results)
    this.listTarget.replaceChildren(...this.items.map((item, index) => this.option(item, index)))
    this.emptyTarget.classList.toggle('d-none', this.items.length > 0 || this.inputTarget.value.trim() === '')
    const kept = previous ? this.items.findIndex((item) => item.kind === previous.kind && item.path === previous.path) : -1
    this.select(kept >= 0 ? kept : 0)
  }

  option (item, index) {
    const link = document.createElement('a')
    link.className = 'list-group-item list-group-item-action d-flex align-items-center gap-2 app-palette-option'
    link.id = `${this.element.id}-option-${index}`
    link.href = item.path
    link.setAttribute('role', 'option')
    link.setAttribute('aria-selected', 'false')
    link.dataset.paletteIndex = index
    link.dataset.paletteKind = item.kind

    const icon = document.createElement('i')
    icon.className = `fa-solid ${item.icon || 'fa-arrow-right'} fa-fw text-body-secondary`
    icon.setAttribute('aria-hidden', 'true')

    const text = document.createElement('span')
    text.className = 'flex-grow-1 text-truncate'
    text.textContent = item.label
    if (item.detail) {
      const detail = document.createElement('small')
      detail.className = 'text-body-secondary ms-2'
      detail.textContent = item.detail
      text.append(detail)
    }

    const kind = document.createElement('small')
    kind.className = 'text-body-secondary text-nowrap'
    kind.textContent = item.kind_label || ''

    link.append(icon, text, kind)
    return link
  }

  select (index) {
    const options = this.listTarget.querySelectorAll('[role="option"]')
    if (options.length === 0) {
      this.selected = -1
      this.inputTarget.removeAttribute('aria-activedescendant')
      return
    }
    this.selected = (index + options.length) % options.length
    options.forEach((option, position) => {
      const active = position === this.selected
      option.classList.toggle('active', active)
      option.setAttribute('aria-selected', active ? 'true' : 'false')
    })
    const current = options[this.selected]
    this.inputTarget.setAttribute('aria-activedescendant', current.id)
    current.scrollIntoView({ block: 'nearest' })
  }
}
