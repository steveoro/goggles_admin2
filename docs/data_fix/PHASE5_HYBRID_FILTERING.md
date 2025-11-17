# Phase 5: Hybrid Filtering Implementation

**Date**: 2025-11-17  
**Status**: ✅ Complete

---

## Overview

Implemented **hybrid server-side + client-side filtering** for Phase 5 results:

1. **Server-side**: Filter out program cards without issues (not rendered at all)
2. **Client-side**: Within visible cards, hide individual result rows without issues

This provides optimal performance and UX - cards without issues aren't even sent to the browser, and within visible cards, users see only problematic rows.

---

## Architecture

### Server-Side Filtering (Controller)

**Trigger**: `filter_issues` URL parameter present

**File**: `app/controllers/data_fix_controller.rb`

#### Added Instance Variable
```ruby
@filter_active = params[:filter_issues].present?
```

#### Filter Programs Before Pagination
```ruby
if @filter_active
  all_programs = filter_programs_with_issues(all_programs)
end
```

#### New Private Method: `filter_programs_with_issues`
```ruby
def filter_programs_with_issues(programs)
  programs.select do |prog|
    program_key = "#{prog['session_order']}-#{prog['event_code']}-#{prog['category_code']}-#{prog['gender_code']}"
    
    if prog['relay']
      # Check if any relay results in this program have issues
      relay_results = GogglesDb::DataImportMeetingRelayResult
                      .where('import_key LIKE ?', "#{program_key}/%")
      
      relay_results.any? do |mrr|
        issue_info = relay_result_has_issues?(mrr)
        issue_info[:has_issues]
      end
    else
      # Check if any individual results in this program have issues
      individual_results = GogglesDb::DataImportMeetingIndividualResult
                           .where('import_key LIKE ?', "#{program_key}/%")
      
      individual_results.any? do |mir|
        if mir.swimmer_id
          swimmer = @swimmers_by_id[mir.swimmer_id]
          swimmer && (swimmer.gender_type_id.nil? || swimmer.year_of_birth.nil?)
        else
          mir.swimmer_key && swimmer_has_missing_data?(mir.swimmer_key).values.any?
        end
      end
    end
  end
end
```

**Logic**:
- For relay programs: Check if any `DataImportMeetingRelayResult` has issues using `relay_result_has_issues?` helper
- For individual programs: Check if any `DataImportMeetingIndividualResult` has missing swimmer data
- Return only programs with at least one problematic result

---

### Client-Side Filtering (Stimulus)

**File**: `app/javascript/controllers/filter_results_controller.js`

#### Bottom-Up Approach
```javascript
filterCards() {
  const showOnlyIssues = this.checkboxTarget.checked
  const allCards = document.querySelectorAll(this.cardSelectorValue)
  
  allCards.forEach(card => {
    if (showOnlyIssues) {
      // STEP 1: Filter result rows FIRST
      const rowStats = this.filterResultRows(card, true)
      
      // STEP 2: Hide card only if NO visible rows remain
      if (rowStats.visible === 0) {
        card.style.display = 'none'
      } else {
        card.style.display = 'block'
      }
    } else {
      // Show all cards and all rows
      card.style.display = 'block'
      this.filterResultRows(card, false)
    }
  })
}
```

#### Row-Level Filtering
```javascript
filterResultRows(card, filterActive) {
  let visibleCount = 0
  let hiddenCount = 0
  
  // For individual results (table rows)
  const resultRows = card.querySelectorAll('tbody tr')
  resultRows.forEach(row => {
    if (filterActive) {
      const hasMissingDataBadge = row.querySelector('.badge-warning[title*="missing"]') || 
                                  row.querySelector('.badge-danger') ||
                                  row.querySelector('.text-warning')
      
      row.style.display = hasMissingDataBadge ? '' : 'none'
      if (hasMissingDataBadge) visibleCount++
      else hiddenCount++
    } else {
      row.style.display = ''
      visibleCount++
    }
  })
  
  // For relay results (div-based structure)
  const relayResultContainers = card.querySelectorAll('.card-body > .border-bottom')
  relayResultContainers.forEach(result => {
    if (filterActive) {
      const hasRedBorder = result.style.borderLeft && result.style.borderLeft.includes('#dc3545')
      const hasDangerBadge = result.querySelector('.badge-danger') !== null
      const hasMissingDataIndicator = result.querySelector('[title*="missing"]') !== null
      
      const hasIssues = hasRedBorder || hasDangerBadge || hasMissingDataIndicator
      
      result.style.display = hasIssues ? '' : 'none'
      if (hasIssues) visibleCount++
      else hiddenCount++
    } else {
      result.style.display = ''
      visibleCount++
    }
  })
  
  return { visible: visibleCount, hidden: hiddenCount }
}
```

---

### View Updates

**File**: `app/views/data_fix/review_results_v2.html.haml`

#### Checkbox with Server-Side Trigger
```haml
- filter_checked = params[:filter_issues].present?
- base_params = request.query_parameters.except(:filter_issues, :page)
%input#filter-issues{ type: 'checkbox', class: 'form-check-input',
                       checked: filter_checked,
                       onchange: "window.location.href='#{review_results_path(filter_checked ? base_params : base_params.merge(filter_issues: '1'))}'",
                       data: { action: 'filter-results#toggle', filter_results_target: 'checkbox' } }
```

**Behavior**:
- Checkbox state reflects URL parameter
- `onchange` triggers page reload with/without `filter_issues=1` parameter
- Stimulus controller still handles client-side row filtering

#### Pagination Links Preserve Filter
```haml
- pagination_base_params = request.query_parameters.except(:page)
= link_to '← Previous', review_results_path(pagination_base_params.merge(page: prev_page))
= link_to 'Next →', review_results_path(pagination_base_params.merge(page: next_page))
```

---

## How It Works

### Filter OFF (Unchecked)

**URL**: `/data_fix/review_results?file_path=...&phase5_v2=1`

1. **Server**: Renders all program cards
2. **Client**: Displays all result rows

### Filter ON (Checked)

**URL**: `/data_fix/review_results?file_path=...&phase5_v2=1&filter_issues=1`

1. **Server**:
   - Calls `filter_programs_with_issues(all_programs)`
   - Only renders cards that have at least one result with issues
   - Other cards never sent to browser

2. **Client** (within visible cards):
   - Stimulus controller hides rows without issues
   - Shows only problematic result rows
   - If all rows hidden → card also hidden (fallback, shouldn't happen with server filter)

---

## Benefits

### Performance
- ✅ Cards without issues not rendered (saves HTML/DOM)
- ✅ Fewer elements for JavaScript to process
- ✅ Faster page load when filter active
- ✅ Server filter runs before pagination (efficient)

### UX
- ✅ Checkbox triggers clear page reload
- ✅ Filter state preserved in URL (shareable links)
- ✅ Pagination preserves filter state
- ✅ Within visible cards, only see problematic rows
- ✅ No "empty cards" - server filters them out

### Maintainability
- ✅ Reuses existing `relay_result_has_issues?` helper
- ✅ Reuses existing `swimmer_has_missing_data?` helper
- ✅ Clear separation: server filters cards, client filters rows
- ✅ Stimulus controller still works as fallback

---

## Filter Detection Logic

### Individual Results
**Issue detected if**:
- Matched swimmer (`swimmer_id` present): Missing `gender_type_id` OR `year_of_birth`
- Unmatched swimmer (`swimmer_key` present): Phase3 data has missing gender OR year

### Relay Results
**Issue detected if**:
- Any relay swimmer has missing `gender_type_id` OR `year_of_birth`
- Checks both matched (via `swimmer_id`) and unmatched (via `swimmer_key` in phase3)

### Visual Indicators
- **Card level**: Red border if any result has issues
- **Row level**: 
  - Individual: `.badge-warning`, `.badge-danger`, `.text-warning`
  - Relay: Inline `border-left: 4px solid #dc3545` style

---

## Testing Checklist

### Server-Side Filtering
- [ ] **Filter OFF** → All program cards visible
- [ ] **Filter ON** → Only cards with issues visible
- [ ] **Filter ON + No issues** → Shows "No results" message
- [ ] **Pagination with filter** → Filter state preserved across pages
- [ ] **URL sharing** → Filter state works from copied URL

### Client-Side Row Filtering
- [ ] **Within visible card** → Only problematic rows visible when filter ON
- [ ] **All rows OK** → Card hidden (shouldn't happen with server filter)
- [ ] **Mixed rows** → Shows only those with issues
- [ ] **Individual results** → Detects missing data badges
- [ ] **Relay results** → Detects red border and danger badges

### Edge Cases
- [ ] **Empty programs** → No errors
- [ ] **All have issues** → All visible
- [ ] **None have issues** → All hidden when filter ON
- [ ] **Page boundaries** → Filter + pagination work together

---

## Files Modified

| File | Lines | Description |
|------|-------|-------------|
| `app/controllers/data_fix_controller.rb` | +43 | Server-side filter method & logic |
| `app/views/data_fix/review_results_v2.html.haml` | +9 | Checkbox triggers page reload |
| `app/javascript/controllers/filter_results_controller.js` | +35 | Row-level filtering logic |
| `app/views/data_fix/_relay_program_card.html.haml` | -1 | Removed TODO comment |

**Total**: ~86 lines

---

## Summary

✅ **Hybrid filtering complete**:
- **Server-side**: Programs without issues not rendered
- **Client-side**: Rows without issues hidden within visible cards
- **URL-based**: Filter state shareable and bookmarkable
- **Pagination-aware**: Filter preserved across pages

🎯 **Perfect balance**: Server handles card-level, JavaScript handles row-level

---

**Next Steps**:
1. Test with real meeting file
2. Verify performance with large meetings
3. Proceed to Phase 6 relay commit support

**Last Updated**: 2025-11-17
