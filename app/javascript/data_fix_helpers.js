// Data-Fix helper functions for populating forms from existing DB records

function setFieldValue(fieldId, value, triggerChange = true) {
  const field = document.getElementById(fieldId)
  if (!field) {
    return
  }

  field.value = value == null ? '' : value
  if (triggerChange) {
    field.dispatchEvent(new Event('change', { bubbles: true }))
  }
}

function setCheckboxValue(fieldId, checked, triggerChange = false) {
  const field = document.getElementById(fieldId)
  if (!field) {
    return
  }

  field.checked = !!checked
  if (triggerChange) {
    field.dispatchEvent(new Event('change', { bubbles: true }))
  }
}

export function resetMeetingFormToOriginal(originalMeetingData) {
  if (!originalMeetingData || typeof originalMeetingData !== 'object') {
    return
  }

  setFieldValue('meeting_meeting_id', '', false)
  setFieldValue('meeting_meeting', '', false)
  const desc = document.getElementById('meeting-desc')
  if (desc) {
    desc.innerHTML = ''
  }

  setFieldValue('meeting_description', originalMeetingData.name, false)
  setFieldValue('meeting_code', originalMeetingData.code, false)
  setFieldValue('meeting_season_id', originalMeetingData.season_id, false)
  setFieldValue('meeting_header_year', originalMeetingData.header_year, false)
  setFieldValue('meeting_header_date', originalMeetingData.header_date, false)
  setFieldValue('meetingURL', originalMeetingData.meetingURL, false)

  setFieldValue('meeting_edition', originalMeetingData.edition, false)
  setFieldValue('meeting_edition_type_id', originalMeetingData.edition_type_id, false)
  setFieldValue('meeting_timing_type_id', originalMeetingData.timing_type_id, false)
  setCheckboxValue('meeting_cancelled', originalMeetingData.cancelled)
  setCheckboxValue('meeting_confirmed', originalMeetingData.confirmed == null ? true : originalMeetingData.confirmed)

  setFieldValue('max_individual_events', originalMeetingData.max_individual_events, false)
  setFieldValue('max_individual_events_per_session', originalMeetingData.max_individual_events_per_session, false)
  setFieldValue('poolLength', originalMeetingData.poolLength, false)

  setFieldValue('dateDay1', originalMeetingData.dateDay1, false)
  setFieldValue('dateMonth1', originalMeetingData.dateMonth1, false)
  setFieldValue('dateYear1', originalMeetingData.dateYear1, false)
  setFieldValue('dateDay2', originalMeetingData.dateDay2, false)
  setFieldValue('dateMonth2', originalMeetingData.dateMonth2, false)
  setFieldValue('dateYear2', originalMeetingData.dateYear2, false)
  setFieldValue('venue1', originalMeetingData.venue1, false)
  setFieldValue('address1', originalMeetingData.address1, false)
}

export function resetTeamFormToOriginal(originalTeamData, teamIndex) {
  if (!originalTeamData || typeof originalTeamData !== 'object') {
    return
  }

  const prefix = 'team_' + teamIndex + '_'

  setFieldValue(prefix + 'id_field', '', false)
  setFieldValue(prefix + 'team_id', '', false)
  setFieldValue(prefix, '', false)

  setFieldValue(prefix + 'editable_name', originalTeamData.editable_name, false)
  setFieldValue(prefix + 'name', originalTeamData.name, false)
  setFieldValue(prefix + 'name_variations', originalTeamData.name_variations, false)
  setFieldValue(prefix + 'city_id_field', originalTeamData.city_id, false)
}

export function resetSwimmerFormToOriginal(originalSwimmerData, swimmerIndex) {
  if (!originalSwimmerData || typeof originalSwimmerData !== 'object') {
    return
  }

  const prefix = 'swimmer_' + swimmerIndex + '_'

  setFieldValue(prefix + 'id_field', '', false)
  setFieldValue(prefix + 'swimmer_id', '', false)
  setFieldValue('swimmer[' + swimmerIndex + ']', '', false)

  setFieldValue(prefix + 'complete_name', originalSwimmerData.complete_name, false)
  setFieldValue(prefix + 'last_name', originalSwimmerData.last_name, false)
  setFieldValue(prefix + 'first_name', originalSwimmerData.first_name, false)
  setFieldValue(prefix + 'year_of_birth', originalSwimmerData.year_of_birth, false)
  setFieldValue(prefix + 'gender_type_code', originalSwimmerData.gender_type_code, false)
}

export function resetSessionPoolAndCityToOriginal(originalData, sessionIndex) {
  if (!originalData || typeof originalData !== 'object') {
    return
  }

  const poolPrefix = 'pool_' + sessionIndex + '_'
  const cityPrefix = 'city_' + sessionIndex + '_'

  setFieldValue(poolPrefix + 'id_field', originalData.id, false)
  setFieldValue(poolPrefix + 'swimming_pool_id', originalData.id, false)
  setFieldValue('pool[' + sessionIndex + ']', originalData.id, false)

  setFieldValue(poolPrefix + 'name', originalData.name, false)
  setFieldValue(poolPrefix + 'nick_name', originalData.nick_name, false)
  setFieldValue(poolPrefix + 'address', originalData.address, false)
  setFieldValue(poolPrefix + 'pool_type_id', originalData.pool_type_id, false)
  setFieldValue(poolPrefix + 'lanes_number', originalData.lanes_number, false)
  setFieldValue(poolPrefix + 'maps_uri', originalData.maps_uri, false)
  setFieldValue(poolPrefix + 'plus_code', originalData.plus_code, false)
  setFieldValue(poolPrefix + 'latitude', originalData.latitude, false)
  setFieldValue(poolPrefix + 'longitude', originalData.longitude, false)

  setFieldValue(cityPrefix + 'id_field', originalData.city_id, false)
  setFieldValue(cityPrefix + 'city_id', originalData.city_id, false)
  setFieldValue('city[' + sessionIndex + ']', originalData.city_id, false)

  setFieldValue(cityPrefix + 'name', originalData.city_name, false)
  setFieldValue(cityPrefix + 'area', originalData.city_area, false)
  setFieldValue(cityPrefix + 'zip', originalData.city_zip, false)
  setFieldValue(cityPrefix + 'country', originalData.city_country, false)
  setFieldValue(cityPrefix + 'country_code', originalData.city_country_code, false)
  setFieldValue(cityPrefix + 'latitude', originalData.city_latitude, false)
  setFieldValue(cityPrefix + 'longitude', originalData.city_longitude, false)
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

  const container = poolIdField.closest('[data-controller="legacy-autocomplete"]')
  if (!container) {
    return null
  }

  return {
    baseApiUrl: container.dataset.legacyAutocompleteBaseApiUrlValue,
    jwt: container.dataset.legacyAutocompleteJwtValue
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
    const field = document.getElementById(prefix + 'description');
    if (field) field.value = session.description;
  }

  if (session.session_order) {
    const field = document.getElementById(prefix + 'order');
    if (field) field.value = session.session_order;
  }

  if (session.scheduled_date) {
    const field = document.getElementById(prefix + 'scheduled_date');
    if (field) field.value = session.scheduled_date;
  }

  if (session.day_part_type_id) {
    const field = document.getElementById(prefix + 'day_part_type_id');
    if (field) field.value = session.day_part_type_id;
  }

  // If swimming_pool_id is available, trigger the pool autocomplete
  if (session.swimming_pool_id) {
    var poolIdField = document.getElementById('pool_' + sessionIndex + '_swimming_pool_id');
    if (poolIdField) {
      poolIdField.value = session.swimming_pool_id;
      poolIdField.dispatchEvent(new Event('change', { bubbles: true }));
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
    const field = document.getElementById(prefix + 'order');
    if (field) field.value = event.event_order;
  }

  if (event.begin_time) {
    const field = document.getElementById(prefix + 'begin_time');
    if (field) field.value = event.begin_time;
  }

  if (event.heat_type_id) {
    const field = document.getElementById(prefix + 'heat_type_id');
    if (field) field.value = event.heat_type_id;
  }

  // If event_type_id is available, trigger the event_type autocomplete
  if (event.event_type_id) {
    var eventTypeIdField = document.getElementById('meeting_event_' + eventIndex + '_event_type_id');
    if (eventTypeIdField) {
      eventTypeIdField.value = event.event_type_id;
      eventTypeIdField.dispatchEvent(new Event('change', { bubbles: true }));
    }
  }

  // Populate legacy fields for backward compatibility
  // These fields are used by the phase file format and are derived from event_type/heat_type
  if (event.distance) {
    const field = document.getElementById(prefix + 'distance');
    if (field) field.value = event.distance;
  }

  if (event.stroke_type_code) {
    const field = document.getElementById(prefix + 'stroke');
    if (field) field.value = event.stroke_type_code;
  }

  if (event.heat_type_code) {
    const field = document.getElementById(prefix + 'heat_type_code');
    if (field) field.value = event.heat_type_code;
  }
}

// Verify-result and confirm-duplicate logic has been moved to
// the verify-result Stimulus controller (verify_result_controller.js).
