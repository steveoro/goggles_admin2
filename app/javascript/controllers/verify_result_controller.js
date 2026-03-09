import { Controller } from "@hotwired/stimulus"

/**
 * Verify Result Controller
 * Handles Phase 5 duplicate detection: verify buttons and confirm-as-existing actions.
 *
 * Usage:
 *   <div data-controller="verify-result">
 *     <button data-action="click->verify-result#verify"
 *             data-verify-result-import-key-param="..."
 *             data-verify-result-result-type-param="individual"
 *             data-verify-result-target-panel-param="#result-0-1-verify">
 *       Verify
 *     </button>
 *   </div>
 *
 * The confirm buttons are rendered dynamically inside the AJAX panel.
 * We use a delegated click listener (bound once in connect) to handle them.
 */
export default class extends Controller {
  connect() {
    this.csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
    // Delegated handler for dynamically-rendered confirm buttons
    this._handleConfirmClick = this._onConfirmClick.bind(this)
    this.element.addEventListener('click', this._handleConfirmClick)
  }

  disconnect() {
    this.element.removeEventListener('click', this._handleConfirmClick)
  }

  // --- Actions ---

  verify(event) {
    event.preventDefault()
    const btn = event.currentTarget
    const importKey = btn.dataset.verifyResultImportKeyParam
    const resultType = btn.dataset.verifyResultResultTypeParam || 'individual'
    const targetSelector = btn.dataset.verifyResultTargetPanelParam
    const panel = document.querySelector(targetSelector)
    if (!panel) return

    // Show the panel (Bootstrap collapse)
    $(panel).collapse('show')

    const self = this
    $.ajax({
      url: '/data_fix/verify_result',
      method: 'GET',
      data: { import_key: importKey, result_type: resultType },
      dataType: 'json',
      success: function(data) {
        const container = panel.querySelector('td > div') || panel.querySelector('div')
        if (container) container.innerHTML = self._renderVerifyPanel(data, importKey, resultType)
      },
      error: function(xhr) {
        const msg = xhr.responseJSON ? xhr.responseJSON.error : 'Verification failed'
        const container = panel.querySelector('td > div') || panel.querySelector('div')
        if (container) {
          container.innerHTML = '<div class="text-danger"><i class="fa fa-exclamation-triangle"></i> ' + msg + '</div>'
        }
      }
    })
  }

  // --- Delegated confirm handler ---

  _onConfirmClick(event) {
    const btn = event.target.closest('.confirm-duplicate-btn')
    if (!btn) return

    event.preventDefault()
    event.stopPropagation()

    const importKey = btn.dataset.importKey
    const existingId = btn.dataset.existingId
    const resultType = btn.dataset.resultType || 'individual'

    if (!confirm('Confirm this result as existing (ID: ' + existingId + ')? The import row will be overwritten with DB values.')) {
      return
    }

    btn.disabled = true
    btn.innerHTML = '<i class="fa fa-spinner fa-spin"></i> Confirming...'

    $.ajax({
      url: '/data_fix/confirm_result_duplicate',
      method: 'PATCH',
      data: { import_key: importKey, existing_id: existingId, result_type: resultType },
      headers: { 'X-CSRF-Token': this.csrfToken },
      dataType: 'json',
      success: function() {
        const row = btn.closest('tr')
        const container = row ? (row.querySelector('td > div') || row) : btn.parentElement
        if (container) {
          container.innerHTML =
            '<div class="text-success"><i class="fa fa-check-circle"></i> ' +
            'Confirmed as existing (ID: ' + existingId + '). Refreshing...</div>'
        }
        setTimeout(function() { window.location.reload() }, 800)
      },
      error: function(xhr) {
        const msg = xhr.responseJSON ? xhr.responseJSON.error : 'Failed to confirm'
        btn.disabled = false
        btn.innerHTML = '<i class="fa fa-check"></i> Confirm'
        alert('Error: ' + msg)
      }
    })
  }

  // --- Private: render verification panel HTML ---

  _renderVerifyPanel(data, importKey, resultType) {
    let html = ''

    // 1) Exact-program duplicates (with Confirm button)
    if (data.duplicates && data.duplicates.length > 0) {
      html += '<div class="mb-2"><strong class="text-danger"><i class="fa fa-exclamation-triangle"></i> ' +
              data.duplicates.length + ' exact duplicate(s) (same program):</strong></div>'
      html += '<table class="table table-sm table-bordered mb-2">' +
              '<thead><tr><th>ID</th><th>Rank</th><th>Timing</th><th>Team</th><th>Match</th><th>Action</th></tr></thead><tbody>'

      data.duplicates.forEach(function(dup) {
        const timingCls = dup.timing_match ? 'text-success' : 'text-warning'
        const teamCls = dup.team_mismatch ? 'text-danger' : 'text-success'
        const teamLbl = dup.team_mismatch ? '!= MISMATCH' : 'OK'
        html += '<tr><td>' + dup.id + '</td>'
        html += '<td>' + (dup.disqualified ? 'DSQ' : dup.rank) + '</td>'
        html += '<td class="' + timingCls + '">' + dup.timing
        if (!dup.timing_match) html += ' <small>(diff: ' + dup.timing_diff_hundredths + '/100)</small>'
        html += '</td>'
        html += '<td>' + (dup.team_name || 'N/A') + ' (ID: ' + dup.team_id + ') <span class="' + teamCls + '">(' + teamLbl + ')</span></td>'
        html += '<td>' + (dup.timing_match ? '<span class="badge badge-success">Exact</span>' : '<span class="badge badge-warning">Diff</span>') + '</td>'
        html += '<td><button class="btn btn-sm btn-outline-success confirm-duplicate-btn" ' +
                'data-import-key="' + importKey + '" data-existing-id="' + dup.id + '" ' +
                'data-result-type="' + resultType + '">' +
                '<i class="fa fa-check"></i> Confirm as existing</button></td></tr>'
      })
      html += '</tbody></table>'
    }

    // 2) Meeting-wide results (informational only — NO Confirm button)
    if (data.meeting_results && data.meeting_results.length > 0) {
      html += '<div class="mb-2"><strong class="text-info"><i class="fa fa-info-circle"></i> ' +
              data.meeting_results.length + ' other result(s) for this swimmer in same meeting:</strong></div>'
      html += '<table class="table table-sm table-bordered mb-2">' +
              '<thead><tr><th>ID</th><th>Event</th><th>Cat.</th><th>Rank</th><th>Timing</th><th>Team (ID)</th></tr></thead><tbody>'

      data.meeting_results.forEach(function(mr) {
        const teamCls = mr.team_mismatch ? 'text-danger fw-bold' : ''
        html += '<tr><td>' + mr.id + '</td>'
        html += '<td>' + (mr.event || 'N/A') + '</td>'
        html += '<td>' + (mr.category || 'N/A') + '</td>'
        html += '<td>' + (mr.disqualified ? 'DSQ' : mr.rank) + '</td>'
        html += '<td>' + mr.timing + '</td>'
        html += '<td class="' + teamCls + '">' + (mr.team_name || 'N/A') + ' (ID: ' + mr.team_id + ')'
        if (mr.team_mismatch) html += ' <span class="badge badge-danger">TEAM MISMATCH</span>'
        html += '</td></tr>'
      })
      html += '</tbody></table>'
    }

    // 3) No results at all
    if ((!data.duplicates || data.duplicates.length === 0) && (!data.meeting_results || data.meeting_results.length === 0)) {
      html += '<div class="text-success"><i class="fa fa-check-circle"></i> No duplicates found. This result will be created as new.</div>'
    }

    // 4) Swimmer badges
    if (data.swimmer_badges && data.swimmer_badges.length > 0) {
      html += '<div class="mt-2"><small><strong>Swimmer badges this season:</strong> '
      data.swimmer_badges.forEach(function(b, i) {
        if (i > 0) html += ', '
        html += b.team_name + ' (team ID: ' + b.team_id + ', badge ID: ' + b.badge_id + ')'
      })
      if (data.swimmer_badges.length > 1) html += ' <span class="badge badge-danger">MULTIPLE BADGES</span>'
      html += '</small></div>'
    }

    return html
  }
}
