# Phase 5 & 6 Completion Plan

**Status**: Phases 1-5 Complete ✅ | Phase 6 Ready to Implement 🚀

**Document Version**: 1.2 (2025-11-02)

---

## Overview

Complete Data-Fix pipeline by finalizing Phase 5 (Result Review) and implementing Phase 6 (Commit & SQL Generation).

### Goals

1. **Phase 5**: Hybrid storage (DB tables for results/laps), read-only review UI, entity matching
2. **Phase 6**: New `Main` strategy reading JSON (phases 1-4) + DB tables (phase 5) to generate SQL

### Key Principles

- **Hybrid Architecture**: JSON for small datasets (phases 1-4), DB tables for large datasets (phase 5)
- Phases 1-4 files contain all entity IDs needed for matching
- Phase 5 stores results/laps in temporary `data_import_*` tables (indexed, efficient)
- Phase 6 reads from both sources respecting referential integrity
- Remove broken "Use Legacy" buttons

### Architecture Update (v0.8.11) ✅

**goggles_db gem changes:**
- Created 5 temporary tables: `data_import_meeting_individual_results`, `data_import_laps`, `data_import_meeting_relay_results`, `data_import_relay_laps`, `data_import_meeting_relay_swimmers`
- All models include `TimingManageable` concern (consistent timing behavior with MIR/Lap)
- Unique `import_key` on each table for O(1) lookups
- 28 specs passing with full coverage

---

## Phase 5: Result Review Finalization

### 5.0 Phase 5 Data Population ✅

**Goal**: Populate `data_import_*` tables from source JSON.

**Implementation**:
- ✅ Created `Import::Phase5Populator` service
- ✅ Reads phases 1-4 for entity IDs
- ✅ Generates `import_key` using MacroSolver patterns
- ✅ Populates `DataImportMeetingIndividualResult` + `DataImportLap` tables
- ✅ Links swimmer_id and team_id from prior phases
- ✅ Integrated into `DataFixController#review_results`

**Flow**:
1. `ResultSolver` builds phase 5 JSON (summary/scaffold)
2. `Phase5Populator` populates DB tables (detailed data)
3. Controller queries `DataImportMeetingIndividualResult` for display

**Tasks**:
- [x] Create `Phase5Populator` service
- [x] Integrate into controller
- [ ] Add specs for populator
- [ ] Test with real data file

### 5.1 Result Display UI ✅

**Goal**: Display results from `data_import_*` tables with consistent card-based UI matching events/swimmers/teams.

**Design Requirements**:
- ✅ Use **collapsible cards** for each MeetingProgram group (category within event)
- ✅ Card borders: **green** if `meeting_program_id` exists (matched), **yellow** if new
- ✅ Card layout: **2 cards per row** on large displays (responsive grid)
- ✅ Each card contains result rows (not full cards)
- ✅ Result rows can **expand** to show lap details (collapsible sub-content)
- ✅ Background: **white/light grey** for result rows (consistent)
- ✅ Icons/badges: show match status per result (swimmer_id/team_id presence)
- ✅ Replicate look-and-feel from `_event_form_card.html.haml`
- ✅ Team name lookup by key for unmatched teams (no more "N/A")
- ✅ Display both delta and from_start timing in lap details

**Current Status** (v1 - table-based):
- ✅ Table-based display grouped by session/event/category/gender
- ✅ Visual indicators: green rows (matched), yellow rows (new)
- ✅ Shows swimmer names, teams, timings, lap splits
- ✅ Eager-loaded swimmers/teams (no N+1 queries)
- ✅ Status badges: "✓ Matched" (green), "+ New" (yellow)

**Next Iteration** (v2 - card-based):
- Replicate legacy behavior: collapsible cards per MeetingProgram
- Result rows expand to show laps (accordion within accordion)
- Match visual style of event/swimmer cards
- Responsive grid: 2 columns on large screens

**Tasks**:
- [x] ~~Table-based display~~ (v1 complete)
- [x] Test with real data in browser (v1 working)
- [x] Create card-based partial `_result_program_card.html.haml`
- [x] Add collapsible result rows with lap expansion
- [x] Match border colors and styling from event cards
- [x] Implement responsive grid layout (2 cols on lg+)
- [x] Add expand/collapse icons and interactions
- [x] Eager-load laps to avoid N+1 queries
- [x] Test card interactions in browser (v2)
- [x] Fix team "N/A" issue (lookup by key for unmatched teams)
- [x] Add lap timing computation (delta + from_start)

### 5.1.1 Lap Timing Handling 

**Challenge**: Source JSON "timing" field contains cumulative time from race start, but DB needs both delta and from_start values.

**Solution Chosen**: **Option 1 - Add missing columns to temp tables**

**Architecture**:
```
Source JSON: "timing": "1'18.56"  →  This is "from_start" (cumulative)
                ↓
         Phase5Populator
                ↓
    ┌───────────────────────────┐
    │ Compute Delta Timing      │  current_from_start - previous_from_start
    │ (using Timing wrapper)    │
    └───────────────────────────┘
                ↓
    Store in data_import_laps:
    - minutes/seconds/hundredths           (DELTA - default columns)
    - minutes_from_start/seconds_from_start/hundredths_from_start
```

**DB Changes**:
- Migration: Add `*_from_start` columns to all 3 temp tables
  - `data_import_laps`
  - `data_import_meeting_relay_swimmers`
  - `data_import_relay_laps`
- Mirrors production structure (`laps`, `meeting_relay_swimmers`, `relay_laps`)

**Computation Logic** (`Phase5Populator#create_lap_records`):
1. Parse source "timing" → store as `from_start`
2. Compute `delta = current_from_start - previous_from_start`
3. Store both values in appropriate columns
4. UI displays both: **Delta** (primary) and **From Start** (muted)

**Benefits**:
- Clean separation of delta vs cumulative timing
- Matches production table structure
- Phase 6 becomes simple copy operation (no computation)
- UI can display both values for verification
- Handles all source variations (delta-only, from_start-only, both)

**Tasks**:
- [x] Create migration in goggles_db
- [x] Update Phase5Populator lap creation logic
- [x] Add `compute_timing_delta` helper method
- [x] Update UI to display both timing values
- [ ] Run migration in test/dev environments
- [ ] Test with real data to verify delta computation
- [x] Add specs for timing computation

### 5.2 Match Existing Database Rows ✅

**Goal**: Find and display existing `MeetingEvent` and `MeetingProgram` IDs.

**Matching Logic Implemented**:

```ruby
# Step 1: Get meeting_session_id from phase 1 (by session_order)
# Step 2: Parse event_code → EventType (e.g., "200RA" → 200m Breaststroke)
# Step 3: Match MeetingEvent by (meeting_session_id, event_type_id)
# Step 4: Parse category → CategoryType (e.g., "M75")
# Step 5: Parse gender → GenderType (e.g., "F")
# Step 6: Match MeetingProgram by (meeting_event_id, category_type_id, gender_type_id)
```

**Implementation Details**:
- `Phase5Populator#find_meeting_program_id` implements full matching chain
- Helper methods: `parse_event_type`, `parse_category_type`, `parse_gender_type`
- Stroke code mapping: SL→FREE, DO→BACK, RA→BREAST, FA→FLY, MI→IND_MED
- Stats tracking: `programs_matched` counter
- Card borders: Green if `meeting_program_id` present, Yellow if new

**Tasks**:
- [x] Implement MeetingEvent matching
- [x] Implement MeetingProgram matching  
- [x] Store matched IDs in `data_import_meeting_individual_results`
- [x] Display matched IDs in card headers (green border = matched)
- [x] Add stats tracking for matched programs
- [ ] Test with real meeting data
- [x] Add specs for matching logic

### 5.3 Match Existing MeetingIndividualResult Records ✅

**Goal**: Find existing `MeetingIndividualResult` records to determine UPDATE vs INSERT operations in Phase 6.

**Matching Logic Implemented**:

```ruby
# Find existing MIR by:
# - meeting_program_id (must exist)
# - swimmer_id (must exist)
# - team_id (must exist)
# Returns: meeting_individual_result_id or nil
```

**Implementation Details**:
- `Phase5Populator#find_existing_mir` performs 3-way match
- Requires all 3 IDs to be present (foreign key integrity)
- Stores `meeting_individual_result_id` in temp table
- Stats tracking: `mirs_matched` counter
- Phase 6 will use this to decide UPDATE vs INSERT

**Decision Logic for Phase 6**:
- If `meeting_individual_result_id` present → **UPDATE** existing record
- If `meeting_individual_result_id` nil → **INSERT** new record

**Tasks**:
- [x] Implement MIR matching by (program_id, swimmer_id, team_id)
- [x] Store matched MIR ID in `data_import_meeting_individual_results`
- [x] Add stats tracking for matched MIRs
- [ ] Test with real meeting data
- [x] Add specs for matching logic

### 5.4 Result Card Content & Data Structure ✅

**Goal**: Display results efficiently, prepare for phase 6 commit.

**Phase 5 JSON Enhancement**:
```json
{
  "_meta": { "source_path": "...", "season_id": 242 },
  "result_groups": [
    {
      "event_key": "100SL",
      "event_code": "100SL",
      "category_code": "M45",
      "gender_code": "M",
      "meeting_event_id": 12345,      // ← NEW: matched from DB
      "meeting_program_id": 67890,    // ← NEW: matched from DB
      "results": [
        {
          "rank": 1,
          "swimmer_key": "ROSSI|MARIO|1978",
          "swimmer_id": 456,            // ← From phase 3
          "team_key": "CSI OBER FERRARI",
          "team_id": 789,               // ← From phase 2
          "timing": "00:58.45",
          "disqualified": false,
          "meeting_individual_result_id": null,  // ← For phase 6 matching
          "laps": [
            { "length_in_meters": 50, "timing": "00:28.12", "lap_id": null }
          ]
        }
      ]
    }
  ]
}
```

**MIR Matching Requirements** (for Phase 6):
- `meeting_program_id` must exist (requires `meeting_event_id`)
- `swimmer_id` must exist (from phase 3)
- `team_id` must exist (from phase 2)
- If all 3 present → check if MIR exists → UPDATE or INSERT

**Tasks**:
- [ ] Update phase 5 JSON structure
- [ ] Scan phase 1-4 files in `review_results` to populate IDs
- [ ] Match existing MeetingIndividualResult rows
- [ ] Update ResultDetailsCardComponent
- [ ] Add specs

### 5.4 Remove Legacy Buttons ✅

**Goal**: Clean up broken "Use Legacy" functionality.

**Tasks**:
- [ ] Remove all "Use Legacy" buttons from views
- [ ] Remove related controller actions
- [ ] Update documentation

### 5.5 Commit Button ✅

**Goal**: Add "Commit All Changes" button routing to Phase 6.

**Implementation**:
```haml
= form_tag(push_prepare_path, method: :post) do
  = hidden_field_tag(:phase1_path, @phase1_path)
  = hidden_field_tag(:phase2_path, @phase2_path)
  = hidden_field_tag(:phase3_path, @phase3_path)
  = hidden_field_tag(:phase4_path, @phase4_path)
  = hidden_field_tag(:phase5_path, @phase5_path)
  = submit_tag('Commit All Changes', class: 'btn btn-primary btn-lg',
               data: { confirm: 'Generate SQL commit file?' })
```

**Tasks**:
- [ ] Add button to review_results view
- [ ] Update routes
- [ ] Add confirmation dialog
- [ ] Test button enables when all phases complete

---

## Phase 6: Commit & SQL Generation

### 6.1 Main Architecture ✅

**Goal**: Create new committer working with phase files instead of MacroSolver.

**Class Structure**:
```ruby
module Import
  module Strategies
    class Main
      attr_reader :phase_files, :sql_log, :commit_data
      
      def initialize(phase_file_paths:)
        @phase_files = load_phase_files(phase_file_paths)
        @sql_log = []
        @commit_data = {} # Cross-phase ID mappings
      end
      
      def commit_all
        ActiveRecord::Base.transaction do
          commit_phase1_entities  # Meeting, Sessions, Pools, Cities
          commit_phase2_entities  # Teams, TeamAffiliations
          commit_phase3_entities  # Swimmers, Badges
          commit_phase4_entities  # MeetingEvents, MeetingPrograms
          commit_phase5_entities  # MIRs, MRRs, Laps
        end
      end
    end
  end
end
```

**Tasks**:
- [ ] Create `Main` class skeleton
- [ ] Implement phase file loading
- [ ] Add transaction wrapper
- [ ] Implement `commit_entity` core method
- [ ] Add SQL logging via `SqlMaker`
- [ ] Create comprehensive specs

### 6.2 Phase 1 Commits (Meeting, Sessions, Pools, Cities) ✅

**Dependency Order**: City → SwimmingPool → Meeting → MeetingSession

**Tasks**:
- [ ] Implement `commit_phase1_entities`
- [ ] Handle City commits (optional)
- [ ] Handle SwimmingPool commits
- [ ] Handle Meeting commits
- [ ] Handle MeetingSession commits
- [ ] Add change detection for UPDATEs
- [ ] Add specs

### 6.3 Phase 2 Commits (Teams, TeamAffiliations) ✅

**Dependency Order**: City → Team → TeamAffiliation

**Tasks**:
- [ ] Implement `commit_phase2_entities`
- [ ] Handle Team commits
- [ ] Auto-create TeamAffiliation for new teams
- [ ] Store team_id mappings for phase 5
- [ ] Add specs

### 6.4 Phase 3 Commits (Swimmers, Badges) ✅

**Dependency Order**: Swimmer → Badge (requires Swimmer + Team + Season + Category)

**Category Calculation**: Based on swimmer YOB and meeting date

**Tasks**:
- [ ] Implement `commit_phase3_entities`
- [ ] Handle Swimmer commits
- [ ] Handle Badge commits with category calculation
- [ ] Store swimmer_id mappings for phase 5
- [ ] Add specs

### 6.5 Phase 4 Commits (MeetingEvents, MeetingPrograms) ✅

**Dependency Order**: MeetingEvent (requires Session) → MeetingProgram (defer to phase 5)

**Note**: MeetingPrograms created in phase 5 when committing results

**Tasks**:
- [ ] Implement `commit_phase4_entities`
- [ ] Handle MeetingEvent commits
- [ ] Store meeting_event_id mappings for phase 5
- [ ] Add specs

### 6.6 Phase 5 Commits (Results, Laps) ✅

**Dependency Order**:
1. MeetingProgram (requires MeetingEvent + Category + Gender)
2. MeetingIndividualResult (requires Program + Swimmer + Team + Badge)
3. Lap (requires MIR)

**MIR Matching**:
```ruby
existing_mir = GogglesDb::MeetingIndividualResult.find_by(
  meeting_program_id: program_id,
  swimmer_id: swimmer_id,
  team_id: team_id
)
# If found → UPDATE (if changed), else → INSERT
```

**Tasks**:
- [ ] Implement `commit_phase5_entities`
- [ ] Handle MeetingProgram creation/matching
- [ ] Handle MIR commits with full hierarchy
- [ ] Handle Lap commits
- [ ] Add timing parsing helpers
- [ ] Handle MRR, RelayLap, MeetingRelaySwimmer
- [ ] Add specs

### 6.7 Change Detection & SQL Generation ✅

**Goal**: Only generate UPDATEs when attributes changed.

```ruby
def attributes_changed?(model, new_attrs)
  new_attrs.except('id').any? { |key, value| model.send(key) != value }
end

def commit_entity(model_class, attributes)
  id = attributes['id']
  if id.present?
    existing = model_class.find(id)
    if attributes_changed?(existing, attributes)
      existing.update!(attributes.except('id'))
      @sql_log << SqlMaker.new(row: existing).log_update
    end
    existing.id
  else
    new_record = model_class.create!(attributes)
    @sql_log << SqlMaker.new(row: new_record).log_insert
    new_record.id
  end
end
```

**Tasks**:
- [ ] Implement `attributes_changed?` helper
- [ ] Test with various data types
- [ ] Ensure `SqlMaker` generates correct UPDATEs
- [ ] Add specs

### 6.8 PushController Integration ✅

**Goal**: Update `PushController#prepare` to use `Main`.

**Current Flow** (Legacy):
```ruby
@committer = Import::MacroCommitter.new(solver: @solver)
@committer.commit_all
```

**New Flow**:
```ruby
@committer = Import::Committers::Main.new(
  phase_file_paths: {
    phase1: params[:phase1_path],
    phase2: params[:phase2_path],
    phase3: params[:phase3_path],
    phase4: params[:phase4_path],
    phase5: params[:phase5_path]
  }
)
@committer.commit_all
```

**SQL File Output**: Same as before, stored in `crawler/data/results.new/<season_id>/`

**Backup Files**: Move committed phase files to `crawler/data/results.done/<season_id>/`

**Tasks**:
- [ ] Update `PushController#prepare` to accept phase file paths
- [ ] Instantiate `Main` instead of `MacroCommitter`
- [ ] Keep SQL file generation logic
- [ ] Move files to `results.done` on success
- [ ] Add error handling and rollback
- [ ] Add specs

### 6.9 Error Handling & Validation ✅

**Goal**: Graceful failures with clear error messages.

**Validation Checks**:
- All required phase files present
- Phase file integrity (valid JSON, expected structure)
- Required entity IDs present (no broken references)
- Database constraints satisfied

**Error Recovery**:
- Transaction rollback on any failure
- Clear error messages for operators
- Log error details for debugging

**Tasks**:
- [ ] Add phase file validation
- [ ] Add entity hierarchy validation
- [ ] Add database constraint validation
- [ ] Implement transaction rollback
- [ ] Add error logging
- [ ] Add specs for error cases

---

## Testing Strategy

### Unit Tests
- [ ] Main initialization and phase loading
- [ ] Each `commit_phaseN_entities` method
- [ ] Change detection logic
- [ ] SQL generation via SqlMaker
- [ ] Error handling and validation

### Integration Tests
- [ ] Complete phase 1-6 workflow
- [ ] Phase file reading and ID resolution
- [ ] Database commits with referential integrity
- [ ] SQL file generation
- [ ] File movement to results.done

### Performance Tests
- [ ] Memory usage (streaming vs loading all)
- [ ] Transaction time for large result sets
- [ ] SQL file generation time

---

## Implementation Timeline

### Week 1: Phase 5 Finalization
- Day 1-2: Result card styling and matching logic
- Day 3-4: Phase 5 JSON structure updates
- Day 5: Commit button and testing

### Week 2-3: Phase 6 Implementation
- Day 1-2: Main architecture
- Day 3-4: Phase 1-2 commits
- Day 5-6: Phase 3-4 commits
- Day 7-9: Phase 5 commits (results + laps)
- Day 10: PushController integration

### Week 4: Testing & Refinement
- Day 1-2: Unit tests
- Day 3-4: Integration tests
- Day 5: Performance testing and optimization

---

## Success Criteria

- [ ] Phase 5 displays all results in collapsible cards
- [ ] Phase 5 shows matched entity IDs correctly
- [ ] Phase 6 generates valid SQL for all entities
- [ ] SQL UPDATEs only when attributes changed
- [ ] SQL INSERTs for new entities
- [ ] Transaction commits successfully for full result set
- [ ] Files moved to results.done on success
- [ ] All tests passing (unit + integration)
- [ ] Memory usage acceptable for large files
- [ ] Documentation complete

---

## Files to Create/Update

### New Files
- `app/strategies/import/committers/phase_committer.rb`
- `spec/strategies/import/committers/phase_committer_spec.rb`

### Updated Files
- `app/controllers/data_fix_controller.rb` (phase 5 matching)
- `app/controllers/push_controller.rb` (phase 6 integration)
- `app/views/data_fix/review_results.html.haml` (phase 5 view)
- `app/views/data_fix/_results_category_v2.html.haml` (card styling)
- `config/routes.rb` (push_prepare_path)

### Phase File Structure Updates
- Phase 5 JSON: Add `meeting_event_id`, `meeting_program_id`, `meeting_individual_result_id`
- All phases: Ensure consistent ID storage

---

## Phase 5 UI Improvements (Nov 2, 2025) ✅

### 1. Quick Filter for Unmatched Data
- **Phase 2 & 3**: Added "Show only unmatched" checkbox filter
- Filters teams/swimmers without assigned IDs
- Helps operators focus on remaining work
- Filter state preserved across pagination

### 2. Collapse/Expand All Results
- **Phase 5**: Added toggle button to collapse/expand all result cards
- JavaScript-based mass toggle for all result groups
- Icon changes: compress ↔ expand
- Improves navigation when reviewing many results

### 3. Preserve Pagination State on Form POST
- **Phase 2 & 3**: All edit/delete/add forms now preserve:
  - Current page number
  - Items per page setting
  - Search query
  - Filter state (unmatched)
- Prevents losing position when editing entities

### 4. Enhanced Match Scoring with Visual Indicators ✅

**Color-Coded Match Confidence:**
- **Green (90-100%)**: Excellent match - high certainty
- **Yellow (70-89%)**: Good/acceptable match  
- **Red (60-69%)**: Questionable match - requires review
- **Gray (<60%)**: Very poor match

**Implementation:**
- `SwimmerSolver`: Added fallback matching by `last_name + gender + year_of_birth` when full name match fails
- `TeamSolver`: Enhanced with color coding
- Both solvers: Lowered auto-assignment threshold from 90% to 60%
- UI: Replaced dropdowns with color-coded list groups showing confidence badges
- Auto-matching now accepts more matches, reducing manual operator work

**Fallback Matching Strategy (Swimmers):**
When no full name matches found:
1. Search by `last_name` + `gender_type_id` + `year_of_birth`
2. Handles abbreviated first names (e.g., "Mario" vs "M.")
3. Assigns confidence 50-59% to indicate fallback match
4. Limits to 5 results to avoid overwhelming UI

---

## Notes

- Legacy "Use Legacy" buttons are broken and should be removed
- Phase files can be enhanced as needed (no backward compatibility required)
- Main is completely new (no MacroCommitter compatibility needed)
- SQL generation uses existing `SqlMaker` utility
- Transaction ensures all-or-nothing commit
