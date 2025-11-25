# Phase 3 Category Unification Refactor

## Overview

This document describes the refactoring that unified category computation and missing data detection in Phase 3 (Swimmers & Badges), consolidating redundant code and improving the enrichment UI.

## Goals

1. **Store individual category data on swimmer entries** (not just badges)
2. **Compute categories in both `SwimmerSolver` and `RelayEnrichmentDetector`** using shared logic
3. **Unify the enrichment panel** to show all missing data (year, gender, category) in one place
4. **Remove redundant code** and improve maintainability
5. **Update specs** to ensure all tests pass

## Changes Made

### 1. Created Shared Category Computation Module

**File:** `app/strategies/import/category_computer.rb`

- New module `Import::CategoryComputer` with shared category resolution logic
- Two methods:
  - `compute_category`: Uses `CategoriesCache` to find category based on age (yob + meeting_date)
  - `compute_category_from_swimmer`: Fallback using `Swimmer#latest_category_type`
- Reused by both `SwimmerSolver` and `RelayEnrichmentDetector`

### 2. Updated SwimmerSolver

**File:** `app/strategies/import/solvers/swimmer_solver.rb`

**Changes:**
- `build_swimmer_entry`: Now computes and stores `category_type_id` and `category_type_code` on each swimmer
- `build_badge_entry`: Simplified to use `CategoryComputer` directly
- Removed obsolete `calculate_category_type` method

**Phase 3 Data Structure (swimmers):**
```json
{
  "key": "LAST|FIRST|1975",
  "last_name": "LAST",
  "first_name": "FIRST",
  "year_of_birth": 1975,
  "gender_type_code": "M",
  "complete_name": "LAST FIRST",
  "swimmer_id": 123,
  "category_type_id": 456,      // NEW
  "category_type_code": "M45",  // NEW
  "fuzzy_matches": [...]
}
```

**Phase 3 Data Structure (badges):**
```json
{
  "swimmer_key": "LAST|FIRST|1975",
  "team_key": "Team Name",
  "season_id": 242,
  "swimmer_id": 123,
  "team_id": 456,
  "category_type_id": 789,
  "category_type_code": "M45",
  "number": "?",
  "badge_id": null
}
```

### 3. Updated RelayEnrichmentDetector

**File:** `app/services/phase3/relay_enrichment_detector.rb`

**Changes:**
- Constructor now accepts `season` and `meeting_date` parameters
- Initializes `@categories_cache` when season is provided
- `build_leg`: Computes `category_type_id` and `category_type_code` for each relay leg
- `detect_issues_for`: Now includes `missing_category` flag in issues

**Issue Detection:**
- `missing_year_of_birth`: Year of birth is missing or zero
- `missing_gender`: Gender code is blank
- `missing_swimmer_id`: Swimmer exists in Phase 3 but has no DB ID (new swimmer)
- `missing_category`: **NEW** - Has year+gender but no category resolved

### 4. Updated Controller

**File:** `app/controllers/data_fix_controller.rb`

**Changes:**
- `review_swimmers`: Extracts season and meeting_date from Phase 1 data
- Passes season and meeting_date to `RelayEnrichmentDetector`
- **Removed** `build_phase3_category_issues_summary` helper (obsolete)
- **Removed** `@category_issues_summary` instance variable

### 5. Unified Enrichment Panel

**File:** `app/views/data_fix/_relay_enrichment_panel.html.haml`

**Changes:**
- Updated title from "Relay Enrichment" to **"Phase 3: Missing Swimmer Data"**
- Updated description to reflect unified scope
- Added `missing_category` to `issue_labels`
- Panel now shows all missing data issues regardless of source (relay or individual)

**Deleted:**
- `app/views/data_fix/_category_issues_panel.html.haml` (obsolete)

### 6. Updated View

**File:** `app/views/data_fix/review_swimmers_v2.html.haml`

**Changes:**
- Removed separate `category_issues_panel` render
- Unified enrichment now shown via `relay_enrichment_panel` only

### 7. Updated Specs

**Files:**
- `spec/strategies/import/solvers/swimmer_solver_spec.rb`
- `spec/requests/data_fix_controller_phase3_spec.rb`

**Changes:**
- Added spec: `stores category_type_id on swimmers when category can be calculated`
- Updated spec: `stores category_type_id on badges...` to also verify `category_type_code`
- Updated phase3 controller specs to check for new panel title

## Benefits

1. **Reduced Redundancy:**
   - Single source of truth for category computation (`CategoryComputer`)
   - No duplicate logic between `SwimmerSolver` and enrichment detector
   
2. **Improved Data Quality:**
   - Category data available earlier (on swimmers, not just badges)
   - Consistent category resolution across all Phase 3 processing

3. **Better UX:**
   - Unified enrichment panel shows all missing data issues
   - No confusion between separate relay and category panels
   - Clear indication of what data is missing and why

4. **Maintainability:**
   - Shared module easier to test and maintain
   - Less code duplication
   - Clear separation of concerns

## Migration Path

To regenerate Phase 3 data with new category fields:

```bash
# In Rails console or via UI
season = GogglesDb::Season.find(242)
solver = Import::Solvers::SwimmerSolver.new(season: season)
solver.build!(
  source_path: '/path/to/meeting.json',
  lt_format: 4,
  phase1_path: '/path/to/meeting-phase1.json',
  phase2_path: '/path/to/meeting-phase2.json'
)
```

Phase 3 JSON will now include:
- `category_type_id` and `category_type_code` on **swimmers**
- `category_type_id` and `category_type_code` on **badges**
- Missing category issues shown in unified enrichment panel

## Testing

All existing specs pass:
- `spec/strategies/import/solvers/swimmer_solver_spec.rb` (7 examples, 0 failures)
- `spec/requests/data_fix_controller_phase3_spec.rb` (37 examples, 0 failures)

## Future Enhancements

1. Add localization for panel title and descriptions
2. Consider adding category enrichment from auxiliary files (similar to year/gender)
3. Add visual indicators in swimmer cards when category is missing
