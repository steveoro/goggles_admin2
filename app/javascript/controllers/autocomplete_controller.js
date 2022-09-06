import { Controller } from '@hotwired/stimulus'
import $ from 'jquery'

window.$ = window.jQuery = $
require('easy-autocomplete')

/**
 * = Easy-Autocomplete StimulusJS controller =
 *
 * ==> NOT CURRENTLY USED by Goggles Main (Admin2-specific) <==
 *
 * Allows to update values in up to 3 "+1" target fields, searched using a search field,
 * while updating also another external description field upon selection.
 *
 * Supports both in-line & remote data providers for the search.
 * If the remote search is enabled (by setting the base API URL value), a second optional
 * API call can be configured to retrieve all the detail fields using the currently selected entity ID.
 *
 * This controller assumes the search target field needs to be configured using the
 * Easy-Autocomplete library (which is a jQuery plugin).
 *
 * The 3rd additional update target can be set and referenced by either a proper target binding
 * or even just its DOM ID string (when it's present on the page but outside the scope of the parent
 * node of this controller).
 *
 * The 4th additional update target is assumed to be *only* "external" to the parent DOM node
 * referencing this controller: the only supported way to bind the target is to set
 * its DOM ID as a parameter, similarly to what can be done for the search target(s) or
 * the 3rd update field target explained above.
 *
 * For library documentation:
 * - @see http://www.easyautocomplete.com/
 *
 * For our in-house Select2-based approach:
 * - @see 'app/javascript/controllers/lookup_controller.js' (both in Main & Admin2)
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
 *                 DOM ID for the 4th optional update target field value; the referred DOM node is assumed to store
 *                 the update target column value (defaults to null).
 *                 Typically used only for binding together 2 different auto-complete components as in the case
 *                 of a SwimmingPool associated to a City (both should be searchable & storable).
 *
 * @param {String} 'data-autocomplete-target4-column-value' (optional)
 *                 field name used to get the value to update the optional 4th update target; defaults to null.
 *                 In the example of a SwimmingPool bound to a City, this would be (SwimmingPool's) 'city_id'.
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
 *
 * @param {String} 'data-autocomplete-jwt-value' (optional, not needed for inline data)
 *                 current_user.jwt (assumes 'current_user' is currently logged-in and valid)
 *
 * == Actions:
 * (no actions, just setup)
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
    payload: Array,
    jwt: String
  }

  /**
   * Sets up the controller.
   * (Called whenever the controller instance connects to the DOM)
   */
  connect () {
    // DEBUG
    // console.log('Connecting autocomplete_controller...')

    if (this.hasFieldTarget && this.hasSearchTarget) {
      // DEBUG
      // console.log('autocomplete_controller: targets found.')

      if (this.hasPayloadValue) {
        // DEBUG
        // console.log('autocomplete_controller => widgetSetupWithInlineData()')
        this.widgetSetupWithInlineData()
      } else if (this.hasBaseApiUrlValue && this.hasJwtValue) {
        this.widgetSetupWithRemoteData()
      }

      $(`#${this.fieldTarget.id}`).on('change', (_eventObject) => {
        this.processUpdate()
      })

      // Use any available default data in the main target & update the desc:
      this.processUpdate()
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Performs the update of all the target fields, depending on the kind of detail
   * method (either by API or by payload).
   *
   * Field details => search + desc update
   */
  processUpdate() {
    const fieldTargetDomId = `#${this.fieldTarget.id}`,
          searchTargetDomId = `#${this.searchTarget.id}`

    // Skip updates when no API detail endpoint or static payload are set:
    if (this.hasDetailEndpointValue) {
      this.fetchAndUpdateDetails(this.detailEndpointValue, $(fieldTargetDomId).val())
    }
    else if (this.hasPayloadValue) {
      // DEBUG
      // console.log('onchange(), with payload', payLoad)
      var targetValue = $(fieldTargetDomId).val()
      var row = this.payloadValue.find(element => element['id'] == targetValue)
      // (The hard-coded 'id' above is because that's a constant column for all data sources)

      // Manually update for the searchTarget if the ID (fieldTarget) is manually changed:
      if (row) {
        // Update description below search target & reset search box when done
        this.updateFieldAndDesc(row)
        $(searchTargetDomId).val('') // clear the search box
      }
    }
    // DEBUG
    // else {
    //   console.log('widgetSetup(): no detailEndpointValue or payloadValue')
    // }
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
  updateFieldAndDesc (entityRow) {
    // DEBUG
    // console.log('updateFieldAndDesc(): entityRow:', entityRow)
    if (this.hasFieldTarget && entityRow) {
      const descValue = this.computeLabelDescription(this, entityRow)
      // DEBUG
      // console.log(`computed description = "${descValue}"`)
      $(this.fieldTarget).val(entityRow.id)
      if (this.hasDescTarget) {
        $(this.descTarget).html(`<b>${entityRow[this.searchColumnValue || 'name']}</b> - ${descValue}`)
      }
      // Overwrite also the optional secondary filtering field (when set) with the new details:
      if (this.hasSearch2ColumnValue && this.hasSearch2DomIdValue) {
        $(`#${this.search2DomIdValue}`).val(entityRow[this.search2ColumnValue])
      }

      if (this.hasField2Target) {
        $(this.field2Target).val(entityRow[this.target2ColumnValue])
      }
      if (this.hasField3Target) {
        $(this.field3Target).val(entityRow[this.target3ColumnValue])
      }
      // Target3 alternative binding using just its DOM ID, when provided:
      if (this.hasTarget4DomIdValue && (this.target3DomIdValue.length > 0)) {
        // DEBUG
        // console.log('updateFieldAndDesc: external target3 found.')
        $(`#${this.target3DomIdValue}`).val(entityRow[this.target3ColumnValue])
        $(`#${this.target3DomIdValue}`).trigger('change')
      }
      // Target4 is considered to be only external to the parent node, so we access it
      // using its DOM ID instead of a controller reference:
      if (this.hasTarget4DomIdValue && (this.target4DomIdValue.length > 0) && this.hasTarget4ColumnValue) {
      // DEBUG
      // console.log('updateFieldAndDesc: external target4 found.')
        $(`#${this.target4DomIdValue}`).val(entityRow[this.target4ColumnValue])
        $(`#${this.target4DomIdValue}`).trigger('change')
      }
    } else {
      // DEBUG
      // console.log('updateFieldAndDesc: no main fieldTarget found or result entityRow null.')
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
    // DEBUG
    // console.log(`fetchAndUpdateDetails(${detailEndpointName}, ${entityId})`)

    if (this.hasBaseApiUrlValue && this.hasJwtValue && entityId) {
      $.ajax({
        method: 'GET',
        dataType: 'json',
        headers: { Authorization: `Bearer ${this.jwtValue}` },
        url: `${this.baseApiUrlValue}/${detailEndpointName}/${entityId}`,
        error: (_xhr, _textStatus, errorThrown) => {
          if (errorThrown === 'Unauthorized') {
            // Force user sign-in & local JWT refresh on JWT expiration:
            document.location.reload()
          } else if (errorThrown !== 'abort') {
            console.error(errorThrown)
          }
        },
        success: (entityRow, _xhr, _textStatus) => {
          // DEBUG
          // console.log(entityRow);
          this.updateFieldAndDesc(entityRow)
        }
      })
    }
    // DEBUG
    // else {
    //   console.warn('fetchAndUpdateDetails: missing baseApiUrlValue or jwtValue or entityId')
    // }
  }
  // ---------------------------------------------------------------------------

  /**
   * Sets up the autocomplete widget for inline data domain search.
   */
  widgetSetupWithInlineData () {
    // DEBUG
    // console.log('autocomplete: widgetSetupWithInlineData()')
    const computeDesc = this.computeLabelDescription
    const searchTargetDomId = `#${this.searchTarget.id}`
    const searchColumn = this.searchColumnValue
    // DEBUG
    // console.log("searchTargetDomId:", searchTargetDomId)
    // console.log("searchColumn:", searchColumn)

    $(searchTargetDomId).easyAutocomplete({
      data: this.payloadValue,
      getValue: searchColumn || 'name',
      template: {
        type: 'custom',
        method: (value, entityRow) => {
          const descValue = computeDesc(this, entityRow)
          return `${value} - <small class="text-muted">${descValue}</small>`
        }
      },
      list: {
        match: { enabled: true },
        maxNumberOfElements: 8,
        onSelectItemEvent: () => {
          // DEBUG
          console.log("onSelectItemEvent: activeElement ID:", document.activeElement.id)
          // DEBUG
          console.log("onSelectItemEvent: searchTargetDomId:", searchTargetDomId)
          this.updateFieldAndDesc($(searchTargetDomId).getSelectedItemData())
          $(searchTargetDomId).val('') // Reset search box when done
        },
        onHideListEvent: () => {
          // (no-op)
        }
      },
      theme: 'round'
    })
  }
  // ---------------------------------------------------------------------------

  /**
   * Sets up the autocomplete widget for dynamic data retrieval using the set JWT value.
   */
  widgetSetupWithRemoteData () {
    // DEBUG
    // console.log('autocomplete: widgetSetupWithRemoteData()')
    const jwt = this.jwtValue
    const computeDesc = this.computeLabelDescription
    const searchTargetDomId = `#${this.searchTarget.id}`
    const searchColumnValue = this.searchColumnValue
    // DEBUG
    // console.log("searchTargetDomId:", searchTargetDomId)

    $(searchTargetDomId).easyAutocomplete({
      url: (queryText) => {
        const baseQueryURI = `${this.baseApiUrlValue}/${this.searchEndpointValue}?${this.searchColumnValue}=${queryText}`
        const search2DomID = `#${this.search2DomIdValue}`
        // Fetch using a secondary filtering query (if present):
        if (this.hasSearch2ColumnValue && this.hasSearch2DomIdValue && $(search2DomID).val().length > 0) {
          return `${baseQueryURI}&${this.search2ColumnValue}=${$(search2DomID).val()}`
        }
        return baseQueryURI
      },
      ajaxSettings: {
        dataType: 'json',
        method: 'GET',
        delay: 250,
        headers: { Authorization: `Bearer ${jwt}` },
        // Handle JWT expiration:
        error: (_xhr, _textStatus, errorThrown) => {
          if (errorThrown === 'Unauthorized') {
            // Force user sign-in & local JWT refresh on JWT expiration:
            document.location.reload()
          } else if (errorThrown !== 'abort') {
            console.error(errorThrown)
          }
        }
      },
      getValue: searchColumnValue || 'name',
      // (element) => {
      //   // DEBUG
      //   console.log("getValue(element)")
      //   console.log("element => ", element[searchColumnValue || 'name'])
      //   return element[searchColumnValue || 'name']
      // },
      template: {
        type: 'custom',
        method: (value, entityRow) => {
          const descValue = computeDesc(this, entityRow)
          return `${value} - <small class="text-muted">${descValue}</small>`
        }
      },
      list: {
        match: { enabled: true },
        maxNumberOfElements: 10,
        // onLoadEvent: () => {
        //   // DEBUG
        //   // console.log("onLoadEvent", this)
        // },
        onSelectItemEvent: () => {
          // DEBUG
          // console.log("onSelectItemEvent: activeElement ID:", document.activeElement.id)
          // DEBUG
          // console.log("onSelectItemEvent: searchTargetDomId:", searchTargetDomId)
          this.updateFieldAndDesc($(searchTargetDomId).getSelectedItemData())
          $(searchTargetDomId).val('') // Reset search box when done
        },
        onHideListEvent: () => {
          // (no-op)
        }
      },
      theme: 'round'
    })
  }
  // ---------------------------------------------------------------------------
}
