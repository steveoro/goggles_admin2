import { Controller } from '@hotwired/stimulus'
import { setFieldValue, present } from 'lib/form_fields'

const BASELINE_FIELDS = ['complete_name', 'last_name', 'first_name', 'year_of_birth', 'gender_type_code']

/**
 * = swimmer-card - StimulusJS controller =
 *
 * One Step 3 swimmer card (data_fix/_swimmer_form_card). Its fields are addressed by the positional ids
 * 'swimmer_<index>_*' (rendered by the card and its LegacyAutoComplete widget).
 *
 * == Values ==
 * - index: the card position (in the filtered list); baseline: the swimmer fields as built from the source.
 *
 * == Actions ==
 * - selectMatch (change on the fuzzy matches select): sets the chosen id on the swimmer LegacyAutoComplete (which
 *   fetches the details) and on the hidden 'swimmer[id]' field; a blank choice restores the baseline;
 * - stop (click on the delete button: the card header toggles the collapse).
 */
export default class extends Controller {
  static values = { index: Number, baseline: { type: Object, default: {} } }

  stop (event) {
    event.stopPropagation()
  }

  selectMatch (event) {
    const swimmerId = event.currentTarget.value
    const prefix = this.prefix()
    if (present(swimmerId)) {
      setFieldValue(`${prefix}swimmer_id`, swimmerId, true)
      setFieldValue(`${prefix}id_field`, swimmerId, false)
    } else {
      this.resetToBaseline()
    }
  }

  resetToBaseline () {
    const baseline = this.baselineValue || {}
    const prefix = this.prefix()
    setFieldValue(`${prefix}id_field`, '', false)
    setFieldValue(`${prefix}swimmer_id`, '', false)
    setFieldValue(`${prefix}swimmer`, '', false)
    BASELINE_FIELDS.forEach((field) => setFieldValue(`${prefix}${field}`, baseline[field], false))
  }

  prefix () {
    return `swimmer_${this.indexValue}_`
  }
}
