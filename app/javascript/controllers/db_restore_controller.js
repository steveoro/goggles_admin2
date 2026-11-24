import { Controller } from '@hotwired/stimulus'

/**
 * = DB restore controller
 *
 * Polls the JSON status of a guided local DB restore run (phase 14) every `interval` ms, without Action Cable
 * (the progress page must keep working while MySQL is dropped and reloaded):
 * - while the status, the step and the "needs operator" flag stay the same, it only updates the progress bar,
 *   the percentage and the step label;
 * - when one of them changes, it reloads the page (the server renders the actions of the new state).
 * Fetch errors are ignored (the next poll retries).
 *
 * == Values:
 * - url: status JSON URL; status / step: the rendered state; needsOperator: the rendered flag;
 * - percent: the rendered progress (sets the bar width on connect: the template has no inline style);
 * - interval: polling period in ms (default 2000)
 *
 * == Targets (all optional): bar (.progress-bar), percent, step
 */
export default class extends Controller {
  static targets = ['bar', 'percent', 'step']
  static values = {
    url: String,
    status: String,
    step: { type: String, default: '' },
    needsOperator: { type: Boolean, default: false },
    percent: { type: Number, default: 0 },
    interval: { type: Number, default: 2000 }
  }

  connect () {
    this.showPercent(this.percentValue)
    this.timer = setInterval(() => this.poll(), this.intervalValue)
  }

  disconnect () {
    clearInterval(this.timer)
  }

  async poll () {
    if (this.busy || !this.urlValue) return

    this.busy = true
    try {
      const response = await fetch(this.urlValue, { headers: { Accept: 'application/json' }, credentials: 'same-origin' })
      if (response.ok) this.update(await response.json())
    } catch (_error) {
      // (retried at the next tick)
    } finally {
      this.busy = false
    }
  }

  update (data) {
    const changed = data.status !== this.statusValue || (data.step || '') !== this.stepValue ||
      Boolean(data.needs_operator) !== this.needsOperatorValue
    if (changed) {
      clearInterval(this.timer)
      window.location.reload()
      return
    }

    if (data.percent !== null && data.percent !== undefined) this.showPercent(data.percent)
    if (this.hasStepTarget && data.step_label) this.stepTarget.textContent = data.step_label
  }

  showPercent (value) {
    const percent = `${value}%`
    if (this.hasBarTarget) {
      this.barTarget.style.width = percent
      this.barTarget.parentElement.setAttribute('aria-valuenow', value)
    }
    if (this.hasPercentTarget) this.percentTarget.textContent = percent
  }
}
