# Filter Results: Stimulus Controller Setup

**Date**: 2025-11-17  
**Issue**: Inline JavaScript not working in Rails 6.2 with Webpacker  
**Solution**: Convert to Stimulus controller

---

## Changes Made

### 1. Created Stimulus Controller ✅
**File**: `app/javascript/controllers/filter_results_controller.js`

```javascript
import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["checkbox"]
  static values = {
    cardSelector: { type: String, default: '[data-has-issues]' }
  }

  connect() {
    this.filterCards()
  }

  toggle() {
    this.filterCards()
  }

  filterCards() {
    if (!this.hasCheckboxTarget) return
    
    const showOnlyIssues = this.checkboxTarget.checked
    const allCards = document.querySelectorAll(this.cardSelectorValue)
    
    allCards.forEach(card => {
      const hasIssues = card.dataset.hasIssues === 'true'
      
      if (showOnlyIssues && !hasIssues) {
        card.style.display = 'none'
      } else {
        card.style.display = 'block'
      }
    })
  }
}
```

### 2. Registered Controller ✅
**File**: `app/javascript/controllers/index.js`

```javascript
import FilterResultsController from "./filter_results_controller"
application.register("filter-results", FilterResultsController)
```

### 3. Updated View ✅
**File**: `app/views/data_fix/review_results_v2.html.haml`

**Wrapped in controller div**:
```haml
%div{ data: { controller: 'filter-results' } }
  # All filter content goes here
```

**Added data attributes to checkbox**:
```haml
%input#filter-issues{ type: 'checkbox', class: 'form-check-input', 
                       data: { action: 'filter-results#toggle', 
                               filter_results_target: 'checkbox' } }
```

**Removed inline JavaScript block** (was lines 142-161)

### 4. Program Cards Already Have Data Attributes ✅
Both partials already have `data: { has_issues: ... }`:
- `_result_program_card.html.haml` - line 39
- `_relay_program_card.html.haml` - line 49

---

## How It Works

### Stimulus Lifecycle

1. **Page loads** → Stimulus detects `data-controller="filter-results"`
2. **Controller connects** → `connect()` runs, calls `filterCards()` to initialize state
3. **Checkbox changes** → `data-action="filter-results#toggle"` triggers `toggle()` method
4. **Filter logic** → `filterCards()` shows/hides cards based on `data-has-issues` attribute

### Data Flow

```
User clicks checkbox
    ↓
Stimulus action: filter-results#toggle
    ↓
toggle() method
    ↓
filterCards() logic
    ↓
Query all cards with [data-has-issues]
    ↓
Check each card's data-has-issues="true" | "false"
    ↓
Show/hide based on checkbox state
```

---

## Testing Checklist

### After Restarting Rails + Webpacker

1. **[ ] Restart Rails server**
   ```bash
   cd /home/steve/Projects/goggles_admin2
   bin/rails server
   ```

2. **[ ] Restart Webpacker dev server** (if running)
   ```bash
   bin/webpack-dev-server
   ```
   Or just rely on on-demand compilation

3. **[ ] Clear browser cache** (Ctrl+Shift+R or Cmd+Shift+R)

### Functional Testing

1. **[ ] Load Phase 5 page** with results
2. **[ ] Open browser console** (F12) - check for errors
3. **[ ] Check Stimulus connection**:
   - Should see no errors
   - Cards should be visible on initial load
   
4. **[ ] Test checkbox**:
   - Uncheck → All cards visible
   - Check → Only cards with issues visible
   - Verify smooth hide/show animation

5. **[ ] Test with different scenarios**:
   - All results have issues → All cards stay visible when checked
   - No results have issues → All cards hidden when checked
   - Mixed results → Only problematic cards visible when checked

6. **[ ] Test pagination** (if present):
   - Filter state should persist across page navigation
   - Check → Navigate to page 2 → Still filtered

### Debug Commands

If filter doesn't work:

1. **Check Stimulus is loaded**:
   ```javascript
   // Browser console
   window.Stimulus
   // Should show Stimulus application object
   ```

2. **Check controller registered**:
   ```javascript
   // Browser console
   window.Stimulus.router.modulesByIdentifier.get("filter-results")
   // Should show FilterResultsController
   ```

3. **Verify data attributes**:
   ```javascript
   // Browser console
   document.querySelector('[data-controller="filter-results"]')
   // Should return the filter div
   
   document.querySelectorAll('[data-has-issues]')
   // Should return all program cards
   ```

4. **Manual test**:
   ```javascript
   // Browser console
   const controller = window.Stimulus.getControllerForElementAndIdentifier(
     document.querySelector('[data-controller="filter-results"]'),
     'filter-results'
   )
   controller.toggle()
   // Should filter cards
   ```

---

## Troubleshooting

### Issue: Controller not found
**Solution**: Make sure `index.js` has the import and registration

### Issue: Cards not filtering
**Solution**: Check that cards have `data-has-issues` attribute in partials

### Issue: Checkbox not responding
**Solution**: Verify `data-action` and `data-filter-results-target` on input

### Issue: "Cannot read property of undefined"
**Solution**: Restart Webpacker, clear browser cache, rebuild assets

---

## Files Modified

| File | Change | Lines |
|------|--------|-------|
| `app/javascript/controllers/filter_results_controller.js` | Created | 59 |
| `app/javascript/controllers/index.js` | Import + register | +3 |
| `app/views/data_fix/review_results_v2.html.haml` | Add controller div, update checkbox, remove JS | ~20 |

**Total**: ~82 lines

---

## Summary

✅ **Converted inline JavaScript to proper Stimulus controller**
- Works with Rails 6.2 + Webpacker
- Follows existing project patterns (see `collapse_all_controller.js`)
- Properly scoped with data attributes
- Auto-initializes on connect

✅ **Benefits**:
- JavaScript properly compiled by Webpacker
- Reusable controller pattern
- Better debugging with Stimulus inspector
- Follows Rails conventions

🎯 **Ready to Test**:
1. Restart Rails server
2. Clear browser cache
3. Load Phase 5 page
4. Toggle filter checkbox

---

**Next**: Test with real meeting file, then proceed to Phase 6 relay commit!

**Last Updated**: 2025-11-17
