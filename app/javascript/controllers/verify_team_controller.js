import { Controller } from '@hotwired/stimulus'
import { Collapse } from 'bootstrap'
import { escapeHtml } from 'lib/form_fields'

const CONFIDENCE_CLASS = { high: 'text-success', medium: 'text-warning', low: 'text-danger', none: 'text-body-secondary' }
const CONFIDENCE_LABEL = { high: 'HIGH', medium: 'MEDIUM', low: 'LOW', none: 'N/A' }

/**
 * = verify-team - StimulusJS controller =
 *
 * "Verify via swimmers" of a matched Step 2 team card: GET data_fix/verify_team (JSON, read only) cross-checks the
 * candidate team with the Phase 3 swimmer badges and the panel shows the outcome (former inline script of
 * review_teams).
 *
 * == Values ==
 * - url: the verify_team URL (file_path, team_key and candidate_team_id included);
 * - failedLabel / emptyLabel: i18n texts of a failed check and of a team without matched swimmers.
 *
 * == Targets ==
 * - panel: the collapse shown on click; content: its body, replaced by the outcome.
 *
 * == Actions ==
 * - verify (click on the button).
 */
export default class extends Controller {
  static targets = ['panel', 'content']

  static values = {
    url: String,
    failedLabel: { type: String, default: 'Verification failed' },
    emptyLabel: { type: String, default: 'No matched swimmers found for this team in Phase 3.' }
  }

  async verify (event) {
    event.preventDefault()
    if (!this.hasPanelTarget || !this.urlValue) return

    Collapse.getOrCreateInstance(this.panelTarget, { toggle: false }).show()
    try {
      const response = await fetch(this.urlValue, { method: 'GET', headers: { Accept: 'application/json' } })
      if (!response.ok) throw new Error(`HTTP ${response.status}`)

      this.render(this.panelHtml(await response.json()))
    } catch (_error) {
      this.render(`<div class="text-danger"><i class="fa fa-exclamation-triangle" aria-hidden="true"></i> ${escapeHtml(this.failedLabelValue)}</div>`)
    }
  }

  render (html) {
    if (this.hasContentTarget) this.contentTarget.innerHTML = html
  }

  panelHtml (data) {
    const confidenceClass = CONFIDENCE_CLASS[data.confidence] || 'text-body-secondary'
    const confidenceLabel = CONFIDENCE_LABEL[data.confidence] || 'N/A'
    let html = `<div class="mb-2"><strong>Confidence: <span class="${confidenceClass}">${confidenceLabel}</span></strong>`
    html += ` (${escapeHtml(data.confirmed)}/${escapeHtml(data.total)} swimmers confirmed`
    if (data.confirmed_other_seasons > 0) html += ` +${escapeHtml(data.confirmed_other_seasons)} via other seasons`
    html += ')</div>'

    const swimmers = Array.isArray(data.swimmers) ? data.swimmers : []
    if (swimmers.length === 0) {
      return `${html}<div class="text-body-secondary"><em>${escapeHtml(this.emptyLabelValue)}</em></div>`
    }

    html += '<div class="table-responsive"><table class="table table-sm table-bordered mb-0"><thead><tr>' +
            '<th>Swimmer</th><th>ID</th><th>Badge Teams (target season)</th><th>Other Season Badges</th><th>Match</th>' +
            '</tr></thead><tbody>'
    swimmers.forEach((swimmer) => {
      html += `<tr><td>${escapeHtml(swimmer.name)}</td><td>${escapeHtml(swimmer.swimmer_id)}</td>` +
              `<td>${this.badgeTeams(swimmer)}</td><td><small>${this.otherBadges(swimmer)}</small></td>` +
              `<td>${this.matchIcon(swimmer)}</td></tr>`
    })
    return `${html}</tbody></table></div>`
  }

  badgeTeams (swimmer) {
    const teams = (swimmer.badge_teams || []).map((badge) =>
      `${escapeHtml(badge.team_name)} (ID: ${escapeHtml(badge.team_id)} / Badge ID: ${escapeHtml(badge.badge_id)})`)
    return teams.join(', ') || '<strong class="text-danger">NO BADGE</strong>'
  }

  otherBadges (swimmer) {
    const others = (swimmer.other_season_badges || []).map((badge) =>
      `${escapeHtml(badge.team_name)} (ID: ${escapeHtml(badge.team_id)} / S: ${escapeHtml(badge.season_id)} / B: ${escapeHtml(badge.badge_id)})`)
    return others.join('<br>') || '<em>None</em>'
  }

  matchIcon (swimmer) {
    if (swimmer.matches_candidate) return '<span class="text-success"><i class="fa fa-check-circle" aria-hidden="true"></i> Yes</span>'
    if (swimmer.matches_candidate_other_seasons) {
      return '<span class="text-warning"><i class="fa fa-check-circle" aria-hidden="true"></i> Other season</span>'
    }
    return '<span class="text-danger"><i class="fa fa-times-circle" aria-hidden="true"></i> No</span>'
  }
}
