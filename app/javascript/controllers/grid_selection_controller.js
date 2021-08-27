import { Controller } from 'stimulus'

/**
 * = grid-selection - StimulusJS controller =
 *
 * Wrapper for JS methods used for multi-row selection in DataGrids.
 *
 * == Targets ==
 * @param {String} 'data-grid-selection-target': 'form'
 *                 DOM ID of the target form (target for this controller instance)
 *                 The target form should contain the submit button used by the action.
 *
 * @param {String} 'data-grid-selection-target': 'payload'
 *                 DOM hidden field containing the actual payload for the form post
 *
 *
 * == Values ==
 * Uses simple 'data' attributes:
 * @param {String} 'data-grid-selection-confirm' => confirmation message before action
 *
 * == Actions:
 * - postSelection => will yield all selected IDs in the Datagrid (using
 *                    selection checkboxes) as payload for the target action button.
 *
 * == Assumptions:
 * - The Datagrid must contain a #selection_column, with a checkbox using the 'grid-selector' style.
 * - Each checkbox should contain the row ID as value.
 * - All selected checkboxes in the page having the same style will be considered as a valid selection.
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['form', 'payload']

  // DEBUG
  /**
   * Setup invoked each time the controller instance connects.
   */
  // connect() {
  //   console.log('connect()')
  //   if (this.hasFormTarget && this.hasPayloadTarget) {
  //     console.log('All targets found.')
  //   }
  // }

  /**
   * Calls Submit on the associated form, updating the list of selected row IDs
   * as hidden payload. Does nothing if the selection is empty.
   */
  handlePost(event) {
    // DEBUG
    // console.log('handlePost() action')
    event.preventDefault()
    // Collect payload: (assumes each checkbox value is set with row ID)
    const idList = $("input[type='checkbox'].grid-selector:checked")
      .toArray()
      .map((node) => { return node.value })

    if (idList.length > 0 && confirm(this.data.get('confirm')) && this.hasFormTarget && this.hasPayloadTarget) {
      $(this.payloadTarget).val(idList)
      // Post data (with hidden payload):
      $(this.formTarget).trigger('submit')
      return true
    }
    return false
  }
  // ---------------------------------------------------------------------------
}
