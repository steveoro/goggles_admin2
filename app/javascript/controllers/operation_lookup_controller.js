import { Controller } from '@hotwired/stimulus'

/**
 * = Operation lookup controller (phase 13) =
 *
 * The id fields of the maintenance operation forms (operations/new): the id stays the submitted value, and the
 * local lookups (GET /lookup/:domain[/:id], LookupController, localhost DB only) give:
 * - a search box (name, description or id) whose matches fill a native <datalist>; picking one sets the id;
 * - the name of the entity next to the id (also for a comma-separated list of ids, e.g. badge ids).
 *
 * == Targets ==
 * - id: the submitted field (number, or text for a list of ids)
 * - search: the search input (optional: absent for the domains that can't be searched by name)
 * - options: the <datalist> of the search input
 * - label: the text naming the entity (or entities)
 *
 * == Values ==
 * - url: base lookup URL (default '/lookup'); domain: 'swimmers', 'teams', 'meetings', 'seasons', 'badges'
 * - none: text for no match / unknown id
 */
export default class extends Controller {
  static targets = ['id', 'search', 'options', 'label']
  static values = { url: { type: String, default: '/lookup' }, domain: String, none: String }

  connect () {
    this.timer = null
    this.resolve()
  }

  disconnect () {
    if (this.timer) clearTimeout(this.timer)
  }

  // (input on the search box) debounced search; a picked option sets the id
  search () {
    if (!this.hasSearchTarget) return

    const value = this.searchTarget.value.trim()
    const picked = value.match(/^(\d+)\s+—/)
    if (picked) {
      this.idTarget.value = picked[1]
      this.resolve()
      return
    }
    if (this.timer) clearTimeout(this.timer)
    if (value.length < 2) return

    this.timer = setTimeout(() => this.fetchMatches(value), 250)
  }

  // (change on the id field) names the entity (or each entity of a list)
  resolve () {
    if (!this.hasLabelTarget || !this.hasIdTarget) return

    const ids = this.idTarget.value.split(',').map((id) => id.trim()).filter((id) => /^\d+$/.test(id))
    if (ids.length === 0) {
      this.labelTarget.textContent = ''
      return
    }
    Promise.all(ids.slice(0, 10).map((id) => this.fetchRow(id)))
      .then((rows) => {
        this.labelTarget.textContent = rows.map((row, index) => (row ? this.rowLabel(row) : `${ids[index]}: ${this.noneValue}`)).join(' · ')
      })
      .catch(() => { this.labelTarget.textContent = '' })
  }

  fetchMatches (query) {
    fetch(`${this.urlValue}/${this.domainValue}?q=${encodeURIComponent(query)}`, { headers: { Accept: 'application/json' } })
      .then((response) => (response.ok ? response.json() : []))
      .then((rows) => {
        if (!this.hasOptionsTarget) return

        this.optionsTarget.replaceChildren(...rows.map((row) => {
          const option = document.createElement('option')
          option.value = `${row.id} — ${this.rowLabel(row)}`
          return option
        }))
        if (rows.length === 0 && this.hasLabelTarget) this.labelTarget.textContent = this.noneValue
      })
      .catch(() => {})
  }

  fetchRow (id) {
    return fetch(`${this.urlValue}/${this.domainValue}/${id}`, { headers: { Accept: 'application/json' } })
      .then((response) => (response.ok ? response.json() : null))
      .catch(() => null)
  }

  rowLabel (row) {
    return row.label || row.description || [row.name, row.city_name].filter(Boolean).join(', ') || row.complete_name || `#${row.id}`
  }
}
