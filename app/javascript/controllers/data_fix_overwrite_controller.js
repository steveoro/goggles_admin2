import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['candidate', 'selectedCount', 'toolbar']

  static values = {
    updateUrl: String,
    bulkUrl: String,
    filePath: String,
    confirmation: String,
    selectedLabel: String,
    ignoredLabel: String,
    updateFailedMessage: String
  }

  connect () {
    this.csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
    this.busy = false
    // Per-row cache: avoids re-running closest()/querySelector() for every candidate on bulk updates
    this.rowCache = new WeakMap()
    this.bulkButtonNodes = null
    this.totalCountNodeList = null
  }

  disconnect () {
    this.rowCache = new WeakMap()
    this.bulkButtonNodes = null
    this.totalCountNodeList = null
  }

  confirmCommit (event) {
    const selectedCount = this.candidateTargets.filter((checkbox) => checkbox.checked).length
    if (selectedCount === 0) return

    const message = this.confirmationValue.replace('%{count}', selectedCount)
    if (!window.confirm(message)) event.preventDefault()
  }

  async toggle (event) {
    event.preventDefault()
    const checkbox = event.currentTarget
    await this.requestSelection({
      url: this.updateUrlValue,
      body: {
        file_path: this.filePathValue,
        candidate_id: checkbox.dataset.candidateId,
        selected: checkbox.checked ? '1' : '0'
      },
      checkbox
    })
  }

  async bulk (event) {
    event.preventDefault()
    if (this.busy) return

    const button = event.currentTarget
    await this.requestSelection({
      url: this.bulkUrlValue,
      body: { file_path: this.filePathValue, operation: button.dataset.operation },
      operation: button.dataset.operation
    })
  }

  async requestSelection ({ url, body, checkbox, operation }) {
    if (this.busy) return

    this.busy = true
    if (checkbox) checkbox.disabled = true
    this.setBulkButtonsDisabled(true)

    try {
      const formData = new FormData()
      Object.entries(body).forEach(([key, value]) => formData.append(key, value))
      const response = await fetch(url, {
        method: 'POST',
        headers: { Accept: 'application/json', 'X-CSRF-Token': this.csrfToken },
        credentials: 'same-origin',
        body: formData
      })
      const data = await response.json()
      if (!response.ok || !data.success) throw new Error(data.error || 'Selection update failed')

      if (checkbox) this.updateCandidateRow(checkbox, data.selected, true)
      if (operation) this.updateBulkRows(operation)
      this.updateCount(data.selected_count, data.total_count)
    } catch (error) {
      if (checkbox) checkbox.checked = !checkbox.checked
      window.alert(this.updateFailedMessageValue || error.message)
    } finally {
      if (checkbox) checkbox.disabled = false
      this.setBulkButtonsDisabled(false)
      this.busy = false
    }
  }

  // Applies a bulk operation client-side, touching only the rows whose state actually changes
  // and flushing all DOM writes in a single animation frame.
  updateBulkRows (operation) {
    const pending = []
    this.candidateTargets.forEach((checkbox) => {
      const { zeroTiming } = this.rowStateFor(checkbox)
      const selected = operation === 'select_all' || (operation !== 'deselect_all' && !zeroTiming)
      if (checkbox.checked !== selected) pending.push([checkbox, selected])
    })
    if (pending.length === 0) return

    window.requestAnimationFrame(() => {
      pending.forEach(([checkbox, selected]) => this.updateCandidateRow(checkbox, selected, true))
    })
  }

  updateCandidateRow (checkbox, selected, force = false) {
    if (!force && checkbox.checked === selected) return

    checkbox.checked = selected
    const { row, status } = this.rowStateFor(checkbox)
    if (!row) return

    row.classList.toggle('bg-danger', selected)
    row.classList.toggle('text-white', selected)
    row.classList.toggle('bg-light', !selected)
    row.classList.toggle('text-muted', !selected)
    if (status) {
      status.textContent = selected ? this.selectedLabelValue : this.ignoredLabelValue
      status.classList.toggle('badge-light', selected)
      status.classList.toggle('text-danger', selected)
      status.classList.toggle('badge-secondary', !selected)
    }
  }

  // Memoizes the row/status nodes and the zero-timing flag for a candidate checkbox
  rowStateFor (checkbox) {
    let state = this.rowCache.get(checkbox)
    if (state) return state

    const row = checkbox.closest('tr')
    state = {
      row,
      status: row?.querySelector('[data-data-fix-overwrite-status]') || null,
      zeroTiming: ['minutes', 'seconds', 'hundredths'].every((field) => Number(checkbox.dataset[field] || 0) === 0)
    }
    this.rowCache.set(checkbox, state)
    return state
  }

  updateCount (selectedCount, totalCount) {
    this.selectedCountTargets.forEach((target) => { target.textContent = selectedCount })
    this.totalCountNodes.forEach((target) => { target.textContent = totalCount })
  }

  setBulkButtonsDisabled (disabled) {
    this.bulkButtons.forEach((button) => { button.disabled = disabled })
  }

  get bulkButtons () {
    if (!this.bulkButtonNodes) {
      this.bulkButtonNodes = Array.from(this.element.querySelectorAll('button[data-operation]'))
    }
    return this.bulkButtonNodes
  }

  get totalCountNodes () {
    if (!this.totalCountNodeList) {
      this.totalCountNodeList = Array.from(this.element.querySelectorAll('[data-overwrite-total-count]'))
    }
    return this.totalCountNodeList
  }
}
