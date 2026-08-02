import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['form', 'noDuplicatedEventsField', 'swimmerCheckbox', 'swimmerPanel', 'rankingContainer', 'computeButton', 'overlay',
                   'cupSelect', 'goggleCupIdField', 'descriptionField', 'seasonYearField', 'endDateField', 'externalSwimmersContainer']
  static values = { smartSelectionUrl: String, cupDataUrl: String }

  connect() {
    this.csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
    this.secondaryTeamSelect = document.querySelector('#secondary_team_select')
    this.boundSmartSelectWithDelay = this.smartSelectWithDelay.bind(this)
    if (this.secondaryTeamSelect) {
      this.secondaryTeamSelect.addEventListener('change', this.boundSmartSelectWithDelay)
    }
  }

  disconnect() {
    if (this.secondaryTeamSelect) {
      this.secondaryTeamSelect.removeEventListener('change', this.boundSmartSelectWithDelay)
    }
  }

  selectAll(event) {
    event.preventDefault()
    this.swimmerCheckboxTargets.forEach((checkbox) => { checkbox.checked = true })
  }

  deselectAll(event) {
    event.preventDefault()
    this.swimmerCheckboxTargets.forEach((checkbox) => { checkbox.checked = false })
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
  }

  async selectCup(event) {
    const cupId = event.target.value
    if (!cupId) {
      this.clearCupFields()
      return
    }

    const teamId = this.fieldValue('team_id')
    const url = new URL(this.cupDataUrlValue, window.location.origin)
    url.searchParams.append('team_id', teamId)
    url.searchParams.append('goggle_cup_id', cupId)

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

    const selectedIds = (data.swimmer_ids || []).map((id) => `${id}`)
    this.swimmerCheckboxTargets.forEach((checkbox) => {
      checkbox.checked = selectedIds.includes(`${checkbox.dataset.swimmerId}`)
    })

    this.renderExternalSwimmers(data.external_swimmers || [], selectedIds)
  }

  clearCupFields() {
    if (this.hasGoggleCupIdFieldTarget) {
      this.goggleCupIdFieldTarget.value = ''
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
    this.swimmerCheckboxTargets.forEach((checkbox) => { checkbox.checked = false })
    this.renderExternalSwimmers([], [])
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
