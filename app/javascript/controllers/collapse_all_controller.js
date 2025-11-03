import { Controller } from "@hotwired/stimulus"

/**
 * Collapse All Controller
 * Toggles collapse state for multiple Bootstrap collapse elements
 * 
 * Usage:
 *   <div data-controller="collapse-all">
 *     <button data-action="collapse-all#toggle" data-collapse-all-target="button">Toggle</button>
 *     <div id="collapse-1" class="collapse show">...</div>
 *     <div id="collapse-2" class="collapse show">...</div>
 *   </div>
 * 
 * Attributes:
 *   data-collapse-all-selector: CSS selector for collapse elements (default: '[id^="result-collapse-"]')
 */
export default class extends Controller {
  static targets = ["button"]
  static values = {
    selector: { type: String, default: '[id^="result-collapse-"]' },
    collapsed: { type: Boolean, default: false }
  }

  connect() {
    // DEBUG
    // console.log('CollapseAllController connected.')
    this.updateButtonState()
  }

  toggle() {
    // DEBUG
    // console.log('toggle()')
    // console.log('Selector:', this.selectorValue)
    this.collapsedValue = !this.collapsedValue
    const collapseElements = document.querySelectorAll(this.selectorValue)
    // console.log('Found elements:', collapseElements.length)

    collapseElements.forEach(element => {
      // DEBUG
      // console.log('Processing element:', element.id)
      const $element = $(element)
      if (this.collapsedValue) {
        $element.collapse('hide')
      } else {
        $element.collapse('show')
      }
    })
    
    this.updateButtonState()
  }

  updateButtonState() {
    // DEBUG
    // console.log('updateButtonState()')
    if (!this.hasButtonTarget) return
    
    const icon = this.buttonTarget.querySelector('i')
    if (!icon) return
    
    if (this.collapsedValue) {
      icon.classList.remove('fa-compress')
      icon.classList.add('fa-expand')
      this.buttonTarget.innerHTML = '<i class="fa fa-expand"></i> Expand All Results'
    } else {
      icon.classList.remove('fa-expand')
      icon.classList.add('fa-compress')
      this.buttonTarget.innerHTML = '<i class="fa fa-compress"></i> Collapse All Results'
    }
  }
}
