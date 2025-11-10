# Phase 5 Relay Display - Task List & Status

**Date Created**: 2025-11-08  
**Feature**: Phase 5 relay result display with collapsible cards and lap details

---

## Overview

Extend Phase 5 result review UI to display relay results alongside individual results. Currently, `Phase5Populator` explicitly **skips relay events** (line 75: `next if event['relay'] == true`). This feature will populate relay data into temporary tables (`data_import_meeting_relay_results`, `data_import_relay_laps`, `data_import_meeting_relay_swimmers`) and render them in the UI using partials similar to individual results.

---

## Current Status

### ✅ Infrastructure Ready
- [x] **Temporary DB tables exist** (goggles_db v0.8.11+)
  - `data_import_meeting_relay_results` - Relay result headers
  - `data_import_relay_laps` - Individual relay lap splits
  - `data_import_meeting_relay_swimmers` - Relay leg swimmers
  - All include `TimingManageable` concern
  - Unique `import_key` for O(1) lookups
  - `*_from_start` timing columns added

- [x] **Phase 5 JSON structure supports relays**
  - Source Microplus JSON contains relay results in `events` with `relay: true`
  - Raw relay data includes leg details, swimmer names, split times

- [x] **Individual results display working**
  - Card-based UI with collapsible rows
  - Lap expansion accordion
  - Match status indicators (green/yellow borders)
  - Eager loading to avoid N+1 queries
  - Partials: `_result_program_card.html.haml`, `_results_category_v2.html.haml`

### ❌ Missing Components

#### 1. Phase5Populator Relay Support
**Status**: 🔴 NOT IMPLEMENTED  
**Current Code**: Lines 75-76 in `app/strategies/import/phase5_populator.rb`
```ruby
next if event['relay'] == true # Skip relay events for now
```

**Required Changes**:
- Remove skip logic for relay events
- Add `populate_relay_results` method parallel to `populate_individual_results`
- Parse relay legs from source JSON (Microplus layout-4 format)
- Extract swimmer names, split times, lap data per leg
- Match relay teams to `team_id` from Phase 2
- Match relay swimmers to `swimmer_id` from Phase 3 (if available)
- Generate `import_key` for relays using pattern: `"#{meeting_code}-#{session_order}-#{event_code}-#{team_key}"`
- Store relay data in temp tables

#### 2. Relay Result Display UI
**Status**: 🔴 NOT IMPLEMENTED  
**Required Partials**:
- `_relay_result_program_card.html.haml` - Relay program card (parallel to `_result_program_card`)
- `_relay_result_row.html.haml` - Individual relay result with expandable leg details
- `_relay_leg_details.html.haml` - Swimmer and lap info per relay leg

**UI Requirements**:
- **Card per relay program** (e.g., "4x100m Freestyle Relay - M45")
- **Border colors**: Green if `meeting_program_id` matched, Yellow if new
- **Each relay result row** shows:
  - Rank
  - Team name (lookup from Phase 2 if unmatched)
  - Total timing
  - Relay type (4x50, 4x100, 4x200, etc.)
  - Match status badges (team_id, meeting_program_id)
- **Expandable leg details** showing:
  - Leg order (1, 2, 3, 4)
  - Swimmer name (or "Unknown" if no swimmer_id)
  - Stroke type (if available in source)
  - Split timing (delta + from_start)
  - Cumulative timing
- **Responsive grid**: 2 cards per row on large screens
- **Consistent styling** with individual result cards

#### 3. Controller Integration
**Status**: 🔴 NOT IMPLEMENTED  
**Required Changes in `DataFixController#review_results`**:
- Query `DataImportMeetingRelayResult` alongside `DataImportMeetingIndividualResult`
- Eager load associations: `relay_laps`, `meeting_relay_swimmers`
- Group relay results by program (session/event/category/gender)
- Pass `@relay_result_groups` to view
- Handle pagination for relay results separately or combined

#### 4. Relay Matching Logic
**Status**: 🔴 NOT IMPLEMENTED  
**Required Matching**:
- **MeetingProgram** matching for relays:
  - Parse event code → EventType (e.g., "4X100SL" → 4x100m Freestyle relay)
  - Match by `(meeting_session_id, event_type_id, category_type_id, gender_type_id)`
  - EventType must have `relay: true`
- **Team** matching:
  - Use `team_id` from Phase 2 if available
  - Lookup team by key if not matched
- **Swimmer** matching (per leg):
  - Use `swimmer_id` from Phase 3 if available
  - Display name from source JSON if not matched
  - Flag incomplete swimmer data (for Phase 3 relay enrichment workflow)

---

## Implementation Plan

### Step 1: Extend Phase5Populator for Relays
**Priority**: HIGH  
**Estimated Time**: 4-6 hours  
**Dependencies**: None

**Tasks**:
- [ ] Remove relay skip logic (line 75-76)
- [ ] Create `populate_relay_results(event)` method
- [ ] Parse Microplus layout-4 relay structure:
  - Extract relay type from `event['type']` or `event['event_code']`
  - Parse relay results from `event['rows']`
  - Extract leg details from result structure
- [ ] Implement `create_relay_result_record(result_data)`
- [ ] Implement `create_relay_swimmer_records(relay_result_id, leg_data)`
- [ ] Implement `create_relay_lap_records(relay_result_id, lap_data)`
- [ ] Generate import_key: `"#{meeting_code}-#{session}-#{event}-#{team}"`
- [ ] Match `meeting_program_id` for relay programs
- [ ] Match `team_id` from Phase 2
- [ ] Match `swimmer_id` per leg from Phase 3
- [ ] Compute delta timing for relay laps
- [ ] Store `from_start` timing in `*_from_start` columns
- [ ] Track stats: `relay_results_created`, `relay_laps_created`, `relay_swimmers_created`
- [ ] Add error handling for malformed relay data

**Relay JSON Structure Reference** (Microplus layout-4):
```json
{
  "type": "relay",
  "relay": true,
  "event_code": "4X100SL",
  "sessionOrder": 1,
  "category": "M45",
  "gender": "M",
  "rows": [
    {
      "rank": 1,
      "team": "CSI OBER FERRARI",
      "timing": "3:45.12",
      "legs": [
        {
          "order": 1,
          "swimmer": "ROSSI|MARIO|1978",
          "stroke": "SL",
          "timing": "00:56.23",
          "laps": [
            {"length": 50, "timing": "00:27.45"},
            {"length": 50, "timing": "00:56.23"}
          ]
        },
        // ... more legs
      ]
    }
  ]
}
```

### Step 2: Create Relay Result UI Partials
**Priority**: HIGH  
**Estimated Time**: 3-4 hours  
**Dependencies**: Step 1

**Tasks**:
- [ ] Create `_relay_result_program_card.html.haml`
  - Card header with program details (event, category, gender)
  - Border color based on `meeting_program_id` presence
  - Collapse/expand button
  - Result count badge
- [ ] Create `_relay_result_row.html.haml`
  - Rank, team name, timing
  - Match status badges
  - Expand button for leg details
  - Collapsible leg details container
- [ ] Create `_relay_leg_details.html.haml`
  - Table with leg order, swimmer name, stroke, split timing
  - Color-coded swimmer match status
  - Lap sub-details if needed
- [ ] Add relay card rendering to `review_results_v2.html.haml`
- [ ] Style with Bootstrap 4 classes matching individual cards
- [ ] Add JavaScript for collapse/expand interactions
- [ ] Test responsive layout (2 cols on lg+ screens)

### Step 3: Update Controller and Query Logic
**Priority**: HIGH  
**Estimated Time**: 2-3 hours  
**Dependencies**: Steps 1, 2

**Tasks**:
- [ ] Update `DataFixController#review_results` action
  - Query relay results: `DataImportMeetingRelayResult.where(season_id:)`
  - Eager load: `includes(:meeting_relay_swimmers, :relay_laps)`
  - Group by program (session/event/category/gender)
  - Sort by rank within each group
- [ ] Pass `@relay_result_groups` to view
- [ ] Add stats: `@relay_results_count`, `@relay_programs_count`
- [ ] Handle empty relay results (don't show relay section if none)
- [ ] Test with Phase 5 populator integration

### Step 4: Add Relay Matching Logic
**Priority**: MEDIUM  
**Estimated Time**: 3-4 hours  
**Dependencies**: Step 1

**Tasks**:
- [ ] Implement `find_relay_event_type(event_code)` helper
  - Parse event code: "4X100SL" → distance=100, stroke=SL, relay=true
  - Match EventType with `relay: true` flag
- [ ] Implement `find_relay_meeting_program` helper
  - Match by (session_id, event_type_id, category, gender)
  - Store `meeting_program_id` if found
- [ ] Add relay program creation logic for Phase 6 prep
- [ ] Display match status in UI (green border if matched)
- [ ] Add specs for relay matching logic

### Step 5: Testing & Validation
**Priority**: HIGH  
**Estimated Time**: 2-3 hours  
**Dependencies**: Steps 1-4

**Tasks**:
- [ ] Create test fixtures with relay data
- [ ] Unit test `Phase5Populator#populate_relay_results`
- [ ] Unit test relay matching helpers
- [ ] Request spec for `review_results` with relays
- [ ] Manual browser test with real Microplus relay file
- [ ] Verify lap timing computation (delta + from_start)
- [ ] Verify team/swimmer matching
- [ ] Test UI interactions (expand/collapse)
- [ ] Performance test with 50+ relay results

### Step 6: Documentation
**Priority**: MEDIUM  
**Estimated Time**: 1 hour  
**Dependencies**: Steps 1-5

**Tasks**:
- [ ] Update `phase5_and_6_completion_plan.md` with relay display status
- [ ] Document Microplus relay JSON structure
- [ ] Add relay display screenshots to docs
- [ ] Update HOWTO guides

---

## Data Flow

### Source → Temp Tables → UI

```
Microplus JSON (relay: true)
         ↓
  Phase5Populator.populate_relay_results
         ↓
  Parse legs & laps → Match teams/swimmers
         ↓
┌────────────────────────────────────────┐
│ data_import_meeting_relay_results      │
│ - import_key (unique)                  │
│ - meeting_program_id (matched or nil)  │
│ - team_id (from Phase 2)               │
│ - rank, timing, relay_code             │
└────────────────────────────────────────┘
         ↓
┌────────────────────────────────────────┐
│ data_import_meeting_relay_swimmers     │
│ - relay_result_id (FK)                 │
│ - swimmer_id (from Phase 3 or nil)     │
│ - leg_order, stroke_type_id            │
│ - timing (from_start columns)          │
└────────────────────────────────────────┘
         ↓
┌────────────────────────────────────────┐
│ data_import_relay_laps                 │
│ - relay_swimmer_id (FK)                │
│ - length_in_meters, lap_order          │
│ - minutes/seconds/hundredths (delta)   │
│ - *_from_start columns                 │
└────────────────────────────────────────┘
         ↓
  DataFixController.review_results
         ↓
  View: _relay_result_program_card.html.haml
```

---

## Edge Cases & Error Handling

### 1. Relay with Missing Team
**Scenario**: `team_id` is nil (not matched in Phase 2)  
**Handling**:
- Display team name from source JSON
- Yellow border on card (unmatched)
- Show warning badge "Team not matched"
- Allow Phase 2 re-scan or manual team assignment

### 2. Relay Leg with Missing Swimmer
**Scenario**: `swimmer_id` is nil (not in Phase 3)  
**Handling**:
- Display swimmer name from source JSON
- Badge: "Swimmer not matched"
- Link to Phase 3 relay enrichment workflow
- Allow multi-pass enrichment

### 3. Malformed Relay Data
**Scenario**: Missing legs, invalid timing, incomplete structure  
**Handling**:
- Log warning with source data
- Skip malformed result (don't crash)
- Display error banner in UI: "X relay results skipped due to errors"
- Provide link to view error log

### 4. Relay with No Category/Gender
**Scenario**: Source JSON missing category or gender for relay  
**Handling**:
- Attempt to infer from team composition
- Default to "Open" category if unknown
- Log warning for manual review

### 5. Large Relay Sets (100+ results)
**Scenario**: Meeting with many relay events  
**Handling**:
- Paginate relay results separately from individual
- Add filter: "Show only relays" checkbox
- Lazy-load lap details on expand (avoid loading all at once)

---

## Testing Checklist

### Unit Tests
- [ ] `Phase5Populator#populate_relay_results`
- [ ] Relay leg parsing from JSON
- [ ] Relay lap timing computation
- [ ] Relay EventType matching
- [ ] Relay MeetingProgram matching
- [ ] Team matching for relays
- [ ] Swimmer matching per leg
- [ ] Import key generation

### Integration Tests
- [ ] Phase 5 populator with relay events
- [ ] Controller renders relay results
- [ ] UI displays relay cards correctly
- [ ] Lap expand/collapse interactions
- [ ] Pagination with relays

### Manual Testing
- [ ] Load real Microplus relay file
- [ ] Verify all relays displayed
- [ ] Check team names (matched vs unmatched)
- [ ] Check swimmer names per leg
- [ ] Verify split timings
- [ ] Test expand/collapse all button
- [ ] Test on mobile/tablet (responsive)

---

## Files to Create/Modify

### New Files
- `app/views/data_fix/_relay_result_program_card.html.haml`
- `app/views/data_fix/_relay_result_row.html.haml`
- `app/views/data_fix/_relay_leg_details.html.haml`
- `spec/strategies/import/phase5_populator_relay_spec.rb`

### Modified Files
- `app/strategies/import/phase5_populator.rb` - Add relay population logic
- `app/controllers/data_fix_controller.rb` - Query and expose relay results
- `app/views/data_fix/review_results_v2.html.haml` - Render relay cards
- `config/locales/data_import.en.yml` - Relay UI labels
- `config/locales/data_import.it.yml` - Italian translations
- `docs/data_fix/phase5_and_6_completion_plan.md` - Update status

---

## Success Criteria

✅ Phase5Populator processes relay events without skipping  
✅ Relay results stored in `data_import_meeting_relay_results` table  
✅ Relay legs stored with swimmer and lap details  
✅ Relay cards render in UI with correct styling  
✅ Relay results show match status (team, program, swimmers)  
✅ Leg details expand/collapse correctly  
✅ All tests passing  
✅ Performance acceptable for 50+ relay results  
✅ Documentation updated  

---

## Related Documents

- [Phase 5 & 6 Completion Plan](./phase5_and_6_completion_plan.md)
- [Phase 3 Relay Enrichment Task List](./phase3_relay_enrichment_task_list.md) (swimmer data integration)
- [Phase 6 Relay Commit Task List](./phase6_relay_commit_task_list.md) (SQL generation)
- [Microplus Crawler Schema](../crawler/microplus_layout4_schema.md) (if exists)

---

**Last Updated**: 2025-11-08T01:33:00Z
