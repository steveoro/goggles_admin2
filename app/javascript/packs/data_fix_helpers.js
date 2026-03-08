// Data-Fix helper functions for populating forms from existing DB records

/**
 * Populate session form fields from existing meeting_session selection
 * @param {number} sessionIndex - The session card index
 * @param {string} meetingSessionId - The selected meeting_session ID
 * @param {Array} existingSessions - Array of existing meeting sessions with all fields
 */
export function populateSessionFromExisting(sessionIndex, meetingSessionId, existingSessions) {
  if (!meetingSessionId || meetingSessionId === '') {
    // Clear fields if "New Session" is selected
    return;
  }

  // Find the selected session in the data
  var session = existingSessions.find(function(s) {
    return s.id == meetingSessionId;
  });

  if (!session) {
    console.warn('Session not found:', meetingSessionId);
    return;
  }

  // Populate form fields
  var prefix = 'session_' + sessionIndex + '_';
  
  if (session.description) {
    $('#' + prefix + 'description').val(session.description);
  }
  
  if (session.session_order) {
    $('#' + prefix + 'order').val(session.session_order);
  }
  
  if (session.scheduled_date) {
    $('#' + prefix + 'scheduled_date').val(session.scheduled_date);
  }
  
  if (session.day_part_type_id) {
    $('#' + prefix + 'day_part_type_id').val(session.day_part_type_id);
  }

  // If swimming_pool_id is available, trigger the pool autocomplete
  if (session.swimming_pool_id) {
    var poolIdField = $('#pool_' + sessionIndex + '_swimming_pool_id');
    if (poolIdField.length) {
      poolIdField.val(session.swimming_pool_id).trigger('change');
    }
  }
}

/**
 * Populate event form fields from existing meeting_event selection
 * @param {number} eventIndex - The event card index
 * @param {string} meetingEventId - The selected meeting_event ID
 * @param {Array} existingEvents - Array of existing meeting events with all fields
 */
export function populateEventFromExisting(eventIndex, meetingEventId, existingEvents) {
  if (!meetingEventId || meetingEventId === '') {
    // Clear fields if "New Event" is selected
    return;
  }

  // Find the selected event in the data
  var event = existingEvents.find(function(e) {
    return e.id == meetingEventId;
  });

  if (!event) {
    console.warn('Event not found:', meetingEventId);
    return;
  }

  // Populate form fields
  var prefix = 'event_' + eventIndex + '_';
  
  if (event.event_order) {
    $('#' + prefix + 'order').val(event.event_order);
  }
  
  if (event.begin_time) {
    $('#' + prefix + 'begin_time').val(event.begin_time);
  }
  
  if (event.heat_type_id) {
    $('#' + prefix + 'heat_type_id').val(event.heat_type_id);
  }

  // If event_type_id is available, trigger the event_type autocomplete
  if (event.event_type_id) {
    var eventTypeIdField = $('#meeting_event_' + eventIndex + '_event_type_id');
    if (eventTypeIdField.length) {
      eventTypeIdField.val(event.event_type_id).trigger('change');
    }
  }

  // Populate legacy fields for backward compatibility
  // These fields are used by the phase file format and are derived from event_type/heat_type
  if (event.distance) {
    $('#' + prefix + 'distance').val(event.distance);
  }
  
  if (event.stroke_type_code) {
    $('#' + prefix + 'stroke').val(event.stroke_type_code);
  }
  
  if (event.heat_type_code) {
    $('#' + prefix + 'heat_type_code').val(event.heat_type_code);
  }
}

/**
 * Initialize verify-result buttons for Phase 5 duplicate detection.
 * Call this after the DOM is ready (e.g., in a DOMContentLoaded handler).
 */
export function initVerifyResultButtons() {
  $(document).on('click', '.verify-result-btn', function(e) {
    e.preventDefault();
    var btn = $(this);
    var importKey = btn.data('import-key');
    var resultType = btn.data('result-type') || 'individual';
    var targetSelector = btn.data('target');
    var panel = $(targetSelector);

    // Show the panel with spinner
    panel.collapse('show');

    $.ajax({
      url: '/data_fix/verify_result',
      method: 'GET',
      data: { import_key: importKey, result_type: resultType },
      dataType: 'json',
      success: function(data) {
        var html = renderVerifyPanel(data, importKey, resultType);
        panel.find('td > div').html(html);
      },
      error: function(xhr) {
        var msg = xhr.responseJSON ? xhr.responseJSON.error : 'Verification failed';
        panel.find('td > div').html(
          '<div class="text-danger"><i class="fa fa-exclamation-triangle"></i> ' + msg + '</div>'
        );
      }
    });
  });

  // Confirm duplicate button handler (delegated)
  $(document).on('click', '.confirm-duplicate-btn', function(e) {
    e.preventDefault();
    var btn = $(this);
    var importKey = btn.data('import-key');
    var existingId = btn.data('existing-id');
    var resultType = btn.data('result-type') || 'individual';
    var row = btn.closest('tr');

    if (!confirm('Confirm this result as existing (ID: ' + existingId + ')? The import row will be overwritten with DB values.')) {
      return;
    }

    btn.prop('disabled', true).html('<i class="fa fa-spinner fa-spin"></i> Confirming...');

    $.ajax({
      url: '/data_fix/confirm_result_duplicate',
      method: 'PATCH',
      data: { import_key: importKey, existing_id: existingId, result_type: resultType },
      headers: { 'X-CSRF-Token': $('meta[name="csrf-token"]').attr('content') },
      dataType: 'json',
      success: function() {
        row.find('td > div').html(
          '<div class="text-success"><i class="fa fa-check-circle"></i> ' +
          'Confirmed as existing (ID: ' + existingId + '). ' +
          'Reload page to see updated status.</div>'
        );
      },
      error: function(xhr) {
        var msg = xhr.responseJSON ? xhr.responseJSON.error : 'Failed to confirm';
        btn.prop('disabled', false).html('<i class="fa fa-check"></i> Confirm');
        alert('Error: ' + msg);
      }
    });
  });
}

/**
 * Render the verification panel HTML from the AJAX response data.
 */
function renderVerifyPanel(data, importKey, resultType) {
  var html = '';

  if (data.duplicates && data.duplicates.length > 0) {
    html += '<div class="mb-2"><strong class="text-danger"><i class="fa fa-exclamation-triangle"></i> ' +
            data.duplicates.length + ' potential duplicate(s) found:</strong></div>';
    html += '<table class="table table-sm table-bordered mb-2">';
    html += '<thead><tr><th>ID</th><th>Rank</th><th>Timing</th><th>Team</th><th>Match</th><th>Action</th></tr></thead><tbody>';

    data.duplicates.forEach(function(dup) {
      var timingClass = dup.timing_match ? 'text-success' : 'text-warning';
      var teamClass = dup.team_mismatch ? 'text-danger' : 'text-success';
      var teamLabel = dup.team_mismatch ? '!= MISMATCH' : 'OK';
      html += '<tr>';
      html += '<td>' + dup.id + '</td>';
      html += '<td>' + (dup.disqualified ? 'DSQ' : dup.rank) + '</td>';
      html += '<td class="' + timingClass + '">' + dup.timing;
      if (!dup.timing_match) {
        html += ' <small>(diff: ' + dup.timing_diff_hundredths + '/100)</small>';
      }
      html += '</td>';
      html += '<td>' + (dup.team_name || 'N/A') + ' <span class="' + teamClass + '">(' + teamLabel + ')</span></td>';
      html += '<td>' + (dup.timing_match ? '<span class="badge badge-success">Exact</span>' : '<span class="badge badge-warning">Diff</span>') + '</td>';
      html += '<td><button class="btn btn-sm btn-outline-success confirm-duplicate-btn" ' +
              'data-import-key="' + importKey + '" data-existing-id="' + dup.id + '" ' +
              'data-result-type="' + resultType + '">' +
              '<i class="fa fa-check"></i> Confirm as existing</button></td>';
      html += '</tr>';
    });
    html += '</tbody></table>';
  } else {
    html += '<div class="text-success"><i class="fa fa-check-circle"></i> No duplicates found. This result will be created as new.</div>';
  }

  // Show swimmer badges (for individual results)
  if (data.swimmer_badges && data.swimmer_badges.length > 0) {
    html += '<div class="mt-2"><small><strong>Swimmer badges this season:</strong> ';
    data.swimmer_badges.forEach(function(badge, idx) {
      if (idx > 0) html += ', ';
      html += badge.team_name + ' (ID: ' + badge.badge_id + ')';
    });
    if (data.swimmer_badges.length > 1) {
      html += ' <span class="badge badge-danger">MULTIPLE BADGES</span>';
    }
    html += '</small></div>';
  }

  return html;
}
