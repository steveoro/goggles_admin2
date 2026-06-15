import { Controller } from '@hotwired/stimulus'
import TomSelect from 'tom-select'

/**
 * = StimulusJS generic Lookup controller =
 *
 * ==> CUSTOMIZED version for Admin2 <==
 * (doesn't need a local /api_session call to retrieve the JWT because of localhost usage)
 *
 * Prepares and manages a generic lookup combo-box for input selection.
 * Works with both remote sources and static arrays of options.
 *
 * For remote data sources, given an authenticated form (behind login, with valid CSRF token):
 * 1. sets a JWT for an API session
 * 2. makes async calls to retrieve lookup data from API endpoints
 * 3. auto-renews JWT on API request 'unauthorized' response
 *
 * Base widget: @see https://tom-select.js.org/
 *
 *
 * == Targets ==
 * @param {String} 'data-lookup-target': 'field'
 *                 the target for this controller instance: a lookup field combo-box;
 *                 query for the selection: any name or description part from the options
 *
 *
 * == Values ==
 * (Put values directly on controller elements)
 * @param {String} 'data-lookup-api-url-value'
 *                 base API URL for data request (w/o params);
 *                 when not set, AJAX setup will be skipped and html options will be used
 *
 * @param {String} 'data-lookup-placeholder-value'
 *                 localized help text for "Choose an option"
 *
 * @param {String} 'data-lookup-query-column-value'
 *                 query field name used in the API lookup call; defaults to 'name'
 *
 * @param {String} 'data-lookup-bound-query-value'
 *                 (API only) inbound additional query parameter field name (no default); when set (for example, as 'country_code'),
 *                 a field text with DOM ID = "<BASE_NAME>_<boundQuery>" will be accessed to retrieve an
 *                 additional (inbound) query parameter value. (In the example, a node with DOM ID = "<BASE_NAME>_country_code")
 *
 * @param {String} 'data-lookup-api-url2-value'
 *                 secondary base API URL for any additional data request (automated, w/o params except the current row ID);
 *                 allows a second API query for entity details after the first lookup,
 *                 using the base name value as target entity and the chosen ID value from the select2 widget as key;
 *                 turned off when not set.
 *
 * @param {Boolean} 'data-lookup-free-text-value'
 *                 enables free text input (the user can enter any text, not just the one matching the items in the value list);
 *                 when set to 'true' (or true by JS DOM attribute getter) it will enable the free 'tags' option of the Select2 widget,
 *                 which allows the user to input any free text that can be used or set as current selection. Disabled by default.
 *
 * @param {String} 'data-lookup-field-base-name-value'
 *                 base name for the DOM IDs used to access the actual fields that will store the
 *                 data values for a form POST (usually an hidden fields).
 *                 Default accessed fields tags will be:
 *                 - DOM ID = "<BASE_NAME>_id" => stores the ID value of the selected option
 *                 - DOM ID = "<BASE_NAME>_label" => stores the display text value of the selected option
 *                 - DOM ID = "<BASE_NAME>_<any other data-field>" => stores any additional data field stored into the selected option
 *                 (The additional data fields will be defined & accessed dynamically.)
 *
 * @param {String} 'data-lookup-jwt-value'
 *                 current_user.jwt (assumes 'current_user' is currently logged-in and valid)
 *
 * == Assumptions:
 * @assert the widget can use '.ts-wrapper' CSS to customize width
 * @assert 'data-lookup-target' must be the actual select element tom-select attaches to
 *
 * == About the 2nd API call feature:
 * By enabling the second API call, the current row ID is used as key for retrieving all row details, including most associated entities,
 * in a single multi-level nested JSON object with all its associated details.
 * (For example: SwimmingPool(current row ID), -> City, -> PoolType, ...)
 *
 * Relying mostly on entity association naming conventions and on the nested structure of the resulting JSON object, and by looking
 * for the presence of other coherently-named DOM widgets or fields, this controller will try to update their values
 * when the main target widget/field changes its values or its selection.
 *
 * For instance, when using correct naming & parameters in configuring this controller, a 'swimming_pool_select' widget could
 * update any of its related 'pool_type_select', 'city_select' or 'city_area' fields found on the same page.
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['field']
  static values = {
    placeholder: String,
    apiUrl: String,
    apiUrl2: String,
    queryColumn: String,
    boundQuery: String,
    freeText: Boolean,
    fieldBaseName: String,
    jwt: String
  }

  /**
   * Sets up the TomSelect widget used for the lookup-combo box to which this
   * controller instance connects.
   */
  connect () {
    if (this.hasFieldTarget) {
      this.refreshWidgetSetup()
    }
  }

  /**
   * Destroys the TomSelect instance on disconnect to avoid duplicate instances.
   */
  disconnect () {
    if (this._tomSelect) {
      this._tomSelect.destroy()
      this._tomSelect = null
    }
  }

  /**
   * Sets up the TomSelect widget either for dynamic data retrieval using the set JWT value
   * or for static data handling otherwise.
   */
  refreshWidgetSetup () {
    if (this._tomSelect) {
      this._tomSelect.destroy()
      this._tomSelect = null
    }
    if (this.hasApiUrlValue && this.hasJwtValue) {
      this.initTomSelectWidget(this.fieldTarget, this.jwtValue)
    } else {
      this.initTomSelectWidget(this.fieldTarget, null)
    }
  }

  /**
   * Retrieves the Promise for the additional entity details object.
   *
   * @param {String} jwt a valid JWT
   * @param {String} entityName the entity/endpoint name (snake-case)
   * @param {String} entityId the desired row ID
   * @returns the 'fetch' Promise that resolves to the an object mapping all entity row details
   */
  async fetchEntityDetails (jwt, entityName, entityId) {
    // DEBUG
    // console.log(`fetchEntityDetails('${entityName}', ${entityId})`)
    // Return an empty object if the secondary API endpoint is not defined:
    if (!this.hasApiUrl2Value) {
      return {}
    }

    return fetch(`${this.apiUrl2Value}/${entityName}/${entityId}`, {
      method: 'GET',
      mode: 'cors',
      headers: {
        Authorization: `Bearer ${jwt}`,
        'Content-type': 'application/json;charset=UTF-8'
      }
    }).then(resp => { return resp.json() })
      .catch(error => console.error('fetchEntityDetails error:', error))
  }

  // ---------------------------------------------------------------------------

  /**
   * Prepares (adjusts) the parameters for the outgoing API call.
   * @param {Object} params the base API query parameters as per Select2 API ('term', 'page')
   */
  prepareAPIPayload (params) {
    // NOTE: avoid pre-setting { select2_format: true } as a default to get always a more rich result dataset
    const queryParams = {}

    // Ask for the simplified select2_format just in special cases:
    if (this.hasFieldBaseNameValue && this.fieldBaseNameValue === 'team') {
      queryParams.select2_format = true
    }

    // Add an in-bound API query parameter, if specified:
    if (this.hasFieldBaseNameValue && this.hasBoundQueryValue && document.querySelector(`#${this.fieldBaseNameValue}_${this.boundQueryValue}`)) {
      queryParams[this.boundQueryValue] = document.querySelector(`#${this.fieldBaseNameValue}_${this.boundQueryValue}`).value
    }

    // Finalize API parameters:
    // - 'term': actual query term
    // - 'page': support for infinite scrolling
    // - 'select2_format': ignored by the API if the endpoint doesn't implement it
    if (this.hasQueryColumnValue) {
      // Bespoke query term:
      queryParams[this.queryColumnValue] = params.term
    } else {
      // Default query term ('name'):
      queryParams.name = params.term
    }
    queryParams.page = params.page
    return queryParams
  }
  // ---------------------------------------------------------------------------

  /**
   * Parses the API result data into the TomSelect options format.
   * @param {Array|Object} data resulting array of data objects from the API
   * @returns {Array} array of { value, text, ...extra } objects for TomSelect
   */
  parseAPIResults (data) {
    const rows = data.results || data
    return rows.map((row) => {
      if (row.complete_name && row.year_of_birth) {
        const r = this.setDataMembersForSwimmer(row)
        return { value: String(r.id), text: r.text, ...r }
      }
      if (row.pool_type_id && row.name) {
        const r = this.setDataMembersForSwimmingPool(row)
        return { value: String(r.id), text: r.text, ...r }
      }
      if (row.code && row.description && row.header_date && row.header_year && row.edition) {
        const r = this.setDataMembersForMeetings(row)
        return { value: String(r.id), text: r.text, ...r }
      }
      if ((row.region || row.area) && row.name) {
        return { value: String(row.id), text: row.name, area: row.region || row.area }
      }
      if (row.long_label) { return { value: String(row.id), text: row.long_label } }
      if (row.label) { return { value: String(row.id), text: row.label } }
      return { value: String(row.id), text: row.text || row.name || String(row.id) }
    })
  }
  // ---------------------------------------------------------------------------

  /**
   * Returns the usual text label used for displaying a row of the specified entityName.
   * @param {String} entityName a snake_case name of the key entity
   * @param {Object} resultRow  the result object holding the entity attributes
   */
  getLabelForEntity (entityName, resultRow) {
    if (entityName === 'swimmer') {
      return `${resultRow.complete_name} (${resultRow.year_of_birth})`
    }
    if (entityName === 'swimming_pool') {
      return `${resultRow.name} (${resultRow.nick_name})`
    }
    if (entityName === 'meeting' || entityName === 'user_workshop') {
      return `${resultRow.description} (${resultRow.header_date})`
    }
    // Defaults, in priority order:
    return resultRow.label || resultRow.name || resultRow.description
  }

  /**
   * Returns an object with all the custom 'data' members for a Swimmer option lookup,
   * plus the obligatory id key & text label for display.
   * @param {Object} resultRow result object holding Swimmer detailed data fields
   */
  setDataMembersForSwimmer (resultRow) {
    return {
      id: resultRow.id,
      complete_name: resultRow.complete_name,
      first_name: resultRow.first_name,
      last_name: resultRow.last_name,
      year_of_birth: resultRow.year_of_birth,
      gender_type_id: resultRow.gender_type_id,
      text: this.getLabelForEntity('swimmer', resultRow)
    }
  }

  /**
   * Returns an object with all the custom 'data' members for a SwimmingPool option lookup,
   * plus the obligatory id key & text label for display.
   * @param {Object} resultRow result data object holding SwimmingPool detailed data fields
   */
  setDataMembersForSwimmingPool (resultRow) {
    return {
      id: resultRow.id,
      name: resultRow.name,
      nick_name: resultRow.nick_name,
      city_id: resultRow.city_id,
      pool_type_id: resultRow.pool_type_id,
      text: this.getLabelForEntity('swimming_pool', resultRow)
    }
  }

  /**
   * Returns an object with all the custom 'data' members for a Meeting/UserWorkshop option lookup,
   * plus the obligatory id key & text label for display.
   * @param {Object} resultRow result data object holding Meeting/UserWorkshop detailed data fields
   */
  setDataMembersForMeetings (resultRow) {
    return {
      id: resultRow.id,
      code: resultRow.code,
      description: resultRow.description,
      header_date: resultRow.header_date,
      header_year: resultRow.header_year,
      edition: resultRow.edition,
      edition_type_id: resultRow.edition_type_id,
      season_id: resultRow.season_id,
      swimming_pool_id: resultRow.swimming_pool_id,
      team_id: resultRow.team_id,
      timing_type_id: resultRow.timing_type_id,
      text: this.getLabelForEntity('meeting', resultRow)
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Returns a new Map extracted from the current TomSelect selection.
   * @param {TomSelect} ts the TomSelect instance
   */
  prepareMapDataFromCurrentSelection (ts) {
    const mapData = new Map()
    if (!ts || !ts.getValue()) return mapData
    const selectedValue = ts.getValue()
    const item = ts.options[selectedValue]
    if (!item) return mapData
    mapData.set('id', selectedValue)
    mapData.set('label', item.text || '')
    Object.entries(item).forEach(([k, v]) => {
      if (k !== 'value' && k !== 'text') mapData.set(k, v)
    })
    return mapData
  }
  // ---------------------------------------------------------------------------

  /**
   * Copies all attributes of a specified Object into a Map of key attributes and values.
   * The method skips certain attributes which may be found when dealing with internal data objects
   * from the Select2 widget.
   * Both object and destMap are assumed to be existing and defined.
   *
   * @param {Object} object   an Object with data properties
   * @param {Map}    destMap  the destination data Map
   * @returns the converted/enriched Map object data
   */
  copyObjectToMap (object, destMap) {
    if (object && destMap) {
      Object.entries(object)
        .forEach(
          ([key, value]) => {
            // Skip peculiar attributes:
            if (key !== 'text' && key !== 'selected' && key !== 'select2Id') {
              destMap.set(key, value)
            }
          }
        )
    }
    return destMap
  }

  /**
   * Sets the text color of the span text identified by '#<BASE_NAME>-presence'.
   * @param {String}  baseName base name for the presence indicator.
   * @param {boolean} hasLabel true sets the flag span text to green; red (default) otherwise.
   */
  presenceLedUpdate (baseName, hasLabel) {
    if (document.querySelector(`#${baseName}-presence`)) {
      // Make sure the "status led" is green when there's a selection and vice-versa:
      // Given that setHiddenFieldsValue() may be invoked twice on some occasions,
      // we'll do an explicit check instead of relying on the simple outcome of toggleClass():
      const element = document.querySelector(`#${baseName}-presence`)
      if (hasLabel) {
        element.classList.add('text-success')
        element.classList.remove('text-danger')
      } else {
        element.classList.add('text-danger')
        element.classList.remove('text-success')
      }
    }
  }

  /**
   * Sets the visibility of the span text identified by '#<BASE_NAME>-new'.
   * @param {String}  baseName base name for the presence indicator.
   * @param {boolean} visible true/false to toggle the 'd-none' CSS class.
   */
  newLedUpdate(baseName, visible) {
    if (document.querySelector(`#${baseName}-new`)) {
      const element = document.querySelector(`#${baseName}-new`)
      if (visible) {
        element.classList.remove('d-none')
      } else {
        element.classList.add('d-none')
      }
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Setter for all the hidden fields stored in the lookup option data (id, label, ...).
   * (Does nothing if the data field is not found.)
   *
   * @param {String} baseName base name for the context of the provided data map and base prefix for
   *                          all the hidden fields;
   * @param {Object} mapData a Map including all attribute names and values that have to be
   *                         stored on hidden field tags having DOM IDs = "<BASE_NAME>_<ATTR_NAME>"
   *
   * == Example: ==
   *
   * mapData = { id: 1, label: "whatever", another_field: "anything", ... }
   *
   * - stores 1          as value of the DOM node having ID "<BASE_NAME>_id"
   * - stores "whatever" as value of the DOM node having ID "<BASE_NAME>_label"
   * - stores "anything" as value of the DOM node having ID "<BASE_NAME>_another_field"
   */
  setHiddenFieldsValue (baseName, mapData) {
    // DEBUG
    // console.log('setHiddenFieldsValue()')
    // console.log(mapData)

    if (baseName && mapData) {
      /*
       * Free-input text case handling => Input field value is "NEW" or unmatched in database
       * Clear the ID field if it's equal to the label.
       */
      if (mapData.get('id') === mapData.get('label')) {
        mapData.set('id', 0)
        this.newLedUpdate(baseName, true)

        // Peculiar cases:
        // 1. SwimmingPool: clear pre-existing values set by cookies when we're setting new records
        if (baseName.startsWith('swimming_pool') && mapData.get('label')) {
          document.querySelector('#swimming_pool_name').value = mapData.get('label')
          document.querySelector('#swimming_pool_nick_name').value = null
          document.querySelector('#swimming_pool_city_id').value = null
          document.querySelector('#swimming_pool_pool_type_id').value = null
        }
        // 1. Swimmer: update complete_name
        if (baseName.startsWith('swimmer') && mapData.get('label') && document.querySelector(`#${baseName}_complete_name`)) {
          document.querySelector(`#${baseName}_complete_name`).value = mapData.get('label')
        }
      }
      else {
        this.newLedUpdate(baseName, false) // Hide the "new" led/flag if there's a result match
      }

      // "Status led" update for the main data input:
      this.presenceLedUpdate(baseName, mapData.has('label'))
      const baseSelector = `#${baseName}_`

      // Set each hidden field tag value from data map only if the DOM node is found:
      mapData.forEach(
        (value, key) => {
          // If a kwy field is found (prefixed with base name), trigger all the related changes,
          // including any '<BASE_NAME><key>_select' value selects (which will work only on Select2
          // widget with pre-fixed list of options):
          if (document.querySelector(`${baseSelector}${key}`)) {
            // DEBUG
            // console.log(`Found DOM field for '${key}': [${baseSelector}${key}] <= ${value}`)
            document.querySelector(`${baseSelector}${key}`).value = value
            /*
             * Trigger a sub-entity change for in-bound select2 widgets.
             * (Updates only the linked sub-entity's hidden id & label)
             *
             * If the current field name ("key") ends with "_id" (as in 'swimming_pool_id', or 'city_id'),
             * then it's assumed to imply the Rails convention for an association column name.
             * Thus, we check if there's also a possible Select2 widget bound to this by a similar name,
             * and we update that too when found.
             *
             * The naming convention is:
             * - "key" ("<something>_id") DOM node for source value
             *   => "key-minus-id_select" ("<something>_select") DOM node for target change
             *
             * == Example ==
             * - key: "pool_type_id" => target select: "pool_type_select"
             */
            const boundSelectBaseName = key.split('_id')[0]
            const boundSelectID = `#${boundSelectBaseName}_select`

            // Process bound select widgets & hidden fields (but skip special cases handled elsewhere)
            if (key.endsWith('_id') && (key !== 'city_id') && document.querySelector(boundSelectID)) {
              this.setOrCreateSelect2Option(boundSelectBaseName, value, null)
            }
          }

          // If there's another Select2 widget with an DOM ID based on the current key and the current
          // value holds nested details, we can go deep with recursion and update its fields too:
          // (but skip special cases handled elsewhere)
          if (!key.endsWith('_id') && (key !== 'city') && document.querySelector(`#${key}_select`) && value.id) {
            // DEBUG
            console.log(`Nested data details w/ '#${key}_select' widget found: going deep...`)
            const nestedLabel = this.getLabelForEntity(key, value)
            this.setOrCreateSelect2Option(key, value.id, nestedLabel)
            const nestedMap = new Map()
            this.copyObjectToMap(value, nestedMap)
            nestedMap.set('label', nestedLabel)
            this.setHiddenFieldsValue(key, nestedMap)
          }
        }
      )

      this.handleSpecialCases(mapData)
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Selects a specific key value in a bound TomSelect widget.
   * Adds the option if not already present.
   *
   * @param {String} boundSelectBaseName  the DOM ID base name
   * @param {String} value the key value
   * @param {String} label the label text; if null, uses existing option text
   */
  setOrCreateTomSelectOption (boundSelectBaseName, value, label) {
    const boundSelectEl = document.querySelector(`#${boundSelectBaseName}_select`)
    if (!boundSelectEl) return
    const ts = boundSelectEl.tomselect
    if (!ts) return

    const strValue = String(value)
    if (!ts.options[strValue] && label) {
      ts.addOption({ value: strValue, text: label })
    }
    ts.setValue(strValue, true)

    // Set also the related hidden fields:
    const idEl = document.querySelector(`#${boundSelectBaseName}_id`)
    if (idEl) idEl.value = strValue
    const labelEl = document.querySelector(`#${boundSelectBaseName}_label`)
    if (labelEl) {
      const resolvedLabel = label || (ts.options[strValue] && ts.options[strValue].text) || ''
      labelEl.value = resolvedLabel
      this.presenceLedUpdate(boundSelectBaseName, resolvedLabel.length > 0)
    }
  }

  /**
   * Additional binding steps taken depending by specific field names that differ from the usual
   * ActiveRecord convention naming scheme ("<FIELD_NAME>_id" => "<FIELD_NAME>" association).
   *
   * Does a bunch domain-specific, quick & dirty update-triggering stuff in other bound widgets,
   * but only if the target DOM IDs are found and mapData contains any one among the following attribute keys:
   *
   * - year_of_birth => updates #category_type_select
   * - year_of_birth => updates #category_type_select
   * - (FUTUREDEV: add more here)
   *
   * @param {Object} mapData a Map including all attribute names for the current selection
   */
  handleSpecialCases (mapData) {
    /*
     * Special case #1:
     * - 'year_of_birth' => update 'category_type_select'
     * (selection dataset assumed to be already present)
     */
    if (mapData.get('year_of_birth') && document.querySelector('#category_type_select')) {
      const age = (new Date().getFullYear() - mapData.get('year_of_birth'))
      const code = Math.floor(age / 5) * 5
      const catTs = document.querySelector('#category_type_select').tomselect
      if (catTs) {
        const matchingOpt = Object.values(catTs.options).find(o => o.text && o.text.includes(`M${code}`))
        if (matchingOpt) {
          catTs.setValue(String(matchingOpt.value), true)
          const idEl = document.querySelector('#category_type_id')
          if (idEl) idEl.value = matchingOpt.value
          const lblEl = document.querySelector('#category_type_label')
          if (lblEl) lblEl.value = matchingOpt.text
        }
      }
    }
    /*
     * Special case #2:
     * - 'gender_type_id' => update 'gender_type_id' standard select_tag
     * (selection dataset assumed to be already present)
     */
    if (mapData.get('gender_type_id') && document.querySelector('#gender_type_id')) {
      const genderEl = document.querySelector('#gender_type_id')
      genderEl.value = mapData.get('gender_type_id')
      genderEl.dispatchEvent(new Event('change'))
    }

    /*
     * Special case #3: 'city_id' w/ city object => update 'city_select'
     * (selection dataset will be created if missing)
     */
    if (mapData.get('city_id') && mapData.get('city') && document.querySelector('#city_select')) {
      this.setOrCreateTomSelectOption('city', mapData.get('city_id'), mapData.get('city').name)
      const ccEl = document.querySelector('#city_country_code')
      if (ccEl) ccEl.value = mapData.get('city').country_code
      const areaEl = document.querySelector('#city_area')
      if (areaEl) areaEl.value = mapData.get('city').area
    }

    /*
     * Special case #4: 'pool_type_id' w/ PoolType object => update 'pool_type_select'
     * (selection dataset will be created if missing)
     */
    if (mapData.get('pool_type_id') && mapData.get('pool_type') && document.querySelector('#pool_type_select')) {
      const valueId = mapData.get('pool_type_id')
      const ptEl = document.querySelector('#pool_type_id')
      if (ptEl) { ptEl.value = valueId; ptEl.dispatchEvent(new Event('change')) }
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Enriches mapData with full entity details from the secondary API endpoint and then
   * updates all hidden fields.
   *
   * @param {String} jwt a valid JWT
   * @param {Object} mapData a Map including all attribute names for the current selection
   */
  async enrichMapDataWithDetails (jwt, mapData) {
    if (this.hasApiUrl2Value && this.hasFieldBaseNameValue && (mapData.get('id') > 0)) {
      return this.fetchEntityDetails(jwt, this.fieldBaseNameValue, mapData.get('id'))
        .then((json) => {
          json.label = mapData.get('label')
          this.copyObjectToMap(json, mapData)
          this.setHiddenFieldsValue(this.hasFieldBaseNameValue ? this.fieldBaseNameValue : '', mapData)
        })
    } else {
      this.setHiddenFieldsValue(this.hasFieldBaseNameValue ? this.fieldBaseNameValue : '', mapData)
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Initializes a TomSelect widget on the given target element.
   * Replaces the former initSelect2Widget.
   *
   * @param {HTMLElement} target  the <select> element
   * @param {String|null} jwt     current API JWT, or null for static data
   */
  initTomSelectWidget (target, jwt) {
    const self = this
    const currJWT = jwt
    const isRemote = this.hasApiUrlValue && currJWT

    const options = {
      placeholder: this.placeholderValue || '',
      create: this.freeTextValue,
      maxItems: 1,
      valueField: 'value',
      labelField: 'text',
      searchField: ['text'],
      // Persist the selection even when the search term doesn't match the displayed text:
      persist: false,
      // Remote load callback (only when apiUrl is set):
      load: isRemote ? (query, callback) => {
        if (query.length < 3) return callback()
        const params = new URLSearchParams(self.prepareAPIPayload({ term: query, page: 1 }))
        fetch(`${self.apiUrlValue}?${params}`, {
          method: 'GET',
          headers: {
            Authorization: `Bearer ${currJWT}`,
            'Content-Type': 'application/json'
          },
          credentials: 'same-origin'
        })
          .then(r => r.json())
          .then(data => callback(self.parseAPIResults(data)))
          .catch(() => {
            console.warn('Lookup API error; attempting JWT refresh...')
            self.refreshWidgetSetup()
            callback()
          })
      } : null,
      onItemAdd: (value, item) => {
        const ts = self._tomSelect
        if (!ts) return
        const opt = ts.options[value]
        if (!opt) return
        const mapData = new Map()
        mapData.set('id', value)
        mapData.set('label', opt.text || '')
        Object.entries(opt).forEach(([k, v]) => {
          if (k !== 'value' && k !== 'text') mapData.set(k, v)
        })
        self.enrichMapDataWithDetails(currJWT, mapData)
      }
    }

    this._tomSelect = new TomSelect(target, options)

    // Preset hidden fields if there is already a pre-selected value:
    const preSelected = this._tomSelect.getValue()
    if (preSelected) {
      const mapData = this.prepareMapDataFromCurrentSelection(this._tomSelect)
      this.setHiddenFieldsValue(this.hasFieldBaseNameValue ? this.fieldBaseNameValue : '', mapData)
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Also update the select2-style reference for bound sub-widgets.
   * Kept as a facade over setOrCreateTomSelectOption for backward compat.
   */
  setOrCreateSelect2Option (boundSelectBaseName, value, label) {
    this.setOrCreateTomSelectOption(boundSelectBaseName, value, label)
  }
  // ---------------------------------------------------------------------------
}
