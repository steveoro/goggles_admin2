import { Controller } from 'stimulus'

/**
 * = grid-edit - StimulusJS controller =
 *
 * Wrapper for JS methods used for single row edit in DataGrids.
 *
 * == Targets ==
 * (none so far)
 *
 * == Values ==
 * (Put values directly on controller elements)
 * @param {String} 'data-grid-edit-modal-id-value':
 *                 DOM ID of the modal target;
 *                 the modal will be filled-in with the values provided as payload.
 *
 * @param {String} 'data-grid-edit-url-value':
 *                 URL string for the update PUT action.
 *
 * @param {String} 'data-grid-edit-modal-edit-title-value':
 *                 string title for the edit modal dialog when the edit mode is set
 *                 (if the payload['id'] is *NOT* null).
 *
 * @param {String} 'data-grid-edit-modal-create-title-value':
 *                 string title for the edit modal dialog when the create mode is set
 *                 (if the payload['id'] is null).
 *
 * @param {Array} 'data-grid-edit-payload-value' (required)
 *                 JSON-ified ActiveRecord model instance of the row that has to be edited.
 *                 (Basically, an object map of keys mapped to values; each key will be editable,
 *                  except the 'id', if given)
 *
 * == Actions:
 * - handleEdit => fill the target modal form and display it.
 *
 * == Assumptions:
 * - #frm-modal-edit
 *   => DOM ID of the internal Form target of the "Grid Edit modal".
 *
 * - #frm-modal-edit-appendable
 *   => DOM ID of the container for the dynamic form fields;
 *   the input fields (& labels) will be generated according to the attributes in the payload.
 *
 * - #btn-submit-save
 *   => Submit button for saving the edits made using the internal Form.
 *
 * - #grid-edit-modal-title
 *   => actual DOM ID of the localized title for the modal window.
 *
 * @author Steve A.
 */
export default class extends Controller {
  static values = {
    modalId: String,
    url: String,
    modalEditTitle: String,
    modalCreateTitle: String,
    payload: Object
  }

  // DEBUG
  /**
   * Setup invoked each time the controller instance connects.
   */
  // connect() {
  //   console.log('connect()')
  //   if (this.hasModalIdValue && this.hasUrlValue && this.hasPayloadValue) {
  //     console.log('All values found.')
  //   }
  // }

  /**
   * Calls Submit on the associated form, updating the list of selected row IDs
   * as hidden payload.
   */
  handleEdit(event) {
    // DEBUG
    // console.log('handleEdit() action')
    event.preventDefault()

    if (this.hasModalIdValue && this.hasUrlValue && this.hasPayloadValue) {
      // DEBUG
      // console.log('urlValue:')
      // console.log(this.urlValue)

      // Fix defaults for modal: (title, hidden _method & submit button method)
      if (this.payloadValue['id'] == null) {
        $('#grid-edit-modal-title').text(this.modalCreateTitleValue)
        $("#frm-modal-edit input[name='_method']").val('post')
        $('#btn-submit-save').attr('method', 'post')
      }
      else {
        $('#grid-edit-modal-title').text(this.modalEditTitleValue)
        $("#frm-modal-edit input[name='_method']").val('patch')
        $('#btn-submit-save').attr('method', 'put')
      }
      // Fix default form target:
      $('#frm-modal-edit').prop('action', this.urlValue)
      // Clear previous contents
      $('#frm-modal-edit-appendable').html('')

      // Make sure Turbolinks doesn't mess with the actual CSRF token of the form partial:
      if ($("#frm-modal-edit input[name='authenticity_token']").val() != $("meta[name='csrf-token']").prop('content')) {
        $("#frm-modal-edit input[name='authenticity_token']").val($("meta[name='csrf-token']").prop('content'))
      }

      Object.entries(this.payloadValue)
        .forEach(
          ([key, value]) => {
            $(`#${key}`).val(value)
          }
        )
      return true
    }
    return false
  }
  // ---------------------------------------------------------------------------
}
