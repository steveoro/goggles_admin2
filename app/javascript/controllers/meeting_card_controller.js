import { Controller } from '@hotwired/stimulus'
import { setFieldValue, setCheckboxValue, fieldValue, present } from 'lib/form_fields'

// Meeting fields restored by "no fuzzy match selected": DOM id => baseline key
const BASELINE_FIELDS = {
  meeting_description: 'name',
  meeting_code: 'code',
  meeting_season_id: 'season_id',
  meeting_header_year: 'header_year',
  meeting_header_date: 'header_date',
  meetingURL: 'meetingURL',
  meeting_edition: 'edition',
  meeting_edition_type_id: 'edition_type_id',
  meeting_timing_type_id: 'timing_type_id',
  max_individual_events: 'max_individual_events',
  max_individual_events_per_session: 'max_individual_events_per_session',
  poolLength: 'poolLength',
  dateDay1: 'dateDay1',
  dateMonth1: 'dateMonth1',
  dateYear1: 'dateYear1',
  dateDay2: 'dateDay2',
  dateMonth2: 'dateMonth2',
  dateYear2: 'dateYear2',
  venue1: 'venue1',
  address1: 'address1'
}

/**
 * = meeting-card - StimulusJS controller =
 *
 * Step 1 (data_fix/_meeting_form_card + the sessions toolbar of review_sessions).
 *
 * == Values / params ==
 * - baseline (value, or the `baseline` param of the select): the meeting fields as built from the source (restored
 *   when no fuzzy match is selected);
 * - idField: DOM id of the LegacyAutoComplete meeting id field (default 'meeting_meeting_id').
 *
 * == Targets ==
 * - rescanId: hidden 'meeting_id' field of the "rescan sessions" form.
 *
 * == Actions ==
 * - selectMatch (change on the fuzzy matches select): sets the chosen id on the LegacyAutoComplete field and lets
 *   it fetch the details ('change' event); a blank choice restores the baseline;
 * - copyMeetingId (submit of the rescan form): sends the meeting id currently chosen in the card.
 */
export default class extends Controller {
  static targets = ['rescanId']

  static values = {
    baseline: Object,
    idField: { type: String, default: 'meeting_meeting_id' }
  }

  selectMatch (event) {
    const selected = event.currentTarget.value
    if (present(selected)) {
      setFieldValue(this.idFieldValue, selected, true)
    } else {
      this.resetToBaseline(event.params?.baseline)
    }
  }

  copyMeetingId () {
    if (this.hasRescanIdTarget) this.rescanIdTarget.value = fieldValue(this.idFieldValue) || ''
  }

  resetToBaseline (baseline = null) {
    baseline = baseline || this.baselineValue || {}
    setFieldValue(this.idFieldValue, '', false)
    setFieldValue('meeting_meeting', '', false)
    const desc = document.getElementById('meeting-desc')
    if (desc) desc.textContent = ''

    Object.entries(BASELINE_FIELDS).forEach(([fieldId, key]) => setFieldValue(fieldId, baseline[key], false))
    setCheckboxValue('meeting_cancelled', baseline.cancelled)
    setCheckboxValue('meeting_confirmed', baseline.confirmed == null ? true : baseline.confirmed)
  }
}
