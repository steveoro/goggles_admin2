import { Controller } from 'stimulus'
import JSONEditor from 'jsoneditor'
import 'jsoneditor/dist/jsoneditor.css'
import 'jsoneditor/dist/img/jsoneditor-icons.svg'

/**
 * = grid-edit - StimulusJS controller =
 *
 * Wrapper for JS methods used for single row edit in DataGrids.
 *
 * This will create a new controller instance for each configured "edit" button of the grid.
 *
 * Each button will yield a customized payload, which can be an empty attribute hash (Object) in the case
 * of a new record, or a hash with the values of a specific row record in case of actual edits.
 *
 * Some specific widgets are supported, depending on input type or specific DOM Ids used:
 * - `${attribute_key}-chk` - checkbox
 * - `#json-editor-${attribute_key}` - JSON editor
 *
 * Assumes also that a EditModalComponent is present in the DOM.
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
 * == Dependencies:
 * - jsoneditor: https://github.com/josdejong/jsoneditor
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
   * Controller constructor.
   * Prepares also the JSONEditor instances for the dynamic form fields.
   */
  // initialize () {
  //   console.log('initialize()')
  // }

  // DEBUG
  /**
   * Setup invoked each time the controller instance connects.
   */
  // connect () {
  //   console.log('connect()')
  // }

  /**
   * Prepares all the input fields on the unique modal form, setting eventually any special checkbox or
   * JSONEditor fields found, so that the form can have a proper payload on POST.
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

      // Make sure Turbolinks doesn't mess with the actual CSRF token of the form partial:
      if ($("#frm-modal-edit input[name='authenticity_token']").val() != $("meta[name='csrf-token']").prop('content')) {
        $("#frm-modal-edit input[name='authenticity_token']").val($("meta[name='csrf-token']").prop('content'))
      }

      // DEBUG
      // console.log(this.payloadValue)

      Object.entries(this.payloadValue)
        .forEach(
          ([key, value]) => {
            // ** Checkbox fields: **
            // (use specific & unique DOM input fields, inside modal form)
            if ($(`#${key}-chk`).prop('type') == 'checkbox') {
              // Hidden field also available? Add a toggle/change event handler:
              if ($(`#${key}`).prop('type') == 'hidden') {
                $(`#${key}-chk`)
                  .on('change', (event) => {
                    const currState = $(event.target).prop('checked')
                    const newValue = (currState == true) || (currState == 'true') ? '1' : '0'
                    $(`#${key}`).val(newValue).trigger('change')
                    $(`#${key}-chk`).val(newValue)
                  })
              }
              // Setup initial hidden field & checkbox value
              const initialValue = (value == true) || (value == 'true')
              $(`#${key}-chk`).prop('checked', initialValue).trigger('change')
            }

            // ** JSONEditor fields: **
            // (use specific & unique DOM containers, inside modal form)
            else if (document.querySelector(`#json-editor-${key}`)) {
              var container = document.querySelector(`#json-editor-${key}`)
              // Editor already created? Initialize its contents (from the row payload):
              if (container.jsoneditor) {
                // DEBUG
                // console.log(`JSON editor found for "${key}", setting field value...`)
                container.jsoneditor.set(JSON.parse(value))
              }
              else {
                // DEBUG
                // console.log(`Creating JSON editor instance for "${key}"...`)
                container.jsoneditor = new JSONEditor(
                  container,
                  {
                    mode: 'tree',
                    modes: ['code', 'tree'],
                    onChangeText: (jsonText) => {
                      // DEBUG
                      // console.log(`JSON editor for "${key}" changed...`)
                      // Update both the row payload & the form's actual hidden field value:
                      this.payloadValue[key] = jsonText
                      $(`#${key}`).val(jsonText).trigger('change')
                    },
                    onError: (err) => {
                      console.error(err)
                    }
                  },
                  JSON.parse(value)
                )
              }
            }

            // ** "Standard" input fields: **
            // (any other input field using attribute "key" as DOM Id)
            else {
              $(`#${key}`).val(value).trigger('change')
            }
          }
        )
      return true
    }
    return false
  }
  // ---------------------------------------------------------------------------
}
