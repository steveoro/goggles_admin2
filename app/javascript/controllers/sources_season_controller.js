import { Controller } from '@hotwired/stimulus'

/**
 * = sources-season - StimulusJS controller =
 *
 * Season selector of the Sources pages (Sources::SeasonSelectorComponent): submits its GET form as soon as
 * another season is chosen (the server remembers the choice).
 */
export default class extends Controller {
  submit () {
    this.element.requestSubmit()
  }
}
