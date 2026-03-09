import { Controller } from "@hotwired/stimulus"

/**
 * Verify Result Controller
 * Handles Phase 5 duplicate detection with 4-tier classification:
 *   - perfect_matches:  auto-fixed on verify click (same event + timing + team)
 *   - partial_matches:  "Fix with this" buttons (same event + team, different timing)
 *   - team_mismatches:  informational with red background (same event, different team)
 *   - other_events:     informational (different events in same meeting)
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
 */
export default class extends Controller {
  connect() {
    this.csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || ''
    this._handleFixClick = this._onFixClick.bind(this)
    this.element.addEventListener('click', this._handleFixClick)
  }

  disconnect() {
    this.element.removeEventListener('click', this._handleFixClick)
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

  // --- Delegated handler for dynamically-rendered "Fix with this" buttons ---

  _onFixClick(event) {
    const btn = event.target.closest('.fix-with-this-btn')
    if (!btn) return

    event.preventDefault()
    event.stopPropagation()

    const importKey = btn.dataset.importKey
    const existingId = btn.dataset.existingId
    const resultType = btn.dataset.resultType || 'individual'
    const mode = btn.dataset.mode || 'overwrite'

    const modeLabel = mode === 'keep_timing'
      ? 'Fix with IMPORT timing (UPDATE existing row ID: ' + existingId + ' on commit)?'
      : 'Fix with EXISTING DB values (ID: ' + existingId + ', no change on commit)?'

    if (!confirm(modeLabel)) return

    btn.disabled = true
    btn.innerHTML = '<i class="fa fa-spinner fa-spin"></i> Fixing...'

    $.ajax({
      url: '/data_fix/confirm_result_duplicate',
      method: 'PATCH',
      data: { import_key: importKey, existing_id: existingId, result_type: resultType, mode: mode },
      headers: { 'X-CSRF-Token': this.csrfToken },
      dataType: 'json',
      success: function() {
        const row = btn.closest('tr') || btn.closest('div')
        if (row) {
          row.innerHTML =
            '<td colspan="6"><div class="text-success"><i class="fa fa-check-circle"></i> ' +
            'Fixed (ID: ' + existingId + ', mode: ' + mode + '). Refreshing...</div></td>'
        }
        setTimeout(function() { window.location.reload() }, 800)
      },
      error: function(xhr) {
        const msg = xhr.responseJSON ? xhr.responseJSON.error : 'Failed to fix'
        btn.disabled = false
        btn.innerHTML = '<i class="fa fa-wrench"></i> Fix with this'
        alert('Error: ' + msg)
      }
    })
  }

  // --- Private: render verification panel HTML (4-tier) ---

  _renderVerifyPanel(data, importKey, resultType) {
    let html = ''

    // --- TIER 0: Auto-fixed (perfect match applied by backend) ---
    if (data.auto_fixed) {
      const pm = (data.perfect_matches && data.perfect_matches[0]) || {}
      html += '<div class="alert alert-success mb-2">'
      html += '<i class="fa fa-check-circle"></i> <strong>Auto-fixed:</strong> '
      html += 'matched existing result <strong>ID ' + data.auto_fixed_id + '</strong>'
      if (pm.timing) html += ' (' + pm.timing + ', ' + (pm.team_name || 'N/A') + ')'
      html += '<br><small>Refreshing in 3 seconds...</small>'
      html += '</div>'
      setTimeout(function() { window.location.reload() }, 3000)
      // Still show other tiers below for reference
    }

    // --- TIER 1: Perfect matches (already auto-fixed if exactly 1; show info if >1) ---
    if (!data.auto_fixed && data.perfect_matches && data.perfect_matches.length > 1) {
      html += '<div class="alert alert-danger mb-2">'
      html += '<i class="fa fa-ban"></i> <strong>' + data.perfect_matches.length +
              ' perfect matches found!</strong> This indicates DB duplicates — manual cleanup required.'
      html += '</div>'
      html += this._renderMatchTable(data.perfect_matches, importKey, resultType, 'disabled')
    }

    // --- TIER 2: Partial matches (same event + team, different timing) ---
    if (data.partial_matches && data.partial_matches.length > 0) {
      const multiplePartials = data.partial_matches.length > 1
      if (multiplePartials) {
        html += '<div class="alert alert-danger mb-2">'
        html += '<i class="fa fa-ban"></i> <strong>' + data.partial_matches.length +
                ' existing results found for same event + team!</strong><br>' +
                'This indicates DB duplicates — manual cleanup required (use rake tasks to merge/fix).'
        html += '</div>'
      } else {
        html += '<div class="mb-2"><strong class="text-warning">' +
                '<i class="fa fa-exclamation-triangle"></i> Partial match found ' +
                '(same event &amp; team, different timing):</strong></div>'
      }

      // Import row: "Fix with this" = keep_timing mode (UPDATE existing with import timing)
      if (!multiplePartials && !data.auto_fixed) {
        html += '<table class="table table-sm table-bordered mb-1"><tbody>'
        html += '<tr class="table-info"><td><strong>Import row</strong> (this timing)</td>'
        html += '<td class="text-right">'
        html += '<button class="btn btn-sm btn-outline-primary fix-with-this-btn" ' +
                'data-import-key="' + importKey + '" ' +
                'data-existing-id="' + data.partial_matches[0].id + '" ' +
                'data-result-type="' + resultType + '" data-mode="keep_timing">' +
                '<i class="fa fa-wrench"></i> Fix with this</button>'
        html += ' <small class="text-muted ml-1">→ UPDATE existing row with import timing</small>'
        html += '</td></tr></tbody></table>'
      }

      // Existing rows
      html += this._renderMatchTable(
        data.partial_matches, importKey, resultType,
        multiplePartials ? 'disabled' : 'overwrite'
      )
    }

    // --- TIER 3: Team mismatches (same event, different team) — bg-light-red, no buttons ---
    if (data.team_mismatches && data.team_mismatches.length > 0) {
      html += '<div class="mb-2"><strong class="text-danger">' +
              '<i class="fa fa-exclamation-triangle"></i> ' + data.team_mismatches.length +
              ' result(s) with different team (same event):</strong></div>'
      html += '<table class="table table-sm table-bordered mb-2">' +
              '<thead><tr><th>ID</th><th>Rank</th><th>Timing</th><th>Team (ID)</th><th>Note</th></tr></thead><tbody>'

      data.team_mismatches.forEach(function(tm) {
        html += '<tr class="bg-light-red"><td>' + tm.id + '</td>'
        html += '<td>' + (tm.disqualified ? 'DSQ' : tm.rank) + '</td>'
        html += '<td>' + tm.timing + '</td>'
        html += '<td>' + (tm.team_name || 'N/A') + ' (ID: ' + tm.team_id + ')</td>'
        html += '<td><span class="badge badge-danger">TEAM MISMATCH</span></td></tr>'
      })
      html += '</tbody></table>'
    }

    // --- TIER 4: Other events (informational) ---
    if (data.other_events && data.other_events.length > 0) {
      html += '<div class="mb-2"><strong class="text-info"><i class="fa fa-info-circle"></i> ' +
              data.other_events.length + ' other result(s) for this swimmer in same meeting:</strong></div>'
      html += '<table class="table table-sm table-bordered mb-2">' +
              '<thead><tr><th>ID</th><th>Event</th><th>Cat.</th><th>Rank</th><th>Timing</th><th>Team (ID)</th></tr></thead><tbody>'

      data.other_events.forEach(function(oe) {
        const teamCls = oe.team_mismatch ? 'text-danger fw-bold' : ''
        html += '<tr><td>' + oe.id + '</td>'
        html += '<td>' + (oe.event || 'N/A') + '</td>'
        html += '<td>' + (oe.category || 'N/A') + '</td>'
        html += '<td>' + (oe.disqualified ? 'DSQ' : oe.rank) + '</td>'
        html += '<td>' + oe.timing + '</td>'
        html += '<td class="' + teamCls + '">' + (oe.team_name || 'N/A') + ' (ID: ' + oe.team_id + ')'
        if (oe.team_mismatch) html += ' <span class="badge badge-danger">TEAM MISMATCH</span>'
        html += '</td></tr>'
      })
      html += '</tbody></table>'
    }

    // --- Relay duplicates (legacy format from check_relay) ---
    if (data.duplicates && data.duplicates.length > 0) {
      html += '<div class="mb-2"><strong class="text-danger"><i class="fa fa-exclamation-triangle"></i> ' +
              data.duplicates.length + ' relay duplicate(s) found:</strong></div>'
      html += this._renderMatchTable(data.duplicates, importKey, resultType, 'overwrite')
    }

    // --- No matches at all ---
    const hasAny = (data.auto_fixed) ||
                   (data.perfect_matches && data.perfect_matches.length > 0) ||
                   (data.partial_matches && data.partial_matches.length > 0) ||
                   (data.team_mismatches && data.team_mismatches.length > 0) ||
                   (data.other_events && data.other_events.length > 0) ||
                   (data.duplicates && data.duplicates.length > 0)
    if (!hasAny) {
      html += '<div class="text-success"><i class="fa fa-check-circle"></i> No existing results found. This result will be created as new.</div>'
    }

    // --- Swimmer badges ---
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

  // --- Private: render a table of match rows with optional "Fix with this" buttons ---
  // buttonMode: 'overwrite' | 'keep_timing' | 'disabled' | null (no button)

  _renderMatchTable(matches, importKey, resultType, buttonMode) {
    let html = '<table class="table table-sm table-bordered mb-2">' +
               '<thead><tr><th>ID</th><th>Rank</th><th>Timing</th><th>Team (ID)</th>'
    if (buttonMode) html += '<th>Action</th>'
    html += '</tr></thead><tbody>'

    matches.forEach(function(m) {
      html += '<tr><td>' + m.id + '</td>'
      html += '<td>' + (m.disqualified ? 'DSQ' : m.rank) + '</td>'
      html += '<td>' + m.timing
      if (m.timing_diff_hundredths) html += ' <small class="text-muted">(diff: ' + m.timing_diff_hundredths + '/100)</small>'
      html += '</td>'
      html += '<td>' + (m.team_name || 'N/A') + ' (ID: ' + m.team_id + ')</td>'
      if (buttonMode) {
        html += '<td>'
        if (buttonMode === 'disabled') {
          html += '<button class="btn btn-sm btn-outline-secondary" disabled>' +
                  '<i class="fa fa-ban"></i> Manual fix required</button>'
        } else {
          const mode = buttonMode // 'overwrite' or 'keep_timing'
          const label = mode === 'overwrite'
            ? '<i class="fa fa-wrench"></i> Fix with this'
            : '<i class="fa fa-wrench"></i> Fix (keep timing)'
          const hint = mode === 'overwrite'
            ? '→ Keep existing DB values (no change on commit)'
            : '→ UPDATE existing row with import timing'
          html += '<button class="btn btn-sm btn-outline-success fix-with-this-btn" ' +
                  'data-import-key="' + importKey + '" data-existing-id="' + m.id + '" ' +
                  'data-result-type="' + resultType + '" data-mode="' + mode + '">' +
                  label + '</button>'
          html += ' <small class="text-muted ml-1">' + hint + '</small>'
        }
        html += '</td>'
      }
      html += '</tr>'
    })
    html += '</tbody></table>'
    return html
  }
}
