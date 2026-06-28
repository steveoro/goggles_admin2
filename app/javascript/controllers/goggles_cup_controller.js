import { Controller } from '@hotwired/stimulus'

export default class extends Controller {
  static targets = ['form', 'noDuplicatedEventsField', 'swimmerCheckbox', 'swimmerPanel', 'rankingContainer', 'computeButton']
  static values = { smartSelectionUrl: String }

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

  async compute(event) {
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
  }

  collapseSwimmerPanel() {
    if (!this.hasSwimmerPanelTarget) {
      return
    }

    this.swimmerPanelTarget.classList.remove('show')
  }
}
