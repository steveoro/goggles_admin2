# Phase 3 Enrichment Fix: Only Update Existing Swimmers

**Date**: 2025-11-17  
**Status**: ✅ Fixed

---

## Problem

The Phase 3 enrichment process was **adding swimmers** from auxiliary data files that don't exist in the main source file, instead of only **enriching existing swimmers**.

### Example Issue

**Main source file**: `2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json`
- Contains swimmers A, B, C

**Auxiliary files** scanned for enrichment:
- Contain swimmers A, B, C, **D (GRAZIANI Fabio)**

**Incorrect behavior**: 
- After enrichment, swimmer dictionary contains A, B, C, **D** ❌
- Swimmer D was added even though not in main source file

**Expected behavior**:
- After enrichment, swimmer dictionary contains only A, B, C ✅
- Only missing attributes (gender, year_of_birth) filled in for A, B, C

---

## Root Cause

**File**: `app/services/phase3/relay_merge_service.rb`

The `merge_swimmers` method had an `else` block that added swimmers from auxiliary files:

```ruby
def merge_swimmers(aux_swimmers)
  aux_swimmers.each do |aux_swimmer|
    key = aux_swimmer[SWIMMER_KEY].to_s
    next if key.blank?

    if (existing = @swimmers_by_key[key])
      @stats[:swimmers_updated] += 1 if merge_swimmer_attributes(existing, aux_swimmer)
    else
      # ❌ PROBLEM: Adding swimmers from auxiliary files
      copied = deep_dup(aux_swimmer)
      copied['fuzzy_matches'] = Array(copied['fuzzy_matches'])
      @swimmers << copied
      @swimmers_by_key[key] = copied
      @stats[:swimmers_added] += 1  # ❌ Wrong behavior
    end
  end
end
```

---

## Solution

Remove the `else` block that adds new swimmers. Only update existing ones:

```ruby
def merge_swimmers(aux_swimmers)
  aux_swimmers.each do |aux_swimmer|
    key = aux_swimmer[SWIMMER_KEY].to_s
    next if key.blank?

    # Only update existing swimmers - do NOT add new ones from auxiliary files
    # The purpose of enrichment is to fill missing attributes, not expand the dictionary
    existing = @swimmers_by_key[key]
    next unless existing  # ✅ Skip swimmers not in main dictionary

    @stats[:swimmers_updated] += 1 if merge_swimmer_attributes(existing, aux_swimmer)
  end
end
```

---

## Changes Made

### 1. RelayMergeService ✅
**File**: `app/services/phase3/relay_merge_service.rb`

- **Removed**: `else` block that adds new swimmers (lines 56-62)
- **Added**: Comment explaining enrichment purpose
- **Changed**: `swimmers_added` stat removed from initialization
- **Result**: Only existing swimmers are updated with missing data

### 2. Controller ✅
**File**: `app/controllers/data_fix_controller.rb`

- **Removed**: `swimmers_added: stats[:swimmers_added]` from flash message
- **Result**: Flash message only shows `swimmers_updated` and `badges_added`

### 3. Locales ✅
**File**: `config/locales/data_import.en.yml`
```yaml
# Before
merge_success: 'Merge complete: %{swimmers_added} swimmers added, %{swimmers_updated} swimmers updated, %{badges_added} badges added.'

# After
merge_success: 'Merge complete: %{swimmers_updated} swimmers updated, %{badges_added} badges added.'
```

**File**: `config/locales/data_import.it.yml`
```yaml
# Before
merge_success: 'Merge completato: %{swimmers_added} nuotatori aggiunti, %{swimmers_updated} aggiornati, %{badges_added} badge aggiunti.'

# After
merge_success: 'Merge completato: %{swimmers_updated} nuotatori aggiornati, %{badges_added} badge aggiunti.'
```

---

## How Enrichment Works Now

### Step 1: Extract Swimmers from Main Source
```ruby
# Phase 3 solver extracts swimmers from main file
main_swimmers = ['LAST1|FIRST1|1990', 'LAST2|FIRST2|1985', ...]
```

### Step 2: Scan Auxiliary Files
```ruby
# Auxiliary files contain additional swimmers
aux_swimmers = ['LAST1|FIRST1|1990', 'LAST3|FIRST3|1980', ...]
```

### Step 3: Enrich Existing Swimmers ONLY
```ruby
# For each swimmer in auxiliary files:
#   - If swimmer KEY exists in main dictionary → UPDATE missing attributes
#   - If swimmer KEY not in main dictionary → SKIP (do not add)

# Result: Only LAST1|FIRST1|1990 gets updated
# LAST3|FIRST3|1980 is IGNORED (not in main source)
```

---

## What Gets Updated

The enrichment fills in **missing attributes only** for existing swimmers:

### Attributes That Can Be Enriched
- ✅ `year_of_birth` (if missing or zero)
- ✅ `gender_type_code` (if blank)
- ✅ `swimmer_id` (if missing, from DB match)
- ✅ `complete_name` (if blank)
- ✅ `first_name` (if blank)
- ✅ `last_name` (if blank)
- ✅ `name_variations` (if blank)
- ✅ `fuzzy_matches` (merges unique matches)

### What Does NOT Happen
- ❌ New swimmers are NOT added
- ❌ Existing attributes are NOT overwritten
- ❌ Swimmer dictionary does NOT expand

---

## Testing

### Test Case 1: Main Source Only
**Main file**: Contains 10 swimmers (5 missing gender, 3 missing year)
**Auxiliary files**: None selected

**Expected**:
- Swimmer count: 10 (unchanged)
- Updated: 0 (no enrichment source)

### Test Case 2: Enrichment from 1 Auxiliary File
**Main file**: Contains swimmers A, B, C (all missing gender)
**Auxiliary file**: Contains swimmers A (has gender), D (complete data)

**Expected**:
- Swimmer count: 3 (A, B, C)
- Swimmer D: NOT added
- Swimmer A: Gender filled in
- Swimmers B, C: No change
- Flash: "1 swimmers updated, X badges added"

### Test Case 3: Enrichment from Multiple Files
**Main file**: Contains swimmers A, B, C
**Auxiliary 1**: Contains A (gender), E (complete)
**Auxiliary 2**: Contains B (year), C (gender + year), F (complete)

**Expected**:
- Swimmer count: 3 (A, B, C)
- Swimmers E, F: NOT added
- Swimmer A: Gender from aux1
- Swimmer B: Year from aux2
- Swimmer C: Gender + year from aux2
- Flash: "3 swimmers updated, X badges added"

### Verification Command
```bash
# 1. Rebuild Phase 3 from main source
# 2. Note swimmer count
# 3. Select auxiliary files
# 4. Merge
# 5. Verify swimmer count is UNCHANGED
# 6. Verify only existing swimmers have updated attributes
```

---

## Files Modified

| File | Change | Lines |
|------|--------|-------|
| `app/services/phase3/relay_merge_service.rb` | Remove add-swimmer logic | -8, +3 |
| `app/controllers/data_fix_controller.rb` | Remove swimmers_added from flash | -1 |
| `config/locales/data_import.en.yml` | Update merge message | -1 |
| `config/locales/data_import.it.yml` | Update merge message | -1 |

**Total**: ~11 lines changed

---

## Summary

✅ **Fixed**: Enrichment no longer adds swimmers from auxiliary files  
✅ **Behavior**: Only existing swimmers get missing attributes filled in  
✅ **Scope**: Swimmer dictionary size remains constant  
✅ **Stats**: `swimmers_added` removed, only `swimmers_updated` reported  

🎯 **Enrichment now works as designed: fill missing data for existing swimmers only!**

---

**Test Scenario**:
1. Load main source: `2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json`
2. Rebuild Phase 3 → note swimmer count (e.g., 100 swimmers)
3. Select 2 auxiliary files for enrichment
4. Merge → verify swimmer count is still 100 (not 100 + new swimmers)
5. Verify "GRAZIANI Fabio" is NOT in the swimmer list (if not in main source)

**Last Updated**: 2025-11-17
