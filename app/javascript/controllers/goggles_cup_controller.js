import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['form', 'noDuplicatedEventsField', 'swimmerCheckbox', 'swimmerPanel', 'rankingContainer', 'computeButton', 'overlay',
                   'cupSelect', 'goggleCupIdField', 'descriptionField', 'seasonYearField', 'endDateField', 'externalSwimmersContainer',
                   'selectionCounter', 'loadExistingButton', 'cupIdDisplay']
  static values = { smartSelectionUrl: String, cupDataUrl: String, loadRankingUrl: String, hasRankingData: Boolean }

  connect() {
    this.csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
    this.secondaryTeamSelect = document.querySelector('#secondary_team_select')
    this.boundSmartSelectWithDelay = this.smartSelectWithDelay.bind(this)
    if (this.secondaryTeamSelect) {
      this.secondaryTeamSelect.addEventListener('change', this.boundSmartSelectWithDelay)
    }
    this.updateSelectionCounter()
    this.toggleLoadExistingButton()
  }

  hasRankingDataValueChanged() {
    this.toggleLoadExistingButton()
  }

  toggleLoadExistingButton() {
    if (!this.hasLoadExistingButtonTarget) {
      return
    }

    this.loadExistingButtonTarget.classList.toggle('d-none', !this.hasRankingDataValue)
  }

  disconnect() {
    if (this.secondaryTeamSelect) {
      this.secondaryTeamSelect.removeEventListener('change', this.boundSmartSelectWithDelay)
    }
  }

  selectAll(event) {
    event.preventDefault()
    this.swimmerCheckboxTargets.forEach((checkbox) => { checkbox.checked = true })
    this.updateSelectionCounter()
  }

  deselectAll(event) {
    event.preventDefault()
    this.swimmerCheckboxTargets.forEach((checkbox) => { checkbox.checked = false })
    this.updateSelectionCounter()
  }

  smartSelectWithDelay() {
    window.setTimeout(() => this.smartSelect(), 150)
  }

  async smartSelect() {
    const teamId = this.fieldValue('team_id')
    const secondaryTeamId = this.fieldValue('secondary_team_id')

    if (!teamId || !secondaryTeamId || secondaryTeamId === '0') {
      return
    }

    const url = new URL(this.smartSelectionUrlValue, window.location.origin)
    url.searchParams.append('team_id', teamId)
    url.searchParams.append('secondary_team_id', secondaryTeamId)

    const response = await fetch(url.toString(), {
      method: 'GET',
      headers: { Accept: 'application/json' }
    })

    if (!response.ok) {
      return
    }

    const data = await response.json()
    const selectedIds = (data.swimmer_ids || []).map((id) => `${id}`)

    this.swimmerCheckboxTargets.forEach((checkbox) => {
      checkbox.checked = selectedIds.includes(`${checkbox.dataset.swimmerId}`)
    })
    this.updateSelectionCounter()
  }

  async selectCup(event) {
    const cupId = event.target.value
    if (!cupId) {
      this.clearCupFields()
      return
    }

    this.setLoading(true)

    const teamId = this.fieldValue('team_id')
    const url = new URL(this.cupDataUrlValue, window.location.origin)
    url.searchParams.append('team_id', teamId)
    url.searchParams.append('goggle_cup_id', cupId)

    try {
      const response = await fetch(url.toString(), {
        method: 'GET',
        headers: { Accept: 'application/json' }
      })

      if (!response.ok) {
        return
      }

      const data = await response.json()

      if (this.hasGoggleCupIdFieldTarget) {
        this.goggleCupIdFieldTarget.value = data.goggle_cup_id || ''
      }
      if (this.hasCupIdDisplayTarget) {
        this.cupIdDisplayTarget.value = data.goggle_cup_id || ''
      }
      if (this.hasDescriptionFieldTarget) {
        this.descriptionFieldTarget.value = data.description || ''
      }
      if (this.hasSeasonYearFieldTarget) {
        this.seasonYearFieldTarget.value = data.season_year || ''
      }
      if (this.hasEndDateFieldTarget) {
        this.endDateFieldTarget.value = data.end_date || ''
      }
      if (this.hasNoDuplicatedEventsFieldTarget) {
        this.noDuplicatedEventsFieldTarget.checked = !!data.no_duplicated_events
      }

      this.hasRankingDataValue = !!data.has_ranking_data

      const selectedIds = (data.swimmer_ids || []).map((id) => `${id}`)
      this.swimmerCheckboxTargets.forEach((checkbox) => {
        checkbox.checked = selectedIds.includes(`${checkbox.dataset.swimmerId}`)
      })

      this.renderExternalSwimmers(data.external_swimmers || [], selectedIds)
      this.updateSelectionCounter()
    } finally {
      this.setLoading(false)
    }
  }

  clearCupFields() {
    if (this.hasGoggleCupIdFieldTarget) {
      this.goggleCupIdFieldTarget.value = ''
    }
    if (this.hasCupIdDisplayTarget) {
      this.cupIdDisplayTarget.value = ''
    }
    if (this.hasDescriptionFieldTarget) {
      this.descriptionFieldTarget.value = ''
    }
    if (this.hasSeasonYearFieldTarget) {
      this.seasonYearFieldTarget.value = ''
    }
    if (this.hasEndDateFieldTarget) {
      this.endDateFieldTarget.value = ''
    }
    this.hasRankingDataValue = false
    this.updateSelectionCounter()
  }

  renderExternalSwimmers(externalSwimmers, selectedIds) {
    if (!this.hasExternalSwimmersContainerTarget) {
      return
    }

    const container = this.externalSwimmersContainerTarget
    if (!externalSwimmers || externalSwimmers.length === 0) {
      container.innerHTML = ''
      return
    }

    const rows = externalSwimmers.map((swimmer) => {
      const id = swimmer.swimmer_id
      const checked = selectedIds.includes(`${id}`) ? 'checked' : ''
      return `
        <tr>
          <td class="text-center">
            <label class="switch round">
              <input type="checkbox" name="swimmer_ids[]" value="${id}" id="external_swimmer_${id}" ${checked}
                     data-goggles-cup-target="swimmerCheckbox" data-swimmer-id="${id}">
              <span class="slider round"></span>
            </label>
          </td>
          <td>${swimmer.swimmer_name}</td>
          <td>${swimmer.swimmer_year_of_birth}</td>
        </tr>`
    }).join('')

    container.innerHTML = `
      <table class="table table-sm table-bordered">
        <thead>
          <tr>
            <th width="50">${container.dataset.selectLabel || 'Select'}</th>
            <th>${container.dataset.nameLabel || 'Swimmer'}</th>
            <th>${container.dataset.yearLabel || 'Year of Birth'}</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>`
  }

  updateSelectionCounter() {
    if (!this.hasSelectionCounterTarget) {
      return
    }

    const total = this.swimmerCheckboxTargets.length
    const selected = this.swimmerCheckboxTargets.filter((cb) => cb.checked).length
    this.selectionCounterTarget.textContent = `(${selected} / ${total})`
  }

  async loadExisting(event) {
    event.preventDefault()
    const cupId = this.goggleCupIdFieldTarget?.value
    if (!cupId) {
      return
    }

    this.setLoading(true)

    const url = new URL(this.loadRankingUrlValue, window.location.origin)
    url.searchParams.append('team_id', this.fieldValue('team_id'))
    url.searchParams.append('goggle_cup_id', cupId)

    try {
      const response = await fetch(url.toString(), {
        method: 'GET',
        headers: { Accept: 'application/json' }
      })

      if (response.ok) {
        const data = await response.json()
        this.rankingContainerTarget.innerHTML = data.html || ''
        this.collapseSwimmerPanel()
      }
    } finally {
      this.setLoading(false)
    }
  }

  async compute(event) {
    // If the Save button triggered this submit, let the browser handle it
    // natively (formaction → save route). Only intercept Compute submits.
    if (event.submitter && event.submitter.dataset.gogglesCupTarget === 'saveButton') {
      return
    }

    event.preventDefault()

    if (!this.hasFormTarget) {
      return
    }

    // Confirm before overwriting precomputed ranking data
    if (this.hasRankingDataValue && this.hasRankingDataValue === true) {
      const message = this.element.dataset.gogglesCupConfirmOverwriteMessage ||
        'A precomputed ranking exists for this cup. Computing will overwrite it. Continue?'
      if (!window.confirm(message)) {
        return
      }
    }

    this.setLoading(true)

    const formData = new FormData(this.formTarget)
    const response = await fetch(this.formTarget.action, {
      method: this.formTarget.method.toUpperCase(),
      headers: {
        Accept: 'application/json',
        'X-CSRF-Token': this.csrfToken
      },
      body: formData
    })

    if (response.ok) {
      const data = await response.json()
      this.rankingContainerTarget.innerHTML = data.html || ''
      this.collapseSwimmerPanel()
    }

    this.setLoading(false)
  }

  fieldValue(fieldName) {
    const field = this.formTarget.querySelector(`[name="${fieldName}"]`) || document.querySelector(`[name="${fieldName}"]`)
    return field ? field.value : ''
  }

  setLoading(loading) {
    if (!this.hasComputeButtonTarget) {
      return
    }

    this.computeButtonTarget.disabled = loading
    this.computeButtonTarget.classList.toggle('disabled', loading)

    if (this.hasOverlayTarget) {
      this.overlayTarget.classList.toggle('d-none', !loading)
    }
  }

  collapseSwimmerPanel() {
    if (!this.hasSwimmerPanelTarget) {
      return
    }

    this.swimmerPanelTarget.classList.remove('show')
  }
}
