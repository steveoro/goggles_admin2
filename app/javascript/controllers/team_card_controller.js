import { Controller } from '@hotwired/stimulus'
import { setFieldValue, present } from 'lib/form_fields'

/**
 * = team-card - StimulusJS controller =
 *
 * One Step 2 team card (data_fix/_team_form_card). Its fields are addressed by the positional ids
 * 'team_<index>_*' (rendered by the card and its LegacyAutoComplete widgets).
 *
 * == Values ==
 * - index: the card position (in the filtered list); baseline: the team fields as built from the source.
 *
 * == Actions ==
 * - selectMatch (change on the fuzzy matches select): sets the chosen id on the team LegacyAutoComplete (which
 *   fetches the details) and on the hidden 'team[team_id]' field; a blank choice restores the baseline;
 * - stop (click on the delete button: the card header toggles the collapse).
 */
export default class extends Controller {
  static values = { index: Number, baseline: { type: Object, default: {} } }

  stop (event) {
    event.stopPropagation()
  }

  selectMatch (event) {
    const teamId = event.currentTarget.value
    const prefix = this.prefix()
    if (present(teamId)) {
      setFieldValue(`${prefix}team_id`, teamId, true)
      setFieldValue(`${prefix}id_field`, teamId, false)
    } else {
      this.resetToBaseline()
    }
  }

  resetToBaseline () {
    const baseline = this.baselineValue || {}
    const prefix = this.prefix()
    setFieldValue(`${prefix}id_field`, '', false)
    setFieldValue(`${prefix}team_id`, '', false)
    setFieldValue(`${prefix}team`, '', false)
    setFieldValue(`${prefix}editable_name`, baseline.editable_name, false)
    setFieldValue(`${prefix}name`, baseline.name, false)
    setFieldValue(`${prefix}name_variations`, baseline.name_variations, false)
    setFieldValue(`${prefix}city_id_field`, baseline.city_id, false)
  }

  prefix () {
    return `team_${this.indexValue}_`
  }
}
