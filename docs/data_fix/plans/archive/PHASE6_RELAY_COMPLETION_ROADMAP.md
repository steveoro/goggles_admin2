# Phase 6 Relay Completion Roadmap

**Created**: 2025-11-10  
**Status**: \ud83c\udfaf ACTION PLAN  
**Target**: Complete Phase 6 with full relay support

---

## Executive Summary

**What's Done** ✅:
- Phase 1-3: Meeting/Team/Swimmer processing complete
- Phase 4 EventSolver: Relay event recognition working (1 session, 3 events by gender)
- Phase 5 ResultSolver: Relay data included in phase5 JSON
- Phase 6 individual results: Commit logic functional

**What's Left** 🎯:
1. Phase5Populator relay population (~4-6 hours)
2. Phase 5 relay UI display (~3-4 hours)
3. Phase 6 relay commit methods (~6-8 hours)
4. Testing and integration (~2-3 hours)

**Total Estimated Time**: 15-21 hours

---

## Prerequisites Completed ✅

### Infrastructure
- ✅ goggles_db v0.8.11+ with 5 relay temporary tables
- ✅ `TimingManageable` concern on all data_import models
- ✅ Unique `import_key` indexing for O(1) lookups
- ✅ 28 specs passing in goggles_db

### Phase 4 Foundation
- ✅ EventSolver relay-only file detection
- ✅ Relay event grouping by gender (F, M, X)
- ✅ Italian title parsing: "4x50 m Misti" → [200, "MI", "S4X50MI"]
- ✅ LT4 event code parsing: "4x50SL", "S4X50MI", "M4X50MI"
- ✅ EventType matching with `relay: true`
- ✅ Test verified with actual relay file

### Phase 5 Foundation
- ✅ ResultSolver includes relay event data
- ✅ Relay result counting per gender
- ✅ Phase5 JSON structure supports relays
- ✅ Individual result display UI working (cards + laps)

---

## ⚠️ UPDATED PRIORITY ORDER (2025-11-10)

**BLOCKER FOUND**: Phase5Populator only handles LT4 format. Test relay file is LT2 format!

**NEW FIRST STEP**: Implement LT2+LT4 format support in Phase5Populator.

👉 **See detailed plan**: [`PHASE5_LT2_LT4_SUPPORT_PLAN.md`](./PHASE5_LT2_LT4_SUPPORT_PLAN.md)

**Revised sequence**:
1. ✅ Remove "Use Legacy" buttons (30 min) - Quick win
2. 🎯 Add LT2+LT4 format detection (10-14 hours) - See new plan
3. 🔜 Phase 5 relay UI (3-4 hours) - After populator complete
4. 🔜 Phase 6 relay commits (6-8 hours) - Final step

---

## Implementation Sequence (LEGACY - See new plan)

### Step 1: Phase5Populator Relay Support 🎯 SUPERSEDED
**Status**: ⚠️ Needs LT2 support first - see `PHASE5_LT2_LT4_SUPPORT_PLAN.md`

~~**Est. Time**: 4-6 hours~~  
**Revised**: 10-14 hours (includes LT2+LT4 support)

**Files**: `app/strategies/import/phase5_populator.rb`

#### 1.1 Remove Relay Skip (Part of new plan)
**Current** (line 75):
```ruby
next if event['relay'] == true # Skip relay events for now
```

**Will change to**:
```ruby
if event['relay'] == true
  populate_relay_results(event)  # Different for LT2 vs LT4
  next
end
```

#### 1.2 Implement `populate_relay_results` Method
**Signature**:
```ruby
def populate_relay_results(event)
  # Similar structure to populate_individual_results
  # But creates 3 models per relay result:
  #   - DataImportMeetingRelayResult (header)
  #   - DataImportRelaySwimmer (per leg, 4x)
  #   - DataImportRelayLap (per lap within leg)
end
```

**Key Logic**:
1. Extract relay metadata from event hash
2. Generate `import_key`: `"#{meeting_code}-#{session}-#{event_code}-#{team_key}"`
3. Match `meeting_program_id` from phase 4
4. Match `team_id` from phase 2
5. Loop through relay results (teams)
6. Create `DataImportMeetingRelayResult` record
7. Loop through legs (usually 4)
8. Match `swimmer_id` from phase 3 (if available)
9. Create `DataImportRelaySwimmer` record per leg
10. Create `DataImportRelayLap` records per leg
11. Compute delta timings (lap_time = from_start[i] - from_start[i-1])
12. Update stats: `relay_results_created`, `relay_swimmers_created`, `relay_laps_created`

**Expected Source JSON Structure**:
```json
{
  "relay": true,
  "eventCode": "S4X50MI",
  "sessionOrder": 1,
  "distance": 200,
  "stroke": "MI",
  "gender": "F",
  "results": [
    {
      "rank": 1,
      "team": "CSI OBER FERRARI",
      "timing": "2:15.45",
      "relay_swimmers": [
        {
          "relay_order": 1,
          "swimmer": "ROSSI|MARIO|1978",
          "stroke_type": "DO",
          "timing": "00:33.12"
        },
        // ... 3 more legs
      ]
    }
  ]
}
```

**Helper Methods Needed**:
```ruby
def find_meeting_program_id_for_relay(session_order, event_code, category, gender)
  # Query phase4 data for matching event
  # EventType must have relay: true
end

def find_team_id_by_key(team_key)
  # Query phase2 data
end

def find_swimmer_id_by_key(swimmer_key)
  # Query phase3 data
end

def parse_relay_swimmer_key(swimmer_string)
  # "ROSSI|MARIO|1978" → key format
end

def build_relay_import_key(meeting_code, session_order, event_code, team_key)
  "#{meeting_code}-#{session_order}-#{event_code}-#{team_key}"
end
```

#### 1.3 Update Stats Tracking
Add to `@stats` hash:
```ruby
{
  relay_results_created: 0,
  relay_swimmers_created: 0,
  relay_laps_created: 0,
  relay_programs_matched: 0,
  relay_teams_matched: 0
}
```

#### 1.4 Tests
- [ ] Unit test for `populate_relay_results`
- [ ] Integration test with real relay JSON file
- [ ] Verify all 3 relay tables populated correctly
- [ ] Verify import_key uniqueness
- [ ] Verify foreign key relationships

---

### Step 2: Phase 5 Relay UI Display 🎯 HIGH PRIORITY
**Est. Time**: 3-4 hours  
**Files**: 
- `app/views/data_fix/_relay_result_program_card.html.haml` (new)
- `app/views/data_fix/_relay_result_row.html.haml` (new)
- `app/views/data_fix/_relay_leg_details.html.haml` (new)
- `app/views/data_fix/review_results_v2.html.haml` (update)
- `app/controllers/data_fix_controller.rb` (update)

#### 2.1 Create Relay Card Partial
**File**: `_relay_result_program_card.html.haml`
```haml
-# Similar structure to _result_program_card.html.haml
-# But shows relay-specific details:
-#   - Event code (S4X50MI, M4X50SL, etc.)
-#   - Relay type (4x50m, 4x100m, etc.)
-#   - Stroke (Misti, Stile Libero, etc.)
-#   - Border: green if program matched, yellow if new

.card{class: card_border_class}
  .card-header
    %h5
      = event_type_name
      %span.text-muted= category_code
      %span.badge= result_count
    %button.btn.btn-sm{data: {toggle: 'collapse'}}
      Expand/Collapse
      
  .card-body.collapse
    = render 'relay_result_row', collection: results
```

#### 2.2 Create Relay Result Row Partial
**File**: `_relay_result_row.html.haml`
```haml
-# Shows one relay team result
-# Expandable to show leg details
.row.result-row
  .col-1= rank
  .col-4= team_name
  .col-2= timing
  .col-2= match_badges
  .col-3
    %button.btn.btn-sm{data: {toggle: 'collapse'}}
      Show Legs
      
  .collapse
    = render 'relay_leg_details', legs: relay_swimmers
```

#### 2.3 Create Relay Leg Details Partial
**File**: `_relay_leg_details.html.haml`
```haml
%table.table.table-sm
  %thead
    %tr
      %th Leg
      %th Swimmer
      %th Stroke
      %th Split
      %th Cumulative
  %tbody
    - legs.each do |leg|
      %tr
        %td= leg.relay_order
        %td= swimmer_name_or_unknown(leg)
        %td= stroke_type_badge(leg)
        %td= leg.reaction_time (delta)
        %td= leg.minutes_from_start (cumulative)
```

#### 2.4 Update Controller
**File**: `data_fix_controller.rb#review_results`

Add relay queries:
```ruby
@relay_result_groups = GogglesDb::DataImportMeetingRelayResult
  .where(season_id: @season.id)
  .includes(:meeting_relay_swimmers, :relay_laps)
  .order(:session_order, :event_code, :category_code, :rank)
  .group_by { |r| [r.event_code, r.category_code, r.gender_code] }
```

#### 2.5 Update View
**File**: `review_results_v2.html.haml`

Add relay section after individual results:
```haml
-# Individual results cards...

%h3 Relay Results
.row
  - @relay_result_groups.each do |program_key, results|
    .col-lg-6
      = render 'relay_result_program_card',
               program_key: program_key,
               results: results
```

---

### Step 3: Phase 6 Relay Commit Methods 🎯 CRITICAL
**Est. Time**: 6-8 hours  
**File**: `app/strategies/import/committers/main.rb`

#### 3.1 Add Relay Commit to Phase 5 Flow
**Current** (`commit_phase5_entities`):
```ruby
def commit_phase5_entities
  # Individual results...
  commit_individual_results
  
  # Add relay results:
  commit_relay_results  # NEW
end
```

#### 3.2 Implement `commit_relay_results`
```ruby
def commit_relay_results
  relay_results = GogglesDb::DataImportMeetingRelayResult
    .where(season_id: @season_id)
    .includes(:meeting_relay_swimmers, :relay_laps)
    
  relay_results.each do |relay_result|
    commit_meeting_relay_result(relay_result)
  end
end
```

#### 3.3 Implement `commit_meeting_relay_result`
```ruby
def commit_meeting_relay_result(temp_relay_result)
  # 1. Ensure MeetingProgram exists (for relay event)
  program_id = temp_relay_result.meeting_program_id ||
               ensure_relay_meeting_program(temp_relay_result)
  
  # 2. Check if MRR already exists (3-way match)
  existing_mrr = find_existing_mrr(
    meeting_program_id: program_id,
    team_id: temp_relay_result.team_id,
    # relay_code or other unique key
  )
  
  # 3. Normalize attributes
  attributes = normalize_relay_result_attributes(temp_relay_result)
  
  # 4. CREATE or UPDATE
  if existing_mrr
    existing_mrr.update!(attributes)
    @sql_log << SqlMaker.new(row: existing_mrr).log_update
    @stats[:relay_results_updated] += 1
  else
    new_mrr = GogglesDb::MeetingRelayResult.create!(attributes)
    @sql_log << SqlMaker.new(row: new_mrr).log_insert
    @stats[:relay_results_created] += 1
  end
  
  # 5. Commit relay swimmers (legs)
  commit_relay_swimmers(new_mrr || existing_mrr, temp_relay_result)
  
  # 6. Commit relay laps
  commit_relay_laps(new_mrr || existing_mrr, temp_relay_result)
  
  new_mrr || existing_mrr
end
```

#### 3.4 Implement `ensure_relay_meeting_program`
```ruby
def ensure_relay_meeting_program(relay_result)
  # Find or create MeetingProgram for relay event
  # Must use EventType with relay: true
  
  event_type = GogglesDb::EventType.find_by(
    code: relay_result.event_code,
    relay: true
  )
  
  category_type = GogglesDb::CategoryType.find_by(
    code: relay_result.category_code
  )
  
  gender_type = GogglesDb::GenderType.find_by(
    code: relay_result.gender_code
  )
  
  program = GogglesDb::MeetingProgram.find_or_create_by!(
    meeting_session_id: relay_result.meeting_session_id,
    event_type_id: event_type.id,
    category_type_id: category_type.id,
    gender_type_id: gender_type.id
  )
  
  @stats[:relay_programs_created] += 1 if program.previously_new_record?
  program.id
end
```

#### 3.5 Implement `commit_relay_swimmers`
```ruby
def commit_relay_swimmers(mrr, temp_relay_result)
  temp_relay_result.meeting_relay_swimmers.each do |temp_swimmer|
    attributes = {
      meeting_relay_result_id: mrr.id,
      swimmer_id: temp_swimmer.swimmer_id,
      badge_id: temp_swimmer.badge_id, # if available
      stroke_type_id: temp_swimmer.stroke_type_id,
      relay_order: temp_swimmer.relay_order,
      reaction_time: temp_swimmer.reaction_time,
      minutes: temp_swimmer.minutes,
      # ... timing fields
    }
    
    # Check if already exists
    existing = GogglesDb::MeetingRelaySwimmer.find_by(
      meeting_relay_result_id: mrr.id,
      relay_order: temp_swimmer.relay_order
    )
    
    if existing
      existing.update!(attributes)
      @sql_log << SqlMaker.new(row: existing).log_update
      @stats[:relay_swimmers_updated] += 1
    else
      new_swimmer = GogglesDb::MeetingRelaySwimmer.create!(attributes)
      @sql_log << SqlMaker.new(row: new_swimmer).log_insert
      @stats[:relay_swimmers_created] += 1
    end
  end
end
```

#### 3.6 Implement `commit_relay_laps`
```ruby
def commit_relay_laps(mrr, temp_relay_result)
  # Find relay swimmers for this MRR
  relay_swimmers = GogglesDb::MeetingRelaySwimmer.where(
    meeting_relay_result_id: mrr.id
  ).index_by(&:relay_order)
  
  temp_relay_result.relay_laps.each do |temp_lap|
    relay_swimmer = relay_swimmers[temp_lap.relay_order]
    
    attributes = {
      meeting_relay_swimmer_id: relay_swimmer.id,
      meeting_program_id: mrr.meeting_program_id,
      length_in_meters: temp_lap.length_in_meters,
      reaction_time: temp_lap.reaction_time,
      minutes: temp_lap.minutes,
      # ... timing fields
    }
    
    # Laps usually don't exist, just create
    new_lap = GogglesDb::RelayLap.create!(attributes)
    @sql_log << SqlMaker.new(row: new_lap).log_insert
    @stats[:relay_laps_created] += 1
  end
end
```

#### 3.7 Update Stats Tracking
Add to `@stats` hash:
```ruby
{
  relay_results_created: 0,
  relay_results_updated: 0,
  relay_programs_created: 0,
  relay_swimmers_created: 0,
  relay_swimmers_updated: 0,
  relay_laps_created: 0
}
```

#### 3.8 Stroke Type Mapping
**For mixed relays (MI stroke)**:
Use `GogglesDb::StrokeType` constants:
- Leg 1 (Backstroke): `BACKSTROKE_ID = 3`
- Leg 2 (Breaststroke): `BREASTSTROKE_ID = 4`
- Leg 3 (Butterfly): `BUTTERFLY_ID = 2`
- Leg 4 (Freestyle): `FREESTYLE_ID = 1`

For same-stroke relays (SL, DO, RA, FA):
- Use the corresponding stroke_type_id for all legs

---

### Step 4: Testing & Validation 🎯
**Est. Time**: 2-3 hours

#### 4.1 Unit Tests
- [ ] `Phase5Populator#populate_relay_results` specs
- [ ] `Main#commit_meeting_relay_result` specs
- [ ] `Main#commit_relay_swimmers` specs
- [ ] `Main#commit_relay_laps` specs

#### 4.2 Integration Tests
- [ ] Full workflow test with relay JSON file
- [ ] Verify phase4 output (1 session, 3 events)
- [ ] Verify phase5 population (temp tables)
- [ ] Verify phase6 commit (production tables)
- [ ] Verify SQL log generation

#### 4.3 Browser Testing
- [ ] Load relay results in review_results_v2 view
- [ ] Verify card rendering
- [ ] Test expand/collapse interactions
- [ ] Verify leg details display
- [ ] Test commit button workflow

#### 4.4 Data Validation
- [ ] Check EventType matching (relay: true)
- [ ] Check MeetingProgram creation
- [ ] Check foreign key integrity
- [ ] Check timing calculations (delta vs from_start)
- [ ] Check stroke_type_id assignments

---

## Success Criteria

### Phase 5 Complete When:
- [x] EventSolver recognizes relay events
- [x] ResultSolver includes relay data in phase5 JSON
- [ ] Phase5Populator populates all 3 relay temp tables
- [ ] Relay results display in UI with cards
- [ ] All relay results show team names (no "N/A")
- [ ] Leg details expand correctly
- [ ] Match status indicators work (green/yellow borders)

### Phase 6 Complete When:
- [x] Individual results commit works
- [ ] Relay results commit works
- [ ] MeetingProgram creation for relays
- [ ] MeetingRelayResult creation/update
- [ ] MeetingRelaySwimmer creation (4 per result)
- [ ] RelayLap creation (N per swimmer)
- [ ] SQL log contains all INSERT/UPDATE statements
- [ ] Files move to `results.done` folder
- [ ] Phase files cleaned up
- [ ] Full end-to-end test passes

---

## Timeline Estimate

| Task | Hours | Priority |
|------|-------|----------|
| 1. Phase5Populator relay logic | 4-6 | HIGH |
| 2. Relay UI partials | 3-4 | HIGH |
| 3. Phase 6 relay commits | 6-8 | CRITICAL |
| 4. Testing & validation | 2-3 | HIGH |
| **Total** | **15-21** | |

**Recommended Approach**: 
1. Start with Phase5Populator (enables testing with real data)
2. Add UI display (visual feedback of what's populated)
3. Implement Phase 6 commits (final production commit)
4. Test thoroughly at each step

---

## Next Immediate Action

**START HERE** 🎯:
1. Open `app/strategies/import/phase5_populator.rb`
2. Remove line 75: `next if event['relay'] == true`
3. Add `populate_relay_results(event)` method
4. Test with actual relay JSON file: `crawler/data/results.new/242/2025-06-24-...4X50MI-l4.json`
5. Verify data in `data_import_meeting_relay_results` table

**Command to verify**:
```ruby
# After running Phase5Populator
GogglesDb::DataImportMeetingRelayResult.count
# Should be > 0 for relay files

GogglesDb::DataImportRelaySwimmer.count
# Should be ~4x relay results

GogglesDb::DataImportRelayLap.count
# Should be ~N laps per swimmer
```
