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
