import { Controller } from '@hotwired/stimulus'
import TomSelect from 'tom-select'

/**
 * = TomSelect-based Autocomplete StimulusJS controller =
 *
 * ==> Admin2-specific <==
 *
 * Allows to update values in up to 3 "+1" target fields, searched using a search field,
 * while updating also another external description field upon selection.
 *
 * Supports both in-line & remote data providers for the search.
 * If the remote search is enabled (by setting the base API URL value), a second optional
 * API call can be configured to retrieve all the detail fields using the currently selected entity ID.
 *
 * This controller uses TomSelect (replaces easyAutocomplete).
 *
 * The 3rd additional update target can be set and referenced by either a proper target binding
 * or even just its DOM ID string (when it's present on the page but outside the scope of the parent
 * node of this controller).
 *
 * Additional "external" targets (from "target4" to "target12") can be set using just a DOM ID and a
 * corresponding column name for the target value, similarly to the way the search target(s) or the 3rd update field target
 * can be also defined as explained above.
 *
 * For library documentation:
 * - @see https://tom-select.js.org/
 *
 * For our in-house TomSelect-based approach:
 * - @see 'app/javascript/controllers/lookup_controller.js' (Admin2)
 *
 * == Targets ==
 * @param {String} 'data-autocomplete-target': 'field'
 *                 target field for the result value of the search; typically, a form field storing an ID value:
 *
 *                 => targetField.val( searched & chosen row['id'] )
 *
 * @param {String} 'data-autocomplete-target': 'field2' (optional)
 *                 secondary target field for the result value of the search; as above, a form field storing an ID value.
 *                 Totally optional: skipped when not set (default: null).
 *                 Used as above for a secondary field that gets updated upon selection:
 *
 *                 => targetField2.val( searched & chosen row[target2Column value] )
 *
 * @param {String} 'data-autocomplete-target': 'field3' (optional)
 *                 tertiary target field for the result value of the search.
 *                 Totally optional: skipped when not set (default: null).
 *                 Used as above for a tertiary field that gets updated upon selection:
 *
 *                 => targetField3.val( searched & chosen row[target3Column value] )
 *
 * @param {String} 'data-autocomplete-target': 'search'
 *                 target for the easy-autocomplete search field, where the user can enter the query text.
 *
 * @param {String} 'data-autocomplete-target': 'desc'
 *                 target for a static description and an additional optional description (label2),
 *                 updated after each list item selection.
 *
 *                 => targetDesc.val( searched & chosen row[labelColumnValue (+ label2ColumnValue)] )
 *
 * == Values ==
 * (Put values directly on controller elements)
 * @param {String} 'data-autocomplete-base-api-url-value' (optional, not needed for inline data)
 *                 base API URL for data request (w/o endpoint or params).
 *                 Set this to null to disable *all* API requests and use the supplied data array of Objects as base domain
 *                 for the autocomplete search.
 *                 (Optional & skipped when not set -- but, when not set, requires the 'data-autocomplete-data-value'
 *                 attribute containing the Array of Objects that define the.)
 *
 * @param {String} 'data-autocomplete-detail-endpoint-value' (optional)
 *                 API endpoint name used to retrieve additional or initial Entity details;
 *                 Default: null.
 *                 Set this only if an additional AJAX API call is needed for detail retrieval.
 *                 For instance, in the case of Lookup Entities (which only have a code and no stored description),
 *                 no additional detail query is possible. For any other case, the detail endpoint should be set if needed.
 *                 (I.e.: model 'SwimmingPool' => detail API: 'swimming_pool' => resulting endpoint: '<baseApiUrlValue>/swimming_pool/<ID>')
 *
 * @param {String} 'data-autocomplete-search-endpoint-value' (optional, not needed for inline data)
 *                 API endpoint name for the actual autocomplete search
 *                 (i.e.: model 'User' => search API: 'users' => resulting endpoint: '<baseApiUrlValue>/users?<SEARCH_QUERY>')
 *
 * @param {String} 'data-autocomplete-search-column-value' (optional, default: 'name')
 *                 query field name used in the API search call; defaults to 'name'
 *
 * @param {String} 'data-autocomplete-search2-column-value' (optional)
 *                 secondary filter/query field name used in the API search call;
 *                 this affects only the list filtering for the search endpoint (can be used to better refine the rows found);
 *                 defaults to null
 *
 * @param {String} 'data-autocomplete-search2-dom-id-value' (optional)
 *                 DOM ID for the secondary search field value; the referred node should contain the secondary filter/query value,
 *                 if the search2 column is defined (defaults to null).
 *
 * @param {String} 'data-autocomplete-label-column-value' (optional, default: 'description')
 *                 field name used to retrieve additional label/description for the results;
 *                 this is also used to compose the label description stored into 'descTarget'.
 *
 * @param {String} 'data-autocomplete-label2-column-value' (optional)
 *                 additional field name used as description (#2) appended to the above;
 *                 (totally optional, skipped when not set)
 *
 * @param {String} 'data-autocomplete-target2-column-value' (optional)
 *                 column or property name used as to set the value of the secondary target field;
 *                 (totally optional, skipped when not set)
  *
 * @param {String} 'data-autocomplete-target3-dom-id-value' (optional)
 *                 DOM ID for the 4th optional update target field value; the referred DOM node is assumed to store
 *                 the update target column value (defaults to null).
 *                 Typically used only for binding together 2 different auto-complete components as in the case
 *                 of a SwimmingPool associated to a City (both should be searchable & storable).
*
 * @param {String} 'data-autocomplete-target3-column-value' (optional)
 *                 column or property name used as to set the value of the tertiary target field;
 *                 (totally optional, skipped when not set)
 *
 * @param {String} 'data-autocomplete-target4-dom-id-value' (optional)
 *                 DOM ID for the 4th "external" update target field value;
 *                 the referred DOM node is assumed to store the update target column value (defaults to null).
 *                 Typically used only for binding together 2 different auto-complete components as in the case
 *                 of a SwimmingPool associated to a City (both should be searchable & storable).
 *
 * @param {String} 'data-autocomplete-target4-column-value' (optional)
 *                 column name used to retrieve the target field value during auto-updates; defaults to null.
 *                 In the example of a SwimmingPool bound to a City, this would be (SwimmingPool's) 'city_id'.
 *
 * All target fields 4..12 work similarly: using a DOM ID plus a column name which points to
 * the value from the detailed result of the selection from the drop-down field.
 *
 * @param {Array} 'data-autocomplete-payload-value' (optional)
 *                 Array of objects specifying the inline data payload for the search domain.
 *
 *                 Each item in the payload Array shall at least respond to:
 *                 - <tt>'id'</tt> => unique identifier for the row;
 *                 - <tt>searchColumn.value</tt> as property name => main search property;
 *                 - <tt>labelColumn.value</tt> as property name => main label or description for the item.
 *
 *                 Optionally (if used in the setup):
 *                 - <tt>label2_column</tt> as property name => additional label for the item;
 *                 - <tt>target2Column.value</tt> as property name => field updating the secondary target;
 *                 - <tt>target3Column.value</tt> as property name => field updating the tertiary target;
 *                 (and so on, for all possible defined targets)
 *
 * @param {String} 'data-autocomplete-jwt-value' (optional, not needed for inline data)
 *                 current_user.jwt (assumes 'current_user' is currently logged-in and valid)
 *
 * == Actions:
 * To force an update of all the linked fields:
 *
 * - Edit fields should bind to: (for example)
 *    - 'change->autocomplete#processUpdate'
 *
 * - Any external "Search" button should bind to: (action: "<bind_string>")
 *    - 'autocomplete#processUpdate' => refreshes all linked fields with the results from any
 *                                      filled-in search criteria.
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['field', 'field2', 'field3', 'search', 'desc']
  static values = {
    baseDomId: String,
    baseApiUrl: String,
    detailEndpoint: String,
    searchEndpoint: String, searchColumn: String,
    search2DomId: String, search2Column: String,
    labelColumn: String, label2Column: String,
    target2Column: String,
    target3DomId: String, target3Column: String,
    target4DomId: String, target4Column: String,
    target5DomId: String, target5Column: String,
    target6DomId: String, target6Column: String,
    target7DomId: String, target7Column: String,
    target8DomId: String, target8Column: String,
    target9DomId: String, target9Column: String,
    target10DomId: String, target10Column: String,
    target11DomId: String, target11Column: String,
    target12DomId: String, target12Column: String,
    payload: Array,
    jwt: String
  }

  /**
   * Sets up the controller.
   * (Called whenever the controller instance connects to the DOM)
   */
  connect () {
    if (this.hasFieldTarget && this.hasSearchTarget) {
      if (this.hasPayloadValue) {
        this.widgetSetupWithInlineData()
      } else if (this.hasBaseApiUrlValue && this.hasJwtValue) {
        this.widgetSetupWithRemoteData()
      }

      this.fieldTarget.addEventListener('change', (_e) => {
        if ((this.fieldTarget.value || '').toString().trim().length === 0) {
          this.clearLinkedBindingTargetsExceptMain()
          return
        }
        this.processUpdate()
      })

      this.searchTarget.addEventListener('input', (_e) => {
        if ((this.searchTarget.value || '').trim().length === 0) {
          this.clearBindingTargetsOnSearchEmpty()
        }
      })
    }
  }

  disconnect () {
    if (this._tomSelect) {
      this._tomSelect.destroy()
      this._tomSelect = null
    }
  }
  // ---------------------------------------------------------------------------

  isBindingColumnName (columnName) {
    return columnName === 'id' || (columnName && columnName.endsWith('_id'))
  }

  clearTargetByDomIdIfBinding (domId, columnName) {
    if (!domId || !this.isBindingColumnName(columnName)) return
    const el = document.querySelector(`#${domId}`)
    if (el) { el.value = ''; el.dispatchEvent(new Event('change')) }
  }

  clearLinkedBindingTargetsExceptMain () {
    if (this.hasDescTarget) this.descTarget.innerHTML = ''

    if (this.hasField2Target && this.isBindingColumnName(this.target2ColumnValue)) {
      this.field2Target.value = ''
      this.field2Target.dispatchEvent(new Event('change'))
    }
    if (this.hasField3Target && this.isBindingColumnName(this.target3ColumnValue)) {
      this.field3Target.value = ''
      this.field3Target.dispatchEvent(new Event('change'))
    }
    this.clearTargetByDomIdIfBinding(this.target3DomIdValue, this.target3ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target4DomIdValue, this.target4ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target5DomIdValue, this.target5ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target6DomIdValue, this.target6ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target7DomIdValue, this.target7ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target8DomIdValue, this.target8ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target9DomIdValue, this.target9ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target10DomIdValue, this.target10ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target11DomIdValue, this.target11ColumnValue)
    this.clearTargetByDomIdIfBinding(this.target12DomIdValue, this.target12ColumnValue)
  }

  clearBindingTargetsOnSearchEmpty () {
    if (this.hasFieldTarget) {
      this.fieldTarget.value = ''
      this.fieldTarget.dispatchEvent(new Event('change'))
    }
    this.clearLinkedBindingTargetsExceptMain()
  }
  // ---------------------------------------------------------------------------

  /**
   * Performs the update of all the target fields, depending on the kind of detail
   * method (either by API or by payload).
   *
   * Field details => search + desc update
   */
  processUpdate() {
    const targetValue = this.fieldTarget.value
    if (this.hasDetailEndpointValue) {
      this.fetchAndUpdateDetails(this.detailEndpointValue, targetValue)
    } else if (this.hasPayloadValue) {
      const row = this.payloadValue.find(element => element['id'] == targetValue)
      if (row) {
        this.updateFieldAndDesc(row)
        this.searchTarget.value = ''
      }
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Computes a descriptive label for the specified row details.
   *
   * @param {Object} context the binding context
   * @param {Object} entityRow the object storing the row details
   *
   * @returns the computed label description using the specified entity row details when present;
   *          an empty string otherwise.
   */
  computeLabelDescription (context, entityRow) {
    if (entityRow) {
      const labelColumnName = context.labelColumnValue || 'description'
      const label2ColumnName = context.label2ColumnValue || false
      const additionalDesc = label2ColumnName ? ` (${label2ColumnName}: ${entityRow[label2ColumnName]})` : ''
      return `${labelColumnName}: ${entityRow[labelColumnName]}${additionalDesc}`
    } else {
      return ''
    }
  }

  /**
   * Updates fieldTarget(s) (1 + 2 || 3 || 4, when defined) & descTarget
   * using the specified entity row details.
   * The controller must have at least the default target associated for the update to start.
   *
   * @param {Object} entityRow the object storing the row details
   */
  setDomValue (domId, value) {
    const el = document.querySelector(`#${domId}`)
    if (el) { el.value = value; el.dispatchEvent(new Event('change')) }
  }

  updateFieldAndDesc (entityRow) {
    if (this.hasFieldTarget && entityRow) {
      const descValue = this.computeLabelDescription(this, entityRow)
      this.fieldTarget.value = entityRow.id
      if (this.hasDescTarget) {
        this.descTarget.innerHTML = `<b>${entityRow[this.searchColumnValue || 'name']}</b> - ${descValue}`
      }
      if (this.hasSearch2ColumnValue && this.hasSearch2DomIdValue) {
        this.setDomValue(this.search2DomIdValue, entityRow[this.search2ColumnValue])
      }
      if (this.hasField2Target) this.field2Target.value = entityRow[this.target2ColumnValue]
      if (this.hasField3Target) this.field3Target.value = entityRow[this.target3ColumnValue]
      if (this.hasTarget3DomIdValue && this.target3DomIdValue.length > 0) {
        this.setDomValue(this.target3DomIdValue, entityRow[this.target3ColumnValue])
      }
      const extTargets = [
        [this.target4DomIdValue, this.target4ColumnValue],
        [this.target5DomIdValue, this.target5ColumnValue],
        [this.target6DomIdValue, this.target6ColumnValue],
        [this.target7DomIdValue, this.target7ColumnValue],
        [this.target8DomIdValue, this.target8ColumnValue],
        [this.target9DomIdValue, this.target9ColumnValue],
        [this.target10DomIdValue, this.target10ColumnValue],
        [this.target11DomIdValue, this.target11ColumnValue],
        [this.target12DomIdValue, this.target12ColumnValue]
      ]
      extTargets.forEach(([domId, col]) => {
        if (domId && domId.length > 0 && col) this.setDomValue(domId, entityRow[col])
      })
    }
  }

  /**
   * Retrieves the specified entity details as an Object and updates 2 target nodes (value and description).
   *
   * @param {String} detailEndpointName the entity detail endpoint name
   * @param {String} entityId the desired row ID
   * @returns the 'fetch' Promise that resolves to the an object mapping all entity row details
   */
  fetchAndUpdateDetails (detailEndpointName, entityId) {
    if (this.hasBaseApiUrlValue && this.hasJwtValue && entityId) {
      fetch(`${this.baseApiUrlValue}/${detailEndpointName}/${entityId}`, {
        method: 'GET',
        headers: { Authorization: `Bearer ${this.jwtValue}`, 'Content-Type': 'application/json' },
        credentials: 'same-origin'
      })
        .then(r => {
          if (!r.ok) { if (r.status === 401) { document.location.reload() } return null }
          return r.json()
        })
        .then(entityRow => { if (entityRow) this.updateFieldAndDesc(entityRow) })
        .catch(err => console.error(err))
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Sets up the TomSelect widget for inline data domain search.
   */
  widgetSetupWithInlineData () {
    const searchColumn = this.searchColumnValue || 'name'
    const items = this.payloadValue.map(row => ({
      value: String(row.id),
      text: row[searchColumn] || String(row.id),
      _row: row
    }))

    this._tomSelect = new TomSelect(this.searchTarget, {
      options: items,
      valueField: 'value',
      labelField: 'text',
      searchField: ['text'],
      maxItems: 1,
      create: false,
      render: {
        option: (data, escape) => {
          const row = data._row || {}
          const descValue = this.computeLabelDescription(this, row)
          return `<div class="option">${escape(data.text)} - <small class="text-muted">${escape(descValue)}</small></div>`
        }
      },
      onItemAdd: (value) => {
        const opt = this._tomSelect.options[value]
        if (opt && opt._row) {
          this.updateFieldAndDesc(opt._row)
          this._tomSelect.clear(true)
          this._tomSelect.setTextboxValue('')
        }
      }
    })
  }
  // ---------------------------------------------------------------------------

  /**
   * Sets up the TomSelect widget for remote API data retrieval.
   */
  widgetSetupWithRemoteData () {
    const jwt = this.jwtValue
    const searchColumnValue = this.searchColumnValue || 'name'

    this._tomSelect = new TomSelect(this.searchTarget, {
      valueField: 'value',
      labelField: 'text',
      searchField: ['text'],
      maxItems: 1,
      create: false,
      load: (query, callback) => {
        if (!query || query.length < 2) return callback()
        const search2El = this.hasSearch2DomIdValue ? document.querySelector(`#${this.search2DomIdValue}`) : null
        let url = `${this.baseApiUrlValue}/${this.searchEndpointValue}?${searchColumnValue}=${encodeURIComponent(query)}`
        if (this.hasSearch2ColumnValue && search2El && search2El.value.length > 0) {
          url += `&${this.search2ColumnValue}=${encodeURIComponent(search2El.value)}`
        }
        fetch(url, {
          method: 'GET',
          headers: { Authorization: `Bearer ${jwt}`, 'Content-Type': 'application/json' },
          credentials: 'same-origin'
        })
          .then(r => {
            if (!r.ok) { if (r.status === 401) document.location.reload(); return [] }
            return r.json()
          })
          .then(data => {
            const rows = Array.isArray(data) ? data : (data.results || [])
            callback(rows.map(row => ({
              value: String(row.id),
              text: row[searchColumnValue] || String(row.id),
              _row: row
            })))
          })
          .catch(err => { console.error(err); callback() })
      },
      render: {
        option: (data, escape) => {
          const row = data._row || {}
          const descValue = this.computeLabelDescription(this, row)
          return `<div class="option">${escape(data.text)} - <small class="text-muted">${escape(descValue)}</small></div>`
        }
      },
      onItemAdd: (value) => {
        const opt = this._tomSelect.options[value]
        if (opt && opt._row) {
          this.updateFieldAndDesc(opt._row)
          this._tomSelect.clear(true)
          this._tomSelect.setTextboxValue('')
        }
      }
    })
  }
  // ---------------------------------------------------------------------------
}
