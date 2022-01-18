import { Controller } from '@hotwired/stimulus'
import Chart from 'chart.js/auto'

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
 * (no actions, just setup)
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
    if (this.hasChartTarget && this.hasDaysValue && this.hasCallsValue && this.hasUsersValue) {
      // DEBUG
      // console.log('Target & min values found. Setting up chart...')

      const labels = this.daysValue
      const data = {
        labels: labels,
        datasets: [
          {
            type: 'line',
            label: 'API calls/day',
            data: this.callsValue,
            fill: false,
            borderColor: 'rgb(75, 192, 192)',
            tension: 0.1
          },
          {
            type: 'line',
            label: 'Users/day',
            data: this.usersValue,
            fill: true,
            borderColor: 'rgb(128, 64, 64)',
            tension: 0.1
          }
        ].concat(this.bubblesValue)
      }

      const config = {
        type: 'line',
        data: data,
        options: {
          responsive: true,
          plugins: {
            legend: { display: false }
          }
        }
      }

      new Chart(this.chartTarget, config)
    }
  }
  // ---------------------------------------------------------------------------
}
