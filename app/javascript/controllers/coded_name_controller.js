import { Controller } from '@hotwired/stimulus'
import $ from 'jquery'

/**
 * = CodedName 'internal API' StimulusJS controller =
 *
 * ==> NOT CURRENTLY USED by Goggles Main (Admin2-specific) <==
 *
 * Allows to retrieve the computed value of a specific "coded name", either Meeting's 'code'
 * or SwimmingPool's 'nick_name', and set it as suggested value for a text input field in a form.
 *
 * == Targets ==
 * @param {String} 'data-coded-name-target': 'field';
 *                 actual target for the computed result: the field will be set with the result value.
 *
 * @param {String} 'data-coded-name-target': 'name';
 *                 holds the 'name' parameter value for GogglesDb::Normalizer::CodedName.
 *
 * @param {String} 'data-coded-name-target': 'desc';
 *                 holds the 'description' parameter value for GogglesDb::Normalizer::CodedName.
 *
 * @param {String} 'data-coded-name-target': 'city';
 *                 holds the 'city_name' parameter value for GogglesDb::Normalizer::CodedName.
 *
 * @param {String} 'data-coded-name-target': 'pool';
 *                 holds the 'pool_type_code' parameter value for GogglesDb::Normalizer::CodedName.
 *
 * == Values ==
 * (Put values directly on controller elements)
 * @param {String} 'data-coded-name-result-type-value' (optional);
 *                 either 'code' (default) or 'nick_name' depending on the type
 *                 of the coded name target.
 *
 * @param {String} 'data-coded-name-jwt-value';
 *                 current_user.jwt (assumes 'current_user' is currently logged-in and valid)
 *
 * == Actions:
 * (no actions, just setup)
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['field', 'name', 'desc', 'city', 'pool']
  static values = { resultType: String, jwt: String }

  /**
   * Sets up the controller.
   * (Called whenever the controller instance connects to the DOM)
   */
  connect() {
    // DEBUG
    // console.log('coded_name_controller: connect()')
    if (this.hasFieldTarget && this.hasJwtValue) {
      // DEBUG
      // console.log('coded_name_controller: main target found.')

      if (this.hasNameTarget) {
        $(this.nameTarget).on('change', (_ev) => { this.fetchAndUpdateCodedName() })
      }
      if (this.hasDescTarget) {
        $(this.descTarget).on('change', (_ev) => { this.fetchAndUpdateCodedName() })
      }
      if (this.hasCityTarget) {
        $(this.cityTarget).on('change', (_ev) => { this.fetchAndUpdateCodedName() })
      }
      if (this.hasPoolTarget) {
        $(this.poolTarget).on('change', (_ev) => { this.fetchAndUpdateCodedName() })
      }
      // Dry run at start:
      this.fetchAndUpdateCodedName()
    }
  }
  // ---------------------------------------------------------------------------

  /**
   * Retrieves the coded name value using the internal API endpoint.
   */
  fetchAndUpdateCodedName() {
    // DEBUG
    // console.log(`fetchAndUpdateCodedName()`)
    const apiURL = '/data_fix/coded_name'

    if (this.hasJwtValue) {
      let dataParams
      if (this.resultTypeValue === 'nick_name') {
        // ** Request SwimmingPool#nick_name: **
        dataParams = {
          target: this.resultTypeValue,
          name: this.nameTarget.value,
          city_name: this.cityTarget.value,
          pool_type_code: this.poolTarget.value === '1' ? 25 : 50
        }
      } else {
        // ** Request Meeting#code **
        // Hack for out-of-parent, very nested, city fields for meetings:
        // if the target is not set directly, assume we have a nested meeting session
        // form for which we can rely to get a possible city name (only the first session
        // is looked for):
        let cityName = this.hasCityTarget ? this.cityTarget.value : $('#city_0_name').val()
        dataParams = {
          target: this.resultTypeValue,
          description: this.descTarget.value,
          city_name: cityName
        }
      }

      $.ajax({
        method: 'GET',
        dataType: 'json',
        headers: { Authorization: `Bearer ${this.jwtValue}` },
        url: apiURL,
        data: dataParams,
        error: (_xhr, _textStatus, errorThrown) => {
          if (errorThrown === 'Unauthorized') {
            // Force user sign-in & local JWT refresh on JWT expiration:
            document.location.reload()
          } else if (errorThrown !== 'abort') {
            console.error(errorThrown)
          }
        },
        success: (result, _xhr, _textStatus) => {
          // DEBUG
          // console.log(result);
          this.fieldTarget.value = result[this.resultTypeValue]
        }
      })
    }
  }
  // ---------------------------------------------------------------------------
}
