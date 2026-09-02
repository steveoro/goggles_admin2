import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['candidate', 'merge', 'selectedCount', 'mergeCount', 'toolbar']

  static values = {
    updateUrl: String,
    mergeUrl: String,
    bulkUrl: String,
    filePath: String,
    confirmation: String,
    selectedLabel: String,
    mergedLabel: String,
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
      checkbox,
      isMerge: false
    })
  }

  async toggleMerge (event) {
    event.preventDefault()
    const checkbox = event.currentTarget
    await this.requestSelection({
      url: this.mergeUrlValue,
      body: {
        file_path: this.filePathValue,
        candidate_id: checkbox.dataset.candidateId,
        merge: checkbox.checked ? '1' : '0'
      },
      checkbox,
      isMerge: true
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

  async requestSelection ({ url, body, checkbox, operation, isMerge = false }) {
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

      if (checkbox && isMerge) this.updateMergeRow(checkbox, data.merge)
      if (checkbox && !isMerge) this.updateCandidateRow(checkbox, data.selected, data.merge, true)
      if (operation) this.updateBulkRows(operation)
      this.updateCount(data.selected_count, data.total_count, data.merge_count)
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
      pending.forEach(([checkbox, selected]) => this.updateCandidateRow(checkbox, selected, null, true))
    })
  }

  updateCandidateRow (checkbox, selected, merge = null, force = false) {
    if (!force && checkbox.checked === selected) return

    checkbox.checked = selected
    const { row, status, merge: mergeCheckbox, mergeTarget } = this.rowStateFor(checkbox)
    if (!row) return

    // Default merge to ON for newly selected rows that have an available target.
    const isMerge = merge === true || (selected && merge === null && mergeCheckbox && !mergeCheckbox.disabled)

    if (mergeCheckbox) {
      mergeCheckbox.disabled = !selected
      mergeCheckbox.checked = isMerge
    }

    row.classList.toggle('bg-info', selected && isMerge)
    row.classList.toggle('text-white', selected)
    row.classList.toggle('bg-danger', selected && !isMerge)
    row.classList.toggle('bg-light', !selected)
    row.classList.toggle('text-muted', !selected)

    if (mergeTarget) {
      mergeTarget.style.display = (selected && isMerge) ? '' : 'none'
    }

    if (status) {
      if (selected && isMerge) {
        status.textContent = this.mergedLabelValue
        status.className = 'badge badge-light text-info'
      } else if (selected) {
        status.textContent = this.selectedLabelValue
        status.className = 'badge badge-light text-danger'
      } else {
        status.textContent = this.ignoredLabelValue
        status.className = 'badge badge-secondary'
      }
    }
  }

  updateMergeRow (checkbox, merge) {
    checkbox.checked = merge
    const { row, status, merge: mergeCheckbox } = this.rowStateFor(checkbox)
    if (!row) return

    // merge is only valid when selected; the selected row toggles between delete and merge
    row.classList.toggle('bg-info', merge)
    row.classList.toggle('bg-danger', !merge)
    row.classList.toggle('text-white', true)

    if (mergeCheckbox) mergeCheckbox.checked = merge

    if (status) {
      if (merge) {
        status.textContent = this.mergedLabelValue
        status.className = 'badge badge-light text-info'
      } else {
        status.textContent = this.selectedLabelValue
        status.className = 'badge badge-light text-danger'
      }
    }
  }

  // Memoizes the row/status/merge nodes and the zero-timing flag for a candidate checkbox
  rowStateFor (checkbox) {
    let state = this.rowCache.get(checkbox)
    if (state) return state

    const row = checkbox.closest('tr')
    state = {
      row,
      status: row?.querySelector('[data-data-fix-overwrite-status]') || null,
      merge: row?.querySelector('input[data-data-fix-overwrite-target="merge"]') || null,
      mergeTarget: row?.querySelector('[data-data-fix-overwrite-target="mergeTarget"]') || null,
      zeroTiming: ['minutes', 'seconds', 'hundredths'].every((field) => Number(checkbox.dataset[field] || 0) === 0)
    }
    this.rowCache.set(checkbox, state)
    return state
  }

  updateCount (selectedCount, totalCount, mergeCount = null) {
    this.selectedCountTargets.forEach((target) => { target.textContent = selectedCount })
    this.totalCountNodes.forEach((target) => { target.textContent = totalCount })
    if (mergeCount !== null) {
      this.mergeCountTargets.forEach((target) => {
        target.textContent = mergeCount
        target.style.display = mergeCount > 0 ? '' : 'none'
      })
    }
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
