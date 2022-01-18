import { Controller } from '@hotwired/stimulus'
import $ from 'jquery'

window.$ = window.jQuery = $
require('easy-autocomplete')

/**
 * = Easy-Autocomplete StimulusJS controller =
 *
 * @see http://www.easyautocomplete.com/
 *
 * == Targets ==
 * @param {String} 'data-autocomplete-target': 'field'
 *                 target field for the result value of the search; typically, a form field storing an ID value.
 *
 * @param {String} 'data-autocomplete-target': 'search'
 *                 target for the search field, where the user can enter the query text.
 *
 * @param {String} 'data-autocomplete-target': 'desc'
 *                 target for a static description, updated after each list item selection.
 *
 * == Values ==
 * (Put values directly on controller elements)
 * @param {String} 'data-autocomplete-base-dom-id-value'
 *                 defines the base string name for the DOM ID used by the modal container,
 *                 its input form (<tt>"frm-<BASE_MODAL_DOM_ID>"</tt>),
 *                 its title label (<tt>"<BASE_MODAL_DOM_ID>-modal-title"</tt>)
 *                 and its submit button (<tt>"btn-<BASE_MODAL_DOM_ID>-submit-save"</tt>);
 *                 default: "grid-edit"
 *
 * @param {String} 'data-autocomplete-base-api-url-value'
 *                 base API URL for data request (w/o endpoint or params)
 *
 * @param {String} 'data-autocomplete-detail-endpoint-value'
 *                 API endpoint name used to retrieve additional or initial Entity details;
 *                 this can be left unset if the additional detail retrieval API call doesn't need to be done,
 *                 as it is the case with lookup entities, which only have a code and no stored description.
 *                 (i.e.: model 'SwimmingPool' => detail API: 'swimming_pool' => resulting endpoint: '<baseApiUrlValue>/swimming_pool/<ID>')
 *
 * @param {String} 'data-autocomplete-search-endpoint-value'
 *                 API endpoint name for the actual autocomplete search
 *                 (i.e.: model 'User' => search API: 'users' => resulting endpoint: '<baseApiUrlValue>/users?<SEARCH_QUERY>')
 *
 * @param {String} 'data-autocomplete-search-column-value'
 *                 query field name used in the API search call; defaults to 'name'
 *
 * @param {String} 'data-autocomplete-search2-column-value'
 *                 secondary filter/query field name used in the API search call;
 *                 this affects only the list filtering for the search endpoint (can be used to better refine the rows found);
 *                 defaults to null
 *
 * @param {String} 'data-autocomplete-search2-dom-id-value'
 *                 DOM ID for the secondary search field value; the referred node should contain the secondary filter/query value,
 *                 if the search2 column is defined (defaults to null).
 *
 * @param {String} 'data-autocomplete-label-column-value'
 *                 field name used to retrieve additional label/description for the results; defaults to 'description';
 *                 this is also used to compose the label description stored into 'descTarget'.
 *
 * @param {String} 'data-autocomplete-label2-column-value'
 *                 secondary field name used as additional description (#2) appended to the above;
 *                 (totally optional, skipped when not set)
 *
 * @param {String} 'data-autocomplete-jwt-value'
 *                 current_user.jwt (assumes 'current_user' is currently logged-in and valid)
 *
 * == Actions:
 * (no actions, just setup)
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['field', 'search', 'desc']
  static values = {
    baseDomId: String,
    baseApiUrl: String,
    detailEndpoint: String,
    searchEndpoint: String, searchColumn: String,
    search2Column: String, search2DomId: String,
    labelColumn: String, label2Column: String,
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
      this.refreshWidgetSetup()
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
  computeLabelDescription(context, entityRow) {
    if (entityRow) {
      const labelColumnName = context.labelColumnValue || 'description'
      const label2ColumnName = context.label2ColumnValue || false
      var additionalDesc = label2ColumnName ? ` (${label2ColumnName}: ${entityRow[label2ColumnName]})` : ''
      return `${labelColumnName}: ${entityRow[labelColumnName]}${additionalDesc}`
    }
    else {
      return ''
    }
  }

  /**
   * Updates fieldTarget & descTarget using the specified entity row details.
   *
   * @param {Object} entityRow the object storing the row details
   */
  updateFieldAndDesc(entityRow) {
    // DEBUG
    // console.log('updateFieldAndDesc(): entityRow:', entityRow)
    if (this.hasFieldTarget) {
      var descValue = this.computeLabelDescription(this, entityRow)
      // DEBUG
      // console.log(`computed description = "${descValue}"`)
      $(this.fieldTarget).val(entityRow.id)
      if (this.hasDescTarget) {
        $(this.descTarget).html(`<b>${entityRow[this.searchColumnValue || 'name']}</b> - ${descValue}`);
      }
    }
    else {
      // DEBUG
      console.log('updateFieldAndDesc: no fieldTarget found.')
    }
  }

  /**
   * Retrieves the specified entity details as an Object and updates 2 target nodes (value and description).
   *
   * @param {String} detailEndpointName the entity detail endpoint name
   * @param {String} entityId the desired row ID
   * @returns the 'fetch' Promise that resolves to the an object mapping all entity row details
   */
  fetchAndUpdateDetails(detailEndpointName, entityId) {
    // DEBUG
    // console.log(`fetchAndUpdateDetails(${detailEndpointName}, ${entityId})`)

    if (this.hasBaseApiUrlValue && this.hasJwtValue && entityId) {
      $.ajax({
        method: 'GET',
        dataType: 'json',
        headers: { 'Authorization': `Bearer ${this.jwtValue}` },
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
   * Sets up the autocomplete widget for dynamic data retrieval using the set JWT value.
   */
  refreshWidgetSetup() {
    // DEBUG
    // console.log('autocomplete: refreshWidgetSetup()')
    if (this.hasBaseApiUrlValue && this.hasJwtValue) {
      const jwt = this.jwtValue
      const computeDesc = this.computeLabelDescription
      const searchTargetDomId = `#${this.searchTarget.id}`
      const fieldTargetDomId = `#${this.fieldTarget.id}`
      // DEBUG
      // console.log("searchTargetDomId:", searchTargetDomId)
      // console.log("fieldTargetDomId:", fieldTargetDomId)

      // Search => field + desc update
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
          headers: { 'Authorization': `Bearer ${jwt}` },
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
        getValue: this.searchColumnValue || 'name',
        template: {
          type: 'custom',
          method: (value, entityRow) => {
            var descValue = computeDesc(this, entityRow)
            return `${value} - <small class="text-muted">${descValue}</small>`
          }
        },
        list: {
          match: { enabled: true },
          maxNumberOfElements: 8,
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

        theme: "round"
      });

      // Field => search + desc update
      $(fieldTargetDomId).on('change', (_eventObject) => {
        // DEBUG
        // console.log('refreshWidgetSetup(): before fetchAndUpdateDetails')

        // Skip detail retrieval if detail endpoint is not set:
        if (this.hasDetailEndpointValue) {
          this.fetchAndUpdateDetails(this.detailEndpointValue, $(fieldTargetDomId).val())
        }
        else {
          // DEBUG
          // console.log('refreshWidgetSetup(): no detailEndpointValue')
        }
      })
    }
  }
  // ---------------------------------------------------------------------------
}
