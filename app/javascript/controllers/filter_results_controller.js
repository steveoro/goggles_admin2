import { Controller } from "@hotwired/stimulus"

/**
 * Filter Results Controller
 * Toggles visibility of program cards based on "has issues" flag
 * 
 * Usage:
 *   <div data-controller="filter-results">
 *     <input type="checkbox" data-action="filter-results#toggle" data-filter-results-target="checkbox">
 *     <div class="card" data-has-issues="true">...</div>
 *     <div class="card" data-has-issues="false">...</div>
 *   </div>
 * 
 * Targets:
 *   checkbox: The filter checkbox input
 * 
 * Values:
 *   cardSelector: CSS selector for cards to filter (default: '[data-has-issues]')
 */
export default class extends Controller {
  static targets = ["checkbox"]
  static values = {
    cardSelector: { type: String, default: '[data-has-issues]' }
  }

  connect() {
    // Initialize filter state
    this.filterCards()
  }

  toggle() {
    this.filterCards()
  }

  filterCards() {
    if (!this.hasCheckboxTarget) return
    
    const showOnlyIssues = this.checkboxTarget.checked
    const allCards = document.querySelectorAll(this.cardSelectorValue)
    
    let hiddenCardsCount = 0
    let visibleCardsCount = 0
    let totalRowsHidden = 0
    let totalRowsVisible = 0
    
    allCards.forEach(card => {
      if (showOnlyIssues) {
        // STEP 1: Filter result rows within this card FIRST
        const rowStats = this.filterResultRows(card, true)
        totalRowsHidden += rowStats.hidden
        totalRowsVisible += rowStats.visible
        
        // STEP 2: Hide card only if NO visible rows remain
        if (rowStats.visible === 0) {
          card.style.display = 'none'
          hiddenCardsCount++
        } else {
          card.style.display = 'block'
          visibleCardsCount++
        }
      } else {
        // Show all cards and all rows
        card.style.display = 'block'
        visibleCardsCount++
        const rowStats = this.filterResultRows(card, false)
        totalRowsVisible += rowStats.visible
      }
    })
  }
  
  // Filter individual result rows within a card
  // Only show rows with issues when filterActive is true
  // Returns { visible: count, hidden: count }
  filterResultRows(card, filterActive) {
    let visibleCount = 0
    let hiddenCount = 0
    
    // For individual results in table rows
    const resultRows = card.querySelectorAll('tbody tr')
    resultRows.forEach(row => {
      if (filterActive) {
        // Check if this row has missing data indicators
        const hasMissingDataBadge = row.querySelector('.text-bg-warning[title*="missing"]') || 
                                    row.querySelector('.text-bg-danger') ||
                                    row.querySelector('.text-warning')
        
        if (hasMissingDataBadge) {
          row.style.display = ''  // Show row
          visibleCount++
        } else {
          row.style.display = 'none'  // Hide row
          hiddenCount++
        }
      } else {
        row.style.display = ''  // Show all rows
        visibleCount++
      }
    })
    
    // For relay results (div-based structure): each result is a .border-bottom div directly under .card-body,
    // marked .data-fix-relay-issue (red left border) when it has issues
    const relayResultContainers = card.querySelectorAll('.card-body > .border-bottom')

    relayResultContainers.forEach((result) => {
      if (filterActive) {
        // Check if this relay result has issues:
        // 1. The red left border (.data-fix-relay-issue)
        // 2. OR has danger badges
        // 3. OR has missing data indicators
        const hasRedBorder = result.classList.contains('data-fix-relay-issue')
        const hasDangerBadge = result.querySelector('.text-bg-danger') !== null
        const hasMissingDataIndicator = result.querySelector('[title*="missing"]') !== null
        
        const hasIssues = hasRedBorder || hasDangerBadge || hasMissingDataIndicator

        if (hasIssues) {
          result.style.display = ''  // Show result
          visibleCount++
        } else {
          result.style.display = 'none'  // Hide result
          hiddenCount++
        }
      } else {
        result.style.display = ''  // Show all results
        visibleCount++
      }
    })
    
    return { visible: visibleCount, hidden: hiddenCount }
  }
}
