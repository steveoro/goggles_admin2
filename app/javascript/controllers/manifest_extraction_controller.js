import { Controller } from '@hotwired/stimulus'

/**
 * = manifest-extraction - StimulusJS controller =
 *
 * Polls the extraction_status JSON endpoint while a manifest-extraction batch
 * is running, updates the status line and reloads the page on completion so
 * the manifest-state column reflects the newly archived PDFs.
 *
 * == Values ==
 * @param {String} 'data-manifest-extraction-url-value'
 *                 The extraction_status endpoint path (no params).
 *
 * @param {String} 'data-manifest-extraction-season-id-value'
 *                 The target season ID (sent as ?season_id=).
 *
 * @param {String} 'data-manifest-extraction-running-value'
 *                 'true' when a batch is already running at render time.
 *
 * == Targets ==
 * @param {String} 'data-manifest-extraction-target': 'status'
 *                 The status line element updated on each poll.
 */
export default class extends Controller {
  static targets = ['status']
  static values = { url: String, seasonId: String, running: Boolean }

  connect() {
    if (this.runningValue) {
      this.startPolling()
    }
  }

  disconnect() {
    this.stopPolling()
  }

  /** Starts the 3s polling timer (and polls immediately once). */
  startPolling() {
    this.timer = setInterval(() => this.poll(), 3000)
    this.poll()
  }

  stopPolling() {
    if (this.timer) {
      clearInterval(this.timer)
    }
    this.timer = null
  }

  /** Fetches the JSON status; reloads the page when a run finishes. */
  async poll() {
    try {
      const res = await fetch(`${this.urlValue}?season_id=${this.seasonIdValue}`,
                              { headers: { 'Accept': 'application/json' } })
      const data = await res.json()
      this.renderStatus(data)
      if (!data.running) {
        this.stopPolling()
        // Refresh manifest ticks & pending count after a completed run:
        if (window.Turbo) {
          window.Turbo.visit(window.location.href, { action: 'replace' })
        } else {
          window.location.reload()
        }
      }
    } catch (_err) {
      this.stopPolling()
    }
  }

  /** Renders the status line from the extraction_status payload. */
  renderStatus(data) {
    if (!this.hasStatusTarget) {
      return
    }
    const status = data.status || {}
    if (data.running) {
      this.statusTarget.textContent = `extracting ${status.progress || 0}/${status.total || 0}: ${status.detail || ''}`
    } else if (status.finished_at) {
      const summary = `done: ${status.extracted || 0} extracted, ${status.skipped || 0} skipped, ${status.failed || 0} failed`
      this.statusTarget.textContent = `${summary} — pending: ${data.pending}`
    }
  }
}
