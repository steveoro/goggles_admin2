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
 * - `${attribute_key}-chk` - checkbox (boolean)
 * - `#json-editor-${attribute_key}` - JSON editor (text)
 *
 * Assumes also that a EditModalComponent is present in the DOM (accessed through its ID as set in the values).
 *
 * == Targets ==
 * (none)
 *
 * == Values ==
 * (Put values directly on controller elements)
 * @param {String} 'data-grid-edit-base-modal-id-value':
 *                 Base DOM ID of the modal target;
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
 * - <tt>handleEdit</tt> => fill the target modal form and display it.
 *
 * == Assumptions:
 * - <tt>"<BASE_MODAL_DOM_ID>-modal"</tt>
 *   => DOM ID of the modal container; the input fields (& labels) are assumed to be already generated by the component,
 *   according to the attributes stored in the payload.
 *
 * - <tt>"frm-<BASE_MODAL_DOM_ID>"</tt>
 *   => DOM ID of the internal Form storing the input fields for the "Grid Edit modal".
 *
 * - <tt>"btn-<BASE_MODAL_DOM_ID>-submit-save"</tt>
 *   => DOM ID of the submit button for saving the edits made using the internal Form.
 *
 * - <tt>"<BASE_MODAL_DOM_ID>-modal-title"</tt>
 *   => DOM ID of the label displaying the localized title string specified in the values
 *      ("data-grid-edit-modal-edit-title-value" or "data-grid-edit-modal-create-title-value").
 *
 * == Dependencies:
 * - jsoneditor: https://github.com/josdejong/jsoneditor
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['form']
  static values = {
    baseModalId: String,
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

    if (this.hasBaseModalIdValue && this.hasUrlValue && this.hasPayloadValue) {
      // DEBUG
      // console.log('urlValue:')
      // console.log(this.urlValue)

      // Fix defaults for modal: (title, hidden _method & submit button method)
      if (this.payloadValue['id'] == null) {
        $(`#${this.baseModalIdValue}-modal-title`).text(this.modalCreateTitleValue)
        $(`#frm-${this.baseModalIdValue} input[name='_method']`).val('post')
        $(`#btn-${this.baseModalIdValue}-submit-save`).attr('method', 'post')
      }
      else {
        $(`#${this.baseModalIdValue}-modal-title`).text(this.modalEditTitleValue)
        $(`#frm-${this.baseModalIdValue} input[name='_method']`).val('patch')
        $(`#btn-${this.baseModalIdValue}-submit-save`).attr('method', 'put')
      }
      // Fix form target URL:
      $(`#frm-${this.baseModalIdValue}`).prop('action', this.urlValue)

      // Make sure Turbolinks doesn't mess with the actual CSRF token of the form partial:
      if ($(`#frm-${this.baseModalIdValue} input[name='authenticity_token']`).val() != $("meta[name='csrf-token']").prop('content')) {
        $(`#frm-${this.baseModalIdValue} input[name='authenticity_token']`).val($("meta[name='csrf-token']").prop('content'))
      }

      // DEBUG
      // console.log(this.payloadValue)
      const nameSpaceBase = (this.baseModalIdValue == 'grid-edit' || this.baseModalIdValue == '' || this.baseModalIdValue == null) ?
                            '' : `${this.baseModalIdValue}_`
      // DEBUG
      console.log(`nameSpaceBase: '${nameSpaceBase}'`)

      Object.entries(this.payloadValue)
        .forEach(
          ([key, value]) => {
            // Use a namespaced selector only when the modal ID is present or different from the default:
            const namespacedFieldDomId = `${nameSpaceBase}${key}`
            // DEBUG
            // console.log(`Processing key: ${key} => Field DOM ID: #${namespacedFieldDomId}`)

            // ** Checkbox fields: **
            // (use specific & unique DOM input fields, inside modal form)
            if ($(`#${namespacedFieldDomId}-chk`).prop('type') == 'checkbox') {
              // DEBUG
              // console.log('Checkbox field found')
              // Hidden field also available? Add a toggle/change event handler:
              if ($(`#${namespacedFieldDomId}`).prop('type') == 'hidden') {
                $(`#${namespacedFieldDomId}-chk`)
                  .on('change', (event) => {
                    const currState = $(event.target).prop('checked')
                    const newValue = (currState == true) || (currState == 'true') ? '1' : '0'
                    $(`#${namespacedFieldDomId}`).val(newValue).trigger('change')
                    $(`#${namespacedFieldDomId}-chk`).val(newValue)
                  })
              }
              // Setup initial hidden field & checkbox value
              const initialValue = (value == true) || (value == 'true')
              $(`#${namespacedFieldDomId}-chk`).prop('checked', initialValue).trigger('change')
            }

            // ** JSONEditor fields: **
            // (use specific & unique DOM containers, inside modal form)
            else if (document.querySelector(`#json-editor-${namespacedFieldDomId}`)) {
              // DEBUG
              // console.log('Possible JSON-editor field found')
              var container = document.querySelector(`#json-editor-${namespacedFieldDomId}`)
              $(`#${namespacedFieldDomId}`).val(value) // Set initial value into hiden field
              // Editor already created? Initialize its contents (from the row payload):
              if (container.jsoneditor) {
                // DEBUG
                // console.log(`JSON editor instance found for "#${namespacedFieldDomId}": setting field value...`)
                container.jsoneditor.set(JSON.parse(value))
              }
              else {
                // DEBUG
                // console.log(`Creating JSON editor instance for "#${namespacedFieldDomId}"...`)
                container.jsoneditor = new JSONEditor(
                  container,
                  {
                    mode: 'tree',
                    modes: ['code', 'tree'],
                    onChangeText: (jsonText) => {
                      // DEBUG
                      // console.log(`JSON editor for "#${namespacedFieldDomId}" changed...`)
                      // Update both the row payload & the form's actual hidden field value:
                      this.payloadValue[key] = jsonText
                      $(`#${namespacedFieldDomId}`).val(jsonText).trigger('change')
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
              // DEBUG
              // console.log(`Processing "#${namespacedFieldDomId}" standard input field...`)
              $(`#${namespacedFieldDomId}`).val(value).trigger('change')
            }
          }
        )
      return true
    }
    return false
  }
  // ---------------------------------------------------------------------------
}
