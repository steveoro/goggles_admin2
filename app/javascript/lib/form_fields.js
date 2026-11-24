/**
 * = lib/form_fields =
 *
 * DOM helpers shared by the Data-Fix card controllers (meeting_card, session_card, team_card, swimmer_card,
 * event_card): they address the form fields by DOM id, the ids rendered by the cards and by the
 * LegacyAutoCompleteComponent widgets (e.g. 'team_3_team_id', 'pool_0_name').
 *
 * A 'change' event dispatched on a field bubbles, so the LegacyAutoComplete controllers (listening on their own
 * fields) fetch the details of a newly selected id, exactly as the former inline handlers did.
 */

/**
 * Sets the value of the field with the given id (missing fields are skipped).
 * @param {string} fieldId - DOM id
 * @param {*} value - new value (null/undefined => '')
 * @param {boolean} triggerChange - dispatch a bubbling 'change' event afterwards
 */
export function setFieldValue (fieldId, value, triggerChange = true) {
  const field = document.getElementById(fieldId)
  if (!field) return

  field.value = value == null ? '' : value
  if (triggerChange) dispatchChange(field)
}

/**
 * Sets the checked state of the checkbox with the given id (missing fields are skipped).
 */
export function setCheckboxValue (fieldId, checked, triggerChange = false) {
  const field = document.getElementById(fieldId)
  if (!field) return

  field.checked = !!checked
  if (triggerChange) dispatchChange(field)
}

/**
 * Value of the field with the given id, or null when missing.
 */
export function fieldValue (fieldId) {
  const field = document.getElementById(fieldId)
  return field ? field.value : null
}

/**
 * Dispatches a bubbling 'change' event on a field (an Element or a DOM id).
 */
export function dispatchChange (fieldOrId) {
  const field = typeof fieldOrId === 'string' ? document.getElementById(fieldOrId) : fieldOrId
  if (field) field.dispatchEvent(new Event('change', { bubbles: true }))
}

/**
 * Copies the value of a field into another one, silently (no 'change' event).
 */
export function copyFieldValue (sourceId, targetId) {
  const source = document.getElementById(sourceId)
  if (source) setFieldValue(targetId, source.value, false)
}

/**
 * True for a non-blank value (as the former inline handlers checked: `value.toString().trim().length > 0`).
 */
export function present (value) {
  return value !== null && value !== undefined && value.toString().trim().length > 0
}

/**
 * GET <baseApiUrl>/<endpoint>/<entityId> with the operator's JWT; the parsed JSON, or null on any failure.
 */
export async function fetchEntityDetails (baseApiUrl, endpoint, entityId, jwt) {
  if (!baseApiUrl || !endpoint || !entityId) return null

  try {
    const response = await fetch(`${baseApiUrl}/${endpoint}/${entityId}`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${jwt}` },
      credentials: 'same-origin'
    })
    if (!response.ok) return null

    return await response.json()
  } catch (_error) {
    return null
  }
}

/**
 * Escapes a value for an HTML text node or attribute.
 */
export function escapeHtml (value) {
  return String(value == null ? '' : value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;')
}
