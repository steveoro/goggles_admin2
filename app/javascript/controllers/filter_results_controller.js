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
    // DEBUG
    console.log('FilterResultsController connected.')
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
    
    // DEBUG: Log filtering results
    console.log(`Filter: ${visibleCardsCount} cards visible (${hiddenCardsCount} hidden), ${totalRowsVisible} rows visible (${totalRowsHidden} hidden), filter=${showOnlyIssues}`)
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
        const hasMissingDataBadge = row.querySelector('.badge-warning[title*="missing"]') || 
                                    row.querySelector('.badge-danger') ||
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
    
    // For relay results (div-based structure with border styling)
    // Each result is a .border-bottom div directly under .card-body with inline border-left style if it has issues
    const relayResultContainers = card.querySelectorAll('.card-body > .border-bottom')
    
    // DEBUG: Log relay result detection
    if (relayResultContainers.length > 0) {
      console.log(`Found ${relayResultContainers.length} relay result containers in card`)
    }
    
    relayResultContainers.forEach((result, index) => {
      if (filterActive) {
        // Check if this relay result has issues:
        // 1. Inline style with red border-left (border-left: 4px solid #dc3545)
        // 2. OR has danger badges
        // 3. OR has missing data indicators
        const hasRedBorder = result.style.borderLeft && result.style.borderLeft.includes('#dc3545')
        const hasDangerBadge = result.querySelector('.badge-danger') !== null
        const hasMissingDataIndicator = result.querySelector('[title*="missing"]') !== null
        
        const hasIssues = hasRedBorder || hasDangerBadge || hasMissingDataIndicator
        
        // DEBUG: Log issue detection
        console.log(`  Relay result ${index}: hasRedBorder=${hasRedBorder}, hasDangerBadge=${hasDangerBadge}, hasMissingData=${hasMissingDataIndicator}, hasIssues=${hasIssues}`)
        
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
