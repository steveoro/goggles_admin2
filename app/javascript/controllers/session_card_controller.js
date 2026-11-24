import { Controller } from '@hotwired/stimulus'
import { setFieldValue, copyFieldValue, dispatchChange, fieldValue, fetchEntityDetails, present } from 'lib/form_fields'

const POOL_FIELDS = ['name', 'nick_name', 'address', 'pool_type_id', 'lanes_number', 'maps_uri', 'plus_code', 'latitude', 'longitude']
const CITY_FIELDS = ['name', 'area', 'zip', 'country', 'country_code', 'latitude', 'longitude']
// Fields copied verbatim from a sibling session card (hidden/autocomplete id fields included)
const COPIED_POOL_FIELDS = ['swimming_pool_id', 'swimming_pool', 'id_field'].concat(POOL_FIELDS)
const COPIED_CITY_FIELDS = ['city_id', 'city', 'id_field'].concat(CITY_FIELDS)

/**
 * = session-card - StimulusJS controller =
 *
 * One Step 1 session card (data_fix/_session_form_card): pool and city fields, whose DOM ids are
 * 'pool_<index>_<field>' / 'city_<index>_<field>' (rendered by the card and its LegacyAutoComplete widgets).
 * (Former global Data-Fix session helpers of data_fix_helpers.js; the pool/city rehydration notes are in AGENTS.md.)
 *
 * == Values ==
 * - index: the session index; existingSessions: the DB sessions of the matched meeting (Step 1 select);
 * - copiedLabel / copyMissingLabel: i18n texts of the copy feedback;
 * - baseline: pool + city fields as built (restored when the "pools in this city" choice is cleared);
 * - mapsSearchUrl: base URL of the "Search Maps" link.
 *
 * == Targets ==
 * - copySource: sibling session select (only the sessions rendered on the page); copyFeedback: "copied" / "nothing
 *   copied" text; poolChoice: "existing pools in the selected city" select;
 *   mapsLink: the "Search Maps" link.
 *
 * == Actions ==
 * - populateFromExisting (change on the DB session select); copyFromSibling (click); selectPool (change on
 *   poolChoice); refreshMapsLink (change on pool name / address / city name); cityIdChanged (change on the
 *   city id field); stop (click on the delete button: the card header toggles the collapse).
 */
export default class extends Controller {
  static targets = ['copySource', 'copyFeedback', 'poolChoice', 'mapsLink']

  static values = {
    index: Number,
    existingSessions: { type: Array, default: [] },
    baseline: { type: Object, default: {} },
    mapsSearchUrl: { type: String, default: 'https://www.google.com/maps/search/' },
    copiedLabel: { type: String, default: 'Copied.' },
    copyMissingLabel: { type: String, default: 'Nothing copied.' }
  }

  stop (event) {
    event.stopPropagation()
  }

  populateFromExisting (event) {
    const sessionId = event.currentTarget.value
    if (!present(sessionId)) return

    const session = this.existingSessionsValue.find((row) => String(row.id) === String(sessionId))
    if (!session) return

    const prefix = `session_${this.indexValue}_`
    if (session.description) setFieldValue(`${prefix}description`, session.description, false)
    if (session.session_order) setFieldValue(`${prefix}order`, session.session_order, false)
    if (session.scheduled_date) setFieldValue(`${prefix}scheduled_date`, session.scheduled_date, false)
    if (session.day_part_type_id) setFieldValue(`${prefix}day_part_type_id`, session.day_part_type_id, false)
    if (session.swimming_pool_id && document.getElementById(this.poolId('swimming_pool_id'))) {
      setFieldValue(this.poolId('swimming_pool_id'), session.swimming_pool_id, true)
      this.rehydratePoolAndCity(session.swimming_pool_id)
    }
  }

  // Copies the pool and city fields (unsaved edits included) of the chosen sibling card, silently: a 'change' on the
  // id fields would start DB rehydrations clobbering the copied values. Only the fields refreshing the maps link fire.
  copyFromSibling (event) {
    const sourceIndex = this.hasCopySourceTarget ? this.copySourceTarget.value : ''
    event?.currentTarget?.blur()
    // (the source card must be on the page: its fields are what gets copied)
    if (!present(sourceIndex) || String(sourceIndex) === String(this.indexValue) || !document.getElementById(`pool_${sourceIndex}_name`)) {
      return this.copyFeedback(this.copyMissingLabelValue, 'text-danger')
    }

    COPIED_POOL_FIELDS.forEach((field) => copyFieldValue(`pool_${sourceIndex}_${field}`, this.poolId(field)))
    COPIED_CITY_FIELDS.forEach((field) => copyFieldValue(`city_${sourceIndex}_${field}`, this.cityId(field)))
    copyFieldValue(`search_pool_${sourceIndex}`, `search_pool_${this.indexValue}`)
    const mapsFields = [this.poolId('name'), this.poolId('address'), this.cityId('name')]
    mapsFields.forEach((fieldId) => dispatchChange(fieldId))
    this.copyFeedback(this.copiedLabelValue, 'text-success')
  }

  copyFeedback (text, cssClass) {
    if (!this.hasCopyFeedbackTarget) return

    this.copyFeedbackTarget.textContent = text
    this.copyFeedbackTarget.className = `small ${cssClass}`
  }

  selectPool (event) {
    const poolId = event.currentTarget.value
    if (present(poolId)) {
      setFieldValue(this.poolId('swimming_pool_id'), poolId, true)
      this.rehydratePoolAndCity(poolId)
    } else {
      this.resetToBaseline()
    }
  }

  refreshMapsLink () {
    if (!this.hasMapsLinkTarget) return

    const query = [fieldValue(this.poolId('name')), fieldValue(this.poolId('address')), fieldValue(this.cityId('name'))]
      .map((part) => part || '').join(', ')
    this.mapsLinkTarget.href = `${this.mapsSearchUrlValue}?q=${encodeURIComponent(query)}`
  }

  cityIdChanged (event) {
    const cityId = event.currentTarget.value
    if (!present(cityId)) return this.clearCityFields()

    const context = this.autocompleteContext()
    if (!context) return

    fetchEntityDetails(context.baseApiUrl, 'city', cityId, context.jwt)
      .then((city) => this.applyCity(city))
  }

  // --- Internals ---

  poolId (field) { return `pool_${this.indexValue}_${field}` }
  cityId (field) { return `city_${this.indexValue}_${field}` }

  async rehydratePoolAndCity (poolId) {
    if (!present(poolId)) return this.clearCityFields()

    const context = this.autocompleteContext()
    if (!context) return

    const pool = await fetchEntityDetails(context.baseApiUrl, 'swimming_pool', poolId, context.jwt)
    if (!pool) return

    setFieldValue(this.poolId('id_field'), pool.id, false)
    setFieldValue(this.poolId('swimming_pool_id'), pool.id, false)
    POOL_FIELDS.forEach((field) => setFieldValue(this.poolId(field), pool[field]))
    if (!pool.city_id) return this.clearCityFields()

    const city = await fetchEntityDetails(context.baseApiUrl, 'city', pool.city_id, context.jwt)
    this.applyCity(city)
  }

  applyCity (city) {
    if (!city) return this.clearCityFields()

    setFieldValue(this.cityId('id_field'), city.id, false)
    setFieldValue(this.cityId('city_id'), city.id, false)
    CITY_FIELDS.forEach((field) => setFieldValue(this.cityId(field), city[field]))
  }

  clearCityFields () {
    setFieldValue(this.cityId('id_field'), '', false)
    setFieldValue(this.cityId('city_id'), '', false)
    CITY_FIELDS.forEach((field) => setFieldValue(this.cityId(field), ''))
  }

  resetToBaseline () {
    const baseline = this.baselineValue || {}
    const index = this.indexValue
    setFieldValue(this.poolId('id_field'), baseline.id, false)
    setFieldValue(this.poolId('swimming_pool_id'), baseline.id, false)
    setFieldValue(`pool[${index}]`, baseline.id, false)
    POOL_FIELDS.forEach((field) => setFieldValue(this.poolId(field), baseline[field], false))

    setFieldValue(this.cityId('id_field'), baseline.city_id, false)
    setFieldValue(this.cityId('city_id'), baseline.city_id, false)
    setFieldValue(`city[${index}]`, baseline.city_id, false)
    CITY_FIELDS.forEach((field) => setFieldValue(this.cityId(field), baseline[`city_${field}`], false))
  }

  // API URL and JWT of the pool LegacyAutoComplete widget of this card (null when missing).
  autocompleteContext () {
    const poolIdField = document.getElementById(this.poolId('swimming_pool_id'))
    const container = poolIdField?.closest('[data-controller~="legacy-autocomplete"]')
    if (!container) return null

    const baseApiUrl = container.dataset.legacyAutocompleteBaseApiUrlValue
    const jwt = container.dataset.legacyAutocompleteJwtValue
    return baseApiUrl && jwt ? { baseApiUrl, jwt } : null
  }
}
