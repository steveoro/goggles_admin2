import { Controller } from '@hotwired/stimulus'
import { setFieldValue, present } from 'lib/form_fields'

/**
 * = event-card - StimulusJS controller =
 *
 * One Step 4 event card (data_fix/_event_form_card), fields 'event_<index>_*'.
 *
 * == Values ==
 * - index: the card index (in the flattened event list); existingEvents: the DB events of the matched meeting.
 *
 * == Actions ==
 * - populateFromExisting (change on the DB event select): copies order, begin time, heat type, event type (through
 *   the event type LegacyAutoComplete: 'change' event) and the read-only legacy fields of the chosen DB event;
 * - stop (click on the delete button: the card header toggles the collapse).
 */
export default class extends Controller {
  static values = { index: Number, existingEvents: { type: Array, default: [] } }

  stop (event) {
    event.stopPropagation()
  }

  populateFromExisting (event) {
    const eventId = event.currentTarget.value
    if (!present(eventId)) return

    const meetingEvent = this.existingEventsValue.find((row) => String(row.id) === String(eventId))
    if (!meetingEvent) return

    const prefix = `event_${this.indexValue}_`
    if (meetingEvent.event_order) setFieldValue(`${prefix}order`, meetingEvent.event_order, false)
    if (meetingEvent.begin_time) setFieldValue(`${prefix}begin_time`, meetingEvent.begin_time, false)
    if (meetingEvent.heat_type_id) setFieldValue(`${prefix}heat_type_id`, meetingEvent.heat_type_id, false)
    if (meetingEvent.event_type_id) setFieldValue(`meeting_event_${this.indexValue}_event_type_id`, meetingEvent.event_type_id, true)
    // (legacy fields of the phase file, derived from the event and heat types)
    if (meetingEvent.distance) setFieldValue(`${prefix}distance`, meetingEvent.distance, false)
    if (meetingEvent.stroke_type_code) setFieldValue(`${prefix}stroke`, meetingEvent.stroke_type_code, false)
    if (meetingEvent.heat_type_code) setFieldValue(`${prefix}heat_type_code`, meetingEvent.heat_type_code, false)
  }
}
