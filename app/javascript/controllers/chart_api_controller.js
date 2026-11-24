import { Controller } from '@hotwired/stimulus'
import { Chart } from 'chart.js/auto'

/**
 * = Chart.js setup for API calls report - StimulusJS controller =
 *
 * Simply sets the base configuration for the Chart.js-based chart report
 * using the StimulusJS configuration helpers.
 *
 * == Targets ==
 * @param {String} 'data-chart-api-target': 'chart' => DOM ID of the target canvas
 *                 (target for this controller instance)
 *
 *
 * == Values ==
 * (Put values directly on controller elements as JSON values that will be parsed by this controller)
 *
 * @param {Array} 'data-chart-api-days-value' (required)
 *                 Array of string dates to be used as key labels for the x-axis
 *
 * @param {Array} 'data-chart-api-calls-value' (required)
 *                 Array of integer values (overall "API daily uses") to be used for the y-axis
 *
 * @param {Array} 'data-chart-api-users-value' (required)
 *                Array of integer values (overall users for non-API calls per day) for drawing an additional
 *                line with its value as y-axis
 *
 * @param {Array} 'data-chart-api-bubbles-value' (optional)
 *                Object including an array of 3-point sub-object, used to define each specific
 *                API route usage for each unique day
 *                (coord. object: {x: day label, y: API usage, radius: API usage} w/ label: route uid)
 *
 *                Detailed structure for an object item in the list:
 *
 *                    {
 *                      type: 'bubble',
 *                      label: "route_label",
 *                      data: [
 *                        { x: days_label1, y: api_use_counter1, r: api_use_counter1 / k },
 *                        { x: days_label2, y: api_use_counter2, r: api_use_counter2 / k },
 *                        // [...]
 *                      ]
 *                    }, { ... }
 *
 * == Actions:
 * (no actions, just setup; the chart redraws with the new colours on each 'theme:changed' event)
 *
 * @author Steve A.
 */
export default class extends Controller {
  static targets = ['chart']
  static values = {
    calls: Array,
    days: Array,
    users: Array,
    bubbles: Array
  }

  /**
   * Setup invoked each time the controller instance connects.
   */
  connect() {
    this.chart = null
    // Redraw with the new colours when the light/dark toggle switches the theme (theme_controller.js):
    this.onThemeChanged = () => this.applyThemeColors()
    document.addEventListener('theme:changed', this.onThemeChanged)

    if (this.hasChartTarget && this.hasDaysValue && this.hasCallsValue && this.hasUsersValue) {
      // DEBUG
      // console.log('Target & min values found. Setting up chart...')

      const colors = this.themeColors()
      const labels = this.daysValue
      const data = {
        labels: labels,
        datasets: [
          {
            type: 'line',
            label: 'API calls/day',
            data: this.callsValue,
            fill: false,
            borderColor: colors.calls,
            tension: 0.1
          },
          {
            type: 'line',
            label: 'Users/day',
            data: this.usersValue,
            fill: true,
            borderColor: colors.users,
            tension: 0.1
          }
        ].concat(this.bubblesValue.map((bubbles) => ({ ...bubbles, ...this.bubbleColors(colors) })))
      }

      const config = {
        type: 'line',
        data: data,
        options: {
          responsive: true,
          color: colors.text,
          scales: {
            x: {
              ticks: { color: colors.ticks },
              grid: { color: colors.grid }
            },
            y: {
              ticks: { color: colors.ticks },
              grid: { color: colors.grid }
            }
          },
          plugins: {
            legend: { display: false }
          }
        }
      }

      this.chart = new Chart(this.chartTarget, config)
    }
  }

  /**
   * Releases the Chart.js instance (the canvas may be reused on Turbo page restores).
   */
  disconnect() {
    document.removeEventListener('theme:changed', this.onThemeChanged)
    this.chart?.destroy()
    this.chart = null
  }

  /**
   * Re-reads the theme colours from the CSS variables and redraws the chart with them
   * (invoked on each 'theme:changed' event; no-op without a chart).
   */
  applyThemeColors() {
    if (!this.chart) return

    const colors = this.themeColors()
    const { datasets } = this.chart.data
    datasets[0].borderColor = colors.calls
    datasets[1].borderColor = colors.users
    datasets.slice(2).forEach((bubbles) => Object.assign(bubbles, this.bubbleColors(colors)))

    const { options } = this.chart
    options.color = colors.text
    for (const axis of ['x', 'y']) {
      options.scales[axis].ticks.color = colors.ticks
      options.scales[axis].grid.color = colors.grid
    }
    this.chart.update('none')
  }

  /**
   * Returns the chart colours for the theme currently in force.
   *
   * @returns {Object} { calls, users, bubbles, text, ticks, grid } colour strings
   */
  themeColors() {
    return {
      calls: this.cssColor('--bs-info', 'rgb(75, 192, 192)'),
      users: this.cssColor('--bs-danger', 'rgb(128, 64, 64)'),
      // (translucent black in light mode, as the Chart.js default; translucent white in dark mode)
      bubbles: `rgba(${this.cssColor('--bs-emphasis-color-rgb', '0, 0, 0')}, 0.1)`,
      text: this.cssColor('--bs-body-color', '#212529'),
      ticks: this.cssColor('--bs-secondary-color', '#6c757d'),
      grid: this.cssColor('--bs-border-color', '#dee2e6')
    }
  }

  /**
   * Returns the colour options of a per-route bubble dataset (the server sends none).
   *
   * @param {Object} colors the result of themeColors()
   * @returns {Object} { backgroundColor, borderColor }
   */
  bubbleColors(colors) {
    return { backgroundColor: colors.bubbles, borderColor: colors.bubbles }
  }

  /**
   * Reads a CSS custom property from the document root, so that the chart follows the
   * Bootstrap light/dark theme in force (on connect and after each theme switch).
   *
   * @param {String} name CSS variable name, including the leading dashes
   * @param {String} fallback color used when the variable is not defined
   * @returns {String} the resolved color value
   */
  cssColor(name, fallback) {
    const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim()
    return value || fallback
  }
  // ---------------------------------------------------------------------------
}
