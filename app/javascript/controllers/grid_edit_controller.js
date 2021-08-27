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
 * (to be def.)
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
    console.log('handleEdit() action')
    event.preventDefault()

    if (this.hasModalIdValue && this.hasUrlValue && this.hasPayloadValue) {
      // DEBUG
      console.log('urlValue:')
      console.log(this.urlValue)

      // Fix default modal title: edit (ID set) |=> create (ID null)
      if (this.payloadValue['id'] == null) {
        $('#grid-edit-modal-title').text(this.modalCreateTitleValue)
      }
      else {
        $('#grid-edit-modal-title').text(this.modalEditTitleValue)
      }
      // Fix default form target:
      $('#frm-modal-edit').prop('action', this.urlValue)
      // Clear previous contents
      $('#frm-modal-edit-appendable').html('')

      Object.entries(this.payloadValue)
        .forEach(
          ([key, value]) => {
            // Dynamic partial for each line of attributes in the modal:
            if (key != 'lock_version') {
              var readOnly = (key == 'id' || key == 'created_at' || key == 'updated_at')
              var fieldClass = readOnly ? 'form-control-plaintext' : 'form-control'
              const html = `<div class="form-group row">
                <label class="col-sm-3 col-form-label" for="${key}">${key}</label>
                <div class="col-sm-9">
                  <input type="text" name="${key}" id="${key}" value="${value == null ? '' : value}"
                         ${readOnly ? 'disabled ' : ''}class="${fieldClass}">
                </div>
              </div>`

              $('#frm-modal-edit-appendable').append(html)
            }
          }
        )
      return true
    }
    return false
  }
  // ---------------------------------------------------------------------------
}
