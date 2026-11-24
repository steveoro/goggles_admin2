import { Controller } from '@hotwired/stimulus'

let codemirrorPromise = null
const loadCodeMirror = () => {
  if (!codemirrorPromise) codemirrorPromise = import('codemirror-json')
  return codemirrorPromise
}

/**
 * = sources-editor - StimulusJS controller =
 *
 * File editor of the Sources Files tab (Sources::FilesController#edit).
 * - JSON files: a CodeMirror 6 editor (the vendored 'codemirror-json' bundle, as grid_edit_controller) replaces the
 *   textarea, which stays the submitted field: the editor text is copied into it on submit. An invalid JSON text is
 *   stopped here with the parser message (the server checks it again and refuses the save anyway).
 * - Other files (CSV, TXT): the plain textarea.
 *
 * == Targets ==
 * - field: the submitted textarea; editor: the CodeMirror container; error: the validation message.
 *
 * == Values ==
 * - json: Boolean, the file is JSON; invalid: message prefix shown for an invalid JSON text.
 */
export default class extends Controller {
  static targets = ['field', 'editor', 'error']
  static values = { json: Boolean, invalid: String }

  connect () {
    if (!this.jsonValue || !this.hasEditorTarget) return

    loadCodeMirror().then((cm) => {
      if (!this.element.isConnected) return

      this.view = new cm.EditorView({
        doc: this.fieldTarget.value,
        extensions: [
          cm.lineNumbers(), cm.highlightActiveLineGutter(), cm.highlightSpecialChars(), cm.history(), cm.foldGutter(),
          cm.drawSelection(), cm.keymap.of([cm.defaultKeymap, cm.historyKeymap, cm.foldKeymap]), cm.bracketMatching(),
          cm.highlightSelectionMatches(), cm.json()
        ],
        parent: this.editorTarget
      })
      this.editorTarget.classList.remove('d-none')
      this.fieldTarget.classList.add('d-none')
    }).catch((err) => console.warn('sources-editor: JSON editor unavailable, using the plain text area', err))
  }

  disconnect () {
    this.view?.destroy()
    this.view = null
  }

  submit (event) {
    if (this.view) this.fieldTarget.value = this.view.state.doc.toString()
    if (!this.jsonValue) return

    try {
      JSON.parse(this.fieldTarget.value)
      this.showError('')
    } catch (err) {
      event.preventDefault()
      event.stopImmediatePropagation()
      this.showError(`${this.invalidValue} ${err.message}`)
    }
  }

  showError (message) {
    if (this.hasErrorTarget) this.errorTarget.textContent = message
  }
}
