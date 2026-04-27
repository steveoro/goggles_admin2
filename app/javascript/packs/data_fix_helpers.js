// Data-Fix helper functions for populating forms from existing DB records

function setFieldValue(fieldId, value, triggerChange = true) {
  const field = $('#' + fieldId)
  if (!field.length) {
    return
  }

  field.val(value == null ? '' : value)
  if (triggerChange) {
    field.trigger('change')
  }
}

function clearSessionCityFields(sessionIndex) {
  setFieldValue('city_' + sessionIndex + '_id_field', '', false)
  setFieldValue('city_' + sessionIndex + '_city_id', '', false)
  setFieldValue('city_' + sessionIndex + '_name', '')
  setFieldValue('city_' + sessionIndex + '_area', '')
  setFieldValue('city_' + sessionIndex + '_zip', '')
  setFieldValue('city_' + sessionIndex + '_country', '')
  setFieldValue('city_' + sessionIndex + '_country_code', '')
  setFieldValue('city_' + sessionIndex + '_latitude', '')
  setFieldValue('city_' + sessionIndex + '_longitude', '')
}

function getAutocompleteContextForSession(sessionIndex) {
  const poolIdField = document.querySelector('#pool_' + sessionIndex + '_swimming_pool_id')
  if (!poolIdField) {
    return null
  }

  const container = poolIdField.closest('[data-controller="autocomplete"]')
  if (!container) {
    return null
  }

  return {
    baseApiUrl: container.dataset.autocompleteBaseApiUrlValue,
    jwt: container.dataset.autocompleteJwtValue
  }
}

async function fetchEntityDetails(baseApiUrl, endpoint, entityId, jwt) {
  if (!baseApiUrl || !endpoint || !entityId) {
    return null
  }

  const response = await fetch(baseApiUrl + '/' + endpoint + '/' + entityId, {
    method: 'GET',
    headers: {
      Authorization: 'Bearer ' + jwt
    },
    credentials: 'same-origin'
  })

  if (!response.ok) {
    return null
  }

  return response.json()
}

function applySessionPoolFields(sessionIndex, pool) {
  setFieldValue('pool_' + sessionIndex + '_id_field', pool.id, false)
  setFieldValue('pool_' + sessionIndex + '_swimming_pool_id', pool.id, false)
  setFieldValue('pool_' + sessionIndex + '_name', pool.name)
  setFieldValue('pool_' + sessionIndex + '_nick_name', pool.nick_name)
  setFieldValue('pool_' + sessionIndex + '_address', pool.address)
  setFieldValue('pool_' + sessionIndex + '_pool_type_id', pool.pool_type_id)
  setFieldValue('pool_' + sessionIndex + '_lanes_number', pool.lanes_number)
  setFieldValue('pool_' + sessionIndex + '_maps_uri', pool.maps_uri)
  setFieldValue('pool_' + sessionIndex + '_plus_code', pool.plus_code)
  setFieldValue('pool_' + sessionIndex + '_latitude', pool.latitude)
  setFieldValue('pool_' + sessionIndex + '_longitude', pool.longitude)
}

function applySessionCityFields(sessionIndex, city) {
  if (!city) {
    clearSessionCityFields(sessionIndex)
    return
  }

  setFieldValue('city_' + sessionIndex + '_id_field', city.id, false)
  setFieldValue('city_' + sessionIndex + '_city_id', city.id, false)
  setFieldValue('city_' + sessionIndex + '_name', city.name)
  setFieldValue('city_' + sessionIndex + '_area', city.area)
  setFieldValue('city_' + sessionIndex + '_zip', city.zip)
  setFieldValue('city_' + sessionIndex + '_country', city.country)
  setFieldValue('city_' + sessionIndex + '_country_code', city.country_code)
  setFieldValue('city_' + sessionIndex + '_latitude', city.latitude)
  setFieldValue('city_' + sessionIndex + '_longitude', city.longitude)
}

export async function rehydrateSessionPoolAndCity(sessionIndex, poolId) {
  if (!poolId) {
    clearSessionCityFields(sessionIndex)
    return
  }

  const context = getAutocompleteContextForSession(sessionIndex)
  if (!context || !context.baseApiUrl || !context.jwt) {
    return
  }

  const pool = await fetchEntityDetails(context.baseApiUrl, 'swimming_pool', poolId, context.jwt)
  if (!pool) {
    return
  }

  applySessionPoolFields(sessionIndex, pool)

  if (!pool.city_id) {
    clearSessionCityFields(sessionIndex)
    return
  }

  const city = await fetchEntityDetails(context.baseApiUrl, 'city', pool.city_id, context.jwt)
  applySessionCityFields(sessionIndex, city)
}

export function rehydrateSessionCityFromId(sessionIndex, cityId) {
  if (!cityId) {
    clearSessionCityFields(sessionIndex)
    return
  }

  const context = getAutocompleteContextForSession(sessionIndex)
  if (!context || !context.baseApiUrl || !context.jwt) {
    return
  }

  fetchEntityDetails(context.baseApiUrl, 'city', cityId, context.jwt)
    .then((city) => {
      applySessionCityFields(sessionIndex, city)
    })
    .catch(() => {
      clearSessionCityFields(sessionIndex)
    })
}

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
      rehydrateSessionPoolAndCity(sessionIndex, session.swimming_pool_id)
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

// Verify-result and confirm-duplicate logic has been moved to
// the verify-result Stimulus controller (verify_result_controller.js).
