# Data-Fix Pipeline Changelog

Track major changes, fixes, and milestones in the Data-Fix pipeline development.

---

## 2025-11-16: Phase 5 Critical Improvements (In Progress) 🚧

### Issue #1: DSQ Results Handling ✅
**Problem**: Disqualified (DSQ) results displayed at top with "0°" rank and zero timing, causing confusion.

**Solution**:
- **View-layer sorting**: Non-DSQ results first (sorted by rank), then DSQ results appended
- **Display updates**:
  - Rank column: Shows "-" for DSQ (instead of 0)
  - Timing column: Shows "—" (em dash) for DSQ (instead of 0'00"00)
  - Status column: Shows red "DSQ" badge (instead of check/plus icons)
- **Database**: DSQ results keep `rank=0` (unchanged)
- **Applied to**: Both individual (`_result_program_card`) and relay (`_relay_program_card`) partials

**Files Modified**:
- `app/views/data_fix/_result_program_card.html.haml`
- `app/views/data_fix/_relay_program_card.html.haml`
- `app/strategies/import/phase5_populator.rb` (comment only)

**Result**: DSQ results now correctly appear at bottom of rankings with proper visual indicators.

---

### Issue #2: Category/Gender Code Computation ✅
**Problem**: 
1. Relay gender taken from first swimmer instead of relay header (`fin_sesso`)
2. Missing swimmer genders not inferred from relay type
3. Missing categories not computed from age sums
4. Incorrect MeetingProgram grouping (e.g., M280 relay split by swimmer gender instead of relay gender)

**Solution**:
- **Created `Phase5::DataIntegrator` service** (`app/services/phase5/data_integrator.rb`)
  - Integrates and infers missing relay and individual result data
  - Uses CategoriesCache mixin for category computation

**Relay Gender Inference**:
1. Priority: `result['gender']` → `event['gender']` → infer from swimmers
2. Inference logic:
   - All female → 'F'
   - All male → 'M'
   - Mixed or unknown → 'X'
3. Supports both 4-token and 5-token lap swimmer formats

**Swimmer Gender Propagation**:
- **Non-mixed relays** (F/M): All swimmers inherit relay gender
- **Mixed relays** (X): Uses 50% rule to infer missing genders
  - Example: 2 known F swimmers → remaining 2 must be M

**Category Computation**:
- **Relays**: Compute from age sum when all YOBs present
  - Example: 4 swimmers × ~70 years → M280 or X280
- **Individuals**: Compute from YOB using CategoriesCache
  - Uses season begin_date or meeting date for age calculation
- Prefix: 'M' for male, 'F' for female, 'X' for mixed relays

**Integration Points**:
- Phase5Populator calls `data_integrator.integrate_relay_result()`
- Integrated values used for program_key generation
- Proper MeetingProgram grouping by relay gender (not swimmer gender)

**Files Created**:
- `app/services/phase5/data_integrator.rb` (new service, 420 lines)

**Files Modified**:
- `app/strategies/import/phase5_populator.rb`:
  - Added `data_integrator` initialization
  - Added `extract_season` helper method
  - Updated relay result processing to use integrated values

**Result**: Relay results now correctly grouped by relay gender/category, with proper inference of missing data.

---

### Issue #3: Phase 5 JSON Output Structure ✅
**Problem**: 
1. Phase 5 didn't output a structured JSON file with program groups
2. Phase 4 incorrectly stored gender on event level (should be genderless)
3. Program grouping by (session + event + category + gender) not persisted
4. Phase 6 couldn't properly create MeetingProgram rows
5. Results were incorrectly stored in phase5 JSON (should be in temp tables only)
6. Event codes didn't link to phase4 event keys

**Solution**:
- **Phase 5 now outputs structured JSON** with program groups (METADATA ONLY)
  - Each program group = unique (session_order + event_code + category_code + gender_code)
  - **NO results array** - results stay in temp tables (hybrid approach)
  - Tracks result_count per program
  - Links to phase4 via event_key
  - Stores meeting_program_id when matched
  
**JSON Structure** (Headers Only):
```json
{
  "name": "phase5",
  "total_programs": 12,
  "total_results": 787,
  "programs": [
    {
      "session_order": 1,
      "event_key": "S4X50MI",           // Links to phase4 events[].key
      "event_code": "S4X50MI",          // Human-readable code
      "category_code": "M100",
      "gender_code": "F",
      "meeting_program_id": 12345,
      "relay": true,
      "result_count": 70                // Count only, not full results
    },
    {
      "session_order": 1,
      "event_key": "S4X50MI",
      "event_code": "S4X50MI",
      "category_code": "M100",
      "gender_code": "M",
      "meeting_program_id": 12346,
      "relay": true,
      "result_count": 181
    }
  ]
}
```

**Key Changes**:
1. **Phase5Populator** (Hybrid Approach):
   - **Programs**: Stored in phase5 JSON (metadata/headers only)
   - **Results & Laps**: Stored in temp tables (DataImportMIR, DataImportMRR, etc.)
   - Added `@programs` hash to collect unique program headers
   - `add_to_programs()` only stores metadata + result_count (NO full results)
   - Extracts `event_key` from source to link to phase4 events
   - `write_phase5_output!()` generates JSON with program headers only
   
2. **DataFixController**:
   - Reads `@phase5_programs` from JSON (program headers)
   - Queries temp tables for actual results using `program_key` filter
   - Programs properly separated by gender (F/M/X for relays)

**Files Modified**:
- `app/strategies/import/phase5_populator.rb`:
  - Added `event_key` extraction from source events (with fallback to eventCode)
  - Modified `add_to_programs()` to store headers only (no results array)
  - Added `result_count` tracking instead of full results
  - `write_phase5_output!()` outputs metadata-only JSON
  - **Critical fix**: Use `event['key'] || event['eventCode']` for LT2 compatibility
  
- `app/strategies/import/adapters/layout2_to4.rb`:
  - **Critical fix**: Keep relay events separate by gender (F/M/X)
  - Changed grouping key from `code` to `code_gender` for relays
  - Individual events still grouped by code only
  
- `app/controllers/data_fix_controller.rb`:
  - Load programs from phase5 JSON
  - Query temp tables by program_key for actual results
  
- `app/views/data_fix/review_results_v2.html.haml`:
  - Use `result_count` instead of `results.size`
  - Query temp tables per program for display

**Result**: 
- **Hybrid storage**: Programs in JSON, results in temp tables
- **Proper entity linking**: event_key → phase4, program → results via program_key
- Phase 5 JSON stays lightweight (no 787 full results, just 12 program headers)
- Relay events correctly split by gender (F/M/X)
- Phase 6 can create MeetingPrograms from phase5 programs
- Example: "4x50MI M100" creates 3 programs: M100•F (70 results), M100•M (181 results), M100•X (27 results)

---

## 2025-11-16: Phase 5 Issue Highlighting ✅

### Issue #4: Results with Missing Data Highlighting
**Problem**: 
- Operators had no way to quickly identify results with missing critical data
- All results displayed with equal visibility (new, matched, and problematic)
- No filtering to focus on problematic results that would fail commit
- Example: Relay results with swimmers missing gender_type_code or year_of_birth

**Solution**:
- **Issue detection**: Helper methods check for missing swimmer data
  - `swimmer_has_missing_data?`: Checks phase3 swimmer for missing gender/year
  - `relay_result_has_issues?`: Scans all relay swimmers for missing data
  - Checks both matched swimmers (DB) and unmatched (phase3 data)
  
- **Visual indicators**:
  - **Red border** for cards with issues (instead of green/yellow)
  - **Red badge** showing count of missing data issues
  - **Expanded by default** (OK results collapsed)
  
- **Filtering**:
  - Checkbox toggle: "Show only results with issues"
  - Hides OK results, shows only problematic ones
  - JavaScript-based client-side filtering

**User Flow**:
1. Navigate to Phase 5 results page
2. Results with issues automatically expanded + red border
3. OK results (new/matched) collapsed by default
4. Toggle "Show only issues" to focus on problems
5. Fix missing data in Phase 3, rebuild Phase 5
6. Proceed to Phase 6 commit

**Files Modified**:
- `app/controllers/data_fix_controller.rb`:
  - Added `swimmer_has_missing_data?` helper
  - Added `relay_result_has_issues?` helper
  - Exposed helpers to views via `helper_method`
  
- `app/views/data_fix/_relay_program_card.html.haml`:
  - Check for issues using helper method
  - Apply `border-danger` class when has_issues
  - Show red badge with issue count
  - Default to `.collapse.show` only if has_issues
  - Add `data-has-issues` attribute for filtering
  
- `app/views/data_fix/review_results_v2.html.haml`:
  - Add filter checkbox toggle
  - Add JavaScript to hide/show cards based on filter

**Result**: 
- Operators can immediately spot problematic results
- Red visual indicators draw attention to issues
- Filtering reduces cognitive load (focus on problems only)
- Example: GRAZIANI Fabio with missing gender shows in red with badge "1 missing data"

---

## 2025-11-15: Documentation Reorganization & UI Improvements ✅

### Documentation Structure Refinement
**Problem**: Plans scattered across 16 files, data structures not documented, hard to navigate.

**Solution**:
- **Created `DATA_STRUCTURES.md`**: Comprehensive reference for all data formats (source JSON, phase files, DB tables)
  - Individual result structures (LT4, LT2)
  - Relay result structures (4-token & 5-token lap formats)
  - Phase file formats (1-5)
  - Temporary DB table schemas
  - Production entity relationships
  - Import key formats
  
- **Created `ROADMAP.md`**: Single consolidated development plan
  - Current sprint status
  - Milestone breakdown (1-6)
  - Task estimates and progress
  - Known issues tracker
  - Future enhancements roadmap

- **Updated `README.md`**: Streamlined navigation and quick status
  - New documentation structure diagram
  - Updated "Getting Started" paths
  - Cleaner "Next Actions" section

- **Archived historical plans**: Moved 16 plan files to `plans/archive/`
  - Kept documentation lean (7 core files)
  - Easy to browse for overview OR deep dive

**Result**: Clear, maintainable, easily browsable documentation structure.

### UI Standardization
**Phases 1, 2, 3 Visual Improvements**:

**Phase 1 (Meeting Card)**:
- Auto-collapses when all required fields filled (season_id, name, date)
- Previously only collapsed when meeting_id present
- Improves focus on sessions when meeting data complete

**Phase 2 & 3 (Teams & Swimmers)**:
- **Unified border colors**:
  - Gray (`border-secondary`): Matched entities with ID
  - Yellow (`border-warning`): New entities, all data present
  - Red (`border-danger`): Missing required data
  
- **Standardized badges**:
  - Green `ID: xxx`: Matched with confidence percentage
  - Yellow `NEW`: New entity ready to commit
  - Red `MISSING DATA`: Requires attention
  - Detailed badges: `No Name`, `No YOB`, `No Gender`
  
- **Icon system**:
  - ✓ Check (green): Matched
  - ➕ Plus (yellow): New
  - ⚠ Warning (red): Missing data
  - ✏ Edit (blue): Needs optional editing

- **Special case**: Matched swimmer with incomplete names shows yellow border + edit icon

**Files Modified**:
- `app/views/data_fix/review_sessions_v2.html.haml`
- `app/views/data_fix/_meeting_form_card.html.haml`
- `app/views/data_fix/review_swimmers_v2.html.haml`
- `app/views/data_fix/_swimmer_form_card.html.haml`
- `app/views/data_fix/review_teams_v2.html.haml`
- `app/views/data_fix/_team_form_card.html.haml`

**Result**: Consistent, intuitive visual feedback across all phases.

---

## 2025-11-14: Phase 3 Relay Enrichment Complete ✅

### Relay Swimmer Matching Fixed
**Problem**: Swimmers with `swimmer_id` still appearing in enrichment list, case-sensitivity issues, malformed lap data.

**Root Causes Identified**:
1. **Case-sensitivity**: Phase 3 key `"CORTI|Delia|1938"` vs source `"CORTI|DELIA|1938"` didn't match
2. **Lap format parsing bug**: System assumed 5-token format (GENDER|LAST|FIRST|YEAR|TEAM) but data had both:
   - 5-token: `"F|PAGLI|Linda|1950|DLF Nuoto Livorno"` ✓
   - 4-token: `"CORTI|Delia|1938|DLF Nuoto Livorno"` ❌ (parsed as FIRST|YEAR|TEAM|X)

**Solutions Implemented**:
1. **Case-insensitive matching** in `RelayEnrichmentDetector`:
   - Added `@phase3_by_key_normalized` hash (lowercase keys)
   - Match tries: exact → normalized → name-only
   
2. **Smart lap format detection**:
   - Check if first token is gender code ("M", "F", "X")
   - If gender + 5 tokens → parse as GENDER|LAST|FIRST|YEAR|TEAM
   - Else 4+ tokens → parse as LAST|FIRST|YEAR|TEAM
   - Handles missing gender gracefully
   
3. **Controller filter enhancement**:
   - Build Set of swimmer keys with IDs (normalized)
   - Case-insensitive lookup when filtering
   - Double-check both phase3_swimmer object AND key lookup

**Files Modified**:
- `app/services/phase3/relay_enrichment_detector.rb`
- `app/controllers/data_fix_controller.rb`

**Result**: 
- Enrichment list correctly excludes all matched swimmers (163 → ~30)
- Handles both lap data formats
- Case-insensitive matching throughout
- CORTI Delia no longer in enrichment (has swimmer_id: 17724)

---

## 2025-11-10: Relay Event Recognition Fixed ✅

### EventSolver Relay Support
**Problem**: Relay events were completely skipped, causing empty phase4 output for relay-only files.

**Solution**:
- Implemented relay-only file detection
- Added Italian title parsing: `"4x50 m Misti"` → `[200, "MI", "S4X50MI"]`
- Added LT4 relay event code parsing
- Implemented gender-based event grouping (F, M, X)
- Added EventType matching with `relay: true` flag

**Result**:
```
Before: 23 sections → 23 sessions, 0-23 unmatched events ❌
After:  23 sections → 1 session, 3 events (F/M/X), all matched ✅
```

**Files Modified**:
- `app/strategies/import/solvers/event_solver.rb` (+150 lines)
- `spec/strategies/import/solvers/event_solver_spec.rb` (3 specs updated)

### ResultSolver Relay Support
**Problem**: Phase5 JSON was empty for relay files.

**Solution**:
- Applied same relay detection logic as EventSolver
- Added relay result counting per gender group
- Preserved relay metadata in phase5 JSON

**Result**: Phase5 JSON now includes relay event structure with result counts.

**Files Modified**:
- `app/strategies/import/solvers/result_solver.rb` (+140 lines)

### Documentation
**Created**:
- `docs/data_fix/FIXES_progress_and_relay_events.md` - Detailed fix summary
- `docs/data_fix/README_CURRENT_STATUS.md` - Current status overview
- `docs/data_fix/PHASE6_RELAY_COMPLETION_ROADMAP.md` - 15-21h implementation plan

**Updated**:
- `docs/data_fix/phase5_and_6_completion_plan.md` - Added relay status
- `docs/data_fix/phase5_relay_display_task_list.md` - Updated foundation status
- `docs/data_fix/phase6_implementation_plan.md` - Added relay commit section

### Test Results
- All 60 solver specs passing ✅
- Empty sections edge case fixed
- Relay processing specs updated

---

## 2025-11-04: Phase 6 Individual Results Complete ✅

### Main Committer Implementation
**Achievement**: Full Phase 6 commit working for individual results.

**Features**:
- Hybrid data sources (JSON for phases 1-4, DB for phase 5)
- Dependency-aware commit order
- Transaction safety (all-or-nothing)
- SQL log generation
- File movement to `results.done/`

**Files Created**:
- `app/strategies/import/committers/main.rb` - Core committer (~950 lines)
- `spec/strategies/import/committers/main_spec.rb` - Comprehensive specs

**Commit Methods**:
- ✅ `commit_city`
- ✅ `commit_swimming_pool`
- ✅ `commit_meeting`
- ✅ `commit_meeting_session`
- ✅ `commit_team`
- ✅ `commit_team_affiliation`
- ✅ `commit_swimmer`
- ✅ `commit_badge`
- ✅ `commit_meeting_event`
- ✅ `commit_meeting_individual_result`
- ✅ `commit_lap`

### UI Integration
- Added "Commit" button on Phase 5 review page
- Confirmation dialog
- Success/error flash messages
- Redirect to push dashboard

**Files Modified**:
- `app/controllers/data_fix_controller.rb` - Added `commit_phase6` action
- `app/views/data_fix/review_results_v2.html.haml` - Added commit button
- `config/routes.rb` - Added phase6 commit route

---

## 2025-11-03: Pre-Matching Pattern Established ✅

### Architecture Shift (v2.0)
**Philosophy**: "Solve Early, Commit Later"

**Benefits**:
- 77% less code in Phase 6 commit layer
- 93% fewer database queries
- Early error detection (users see issues during phase building)
- Self-contained phase files (no cross-phase lookups)

### Phase 2: Team Affiliation Pre-Matching
**Implementation**: Match existing `TeamAffiliation` during Phase 2 building, store `team_affiliation_id` in phase2.json.

**Files Modified**:
- `app/strategies/import/solvers/team_solver.rb`
- `docs/data_fix/phase2_affiliation_matching.md` (created)

### Phase 3: Badge Pre-Matching + Category Calculation
**Implementation**: 
- Match existing `Badge` during Phase 3 building
- Calculate `category_type_id` using `CategoriesCache`
- Store both in phase3.json

**Files Modified**:
- `app/strategies/import/solvers/swimmer_solver.rb`
- `docs/data_fix/phase3_badge_matching.md` (created)

### Phase 4: Meeting Event Pre-Matching
**Implementation**: Match existing `MeetingEvent` during Phase 4 building, store `meeting_event_id` in phase4.json.

**Files Modified**:
- `app/strategies/import/solvers/event_solver.rb`
- `docs/data_fix/phase4_event_matching.md` (created)

### Documentation
**Created**:
- `docs/data_fix/pre_matching_pattern_complete.md` - Pattern overview
- `docs/data_fix/phase6_integration_with_prematching.md` - Phase 6 integration guide

---

## 2025-11-02: Phase 5 Hybrid Storage ✅

### Architecture Decision
**Problem**: Phase 5 results can have 10,000+ rows per meeting - JSON files would be 10-50 MB.

**Solution**: Use DB tables (`data_import_*`) instead of JSON for Phase 5.

### goggles_db Gem Changes (v0.8.11+)
**Created 5 temporary tables**:
- `data_import_meeting_individual_results`
- `data_import_laps`
- `data_import_meeting_relay_results`
- `data_import_relay_swimmers`
- `data_import_relay_laps`

**Features**:
- Unique `import_key` for O(1) lookups
- `TimingManageable` concern for consistent timing behavior
- `*_from_start` columns for cumulative timing
- 28 specs with full coverage

### Phase5Populator Implementation
**Created**: `app/strategies/import/phase5_populator.rb`

**Features**:
- Reads phases 1-4 for entity IDs
- Generates `import_key` using MacroSolver patterns
- Populates `DataImportMeetingIndividualResult` + `DataImportLap` tables
- Matches existing `MeetingIndividualResult` for UPDATE vs INSERT decision

**Files Created**:
- `app/strategies/import/phase5_populator.rb`
- `spec/strategies/import/phase5_populator_spec.rb`

### Result Display UI
**Version 1** (table-based): ✅ Complete  
**Version 2** (card-based): ✅ Complete

**Partials Created**:
- `app/views/data_fix/_result_program_card.html.haml`
- `app/views/data_fix/_results_category_v2.html.haml`
- `app/views/data_fix/review_results_v2.html.haml`

**Features**:
- Collapsible cards per MeetingProgram
- Expandable result rows with lap details
- Match status indicators (green/yellow borders)
- Responsive grid (2 columns on large screens)
- Eager loading (no N+1 queries)

---

## 2025-10-06: Phase 3 Relay Enrichment ✅

### Relay Swimmer Matching Workflow
**Purpose**: Enrich relay events with swimmer data per leg position.

**Components**:
- `RelayEnrichmentDetector` - Scans for incomplete relay legs
- `RelayMergeService` - Merges auxiliary phase3 files
- Accordion UI on Phase 3 review page
- "Scan & Merge" button

**Files Created**:
- `app/services/phase3/relay_enrichment_detector.rb`
- `app/services/phase3/relay_merge_service.rb`
- `app/views/data_fix/_relay_enrichment_panel.html.haml`

**Documentation**:
- `docs/data_fix/phase3_relay_enrichment_task_list.md`

---

## 2025-09-15: Fuzzy Matching Thresholds Adjusted

### Team Matching
**Changed**: Auto-assignment threshold from 90% → 60%

**Reason**: 90% was too strict - many valid matches required manual review.

**Impact**: Significantly reduced manual work for common team variations.

**Files Modified**:
- `app/strategies/import/solvers/team_solver.rb#auto_assignable?`

### Swimmer Matching
Similar threshold adjustments for swimmer fuzzy matching.

---

## 2025-08-20: Phase 1-4 Initial Implementation ✅

### Phase 1: Meeting & Sessions
- Meeting metadata import
- Session management
- Venue/city handling

### Phase 2: Teams
- Team fuzzy matching (Jaro-Winkler)
- Manual team assignment UI
- TeamAffiliation placeholder

### Phase 3: Swimmers & Badges
- Swimmer exact matching
- Manual swimmer assignment UI
- Badge placeholder

### Phase 4: Events
- Event deduplication within sessions
- EventType matching by code
- MeetingEvent placeholder

**Initial Files Created**:
- `app/strategies/import/solvers/phase1_solver.rb`
- `app/strategies/import/solvers/team_solver.rb`
- `app/strategies/import/solvers/swimmer_solver.rb`
- `app/strategies/import/solvers/event_solver.rb`
- Views for all 4 phases

---

## Migration from Legacy v1.0

### What Changed

**v1.0 (Legacy)**:
- Single MacroSolver monolith
- All matching at commit time
- Phase files were simple data dumps
- Phase 6 had complex lookup logic

**v2.0 (Current)**:
- Phased solvers (separation of concerns)
- Pre-matching pattern (matching at build time)
- Self-contained phase files (all IDs resolved)
- Phase 6 is pure persistence

### Migration Path
Legacy documentation preserved in `docs/data_fix/legacy_version/` for reference.

---

## Upcoming Changes

### Phase 5 Relay Population (In Progress)
**ETA**: 4-6 hours  
**Status**: Phase 4 & 5 solvers ✅, Populator 🎯 next

### Phase 5 Relay UI (Planned)
**ETA**: 3-4 hours  
**Dependencies**: Populator completion

### Phase 6 Relay Commits (Planned)
**ETA**: 6-8 hours  
**Dependencies**: Phase 5 relay complete

**See**: [plans/PHASE6_RELAY_COMPLETION_ROADMAP.md](./plans/PHASE6_RELAY_COMPLETION_ROADMAP.md)

---

## Version History

- **v2.1** (2025-11-10) - Relay event recognition
- **v2.0** (2025-11-03) - Pre-matching pattern established
- **v1.5** (2025-11-02) - Hybrid storage (Phase 5 DB tables)
- **v1.0** (2025-08-20) - Initial phased implementation
- **v0.x** (Legacy) - MacroSolver monolith

---

**For current status**, see [README.md](./README.md)  
**For detailed plans**, see [plans/](./plans/)
