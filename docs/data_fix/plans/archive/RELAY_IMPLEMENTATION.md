# Relay Support Implementation

**Last Updated**: 2025-11-10  
**Status**: Phase 4 ✅ | Phase 5 Solver ✅ | Phase 5 Populator 🎯 | Phase 6 🎯

This document tracks relay support across all phases of the Data-Fix pipeline.

---

## Quick Status

| Component | Status | Date Completed | Notes |
|-----------|--------|----------------|-------|
| **Phase 3: Relay Enrichment** | ✅ Complete | 2025-11-04 | Swimmer matching per leg |
| **Phase 4: EventSolver** | ✅ Complete | 2025-11-10 | Relay event recognition |
| **Phase 5: ResultSolver** | ✅ Complete | 2025-11-10 | Relay result processing |
| **Phase 5: Populator** | 🎯 **ACTIVE** (10-14 hrs) | - | ⚠️ **BLOCKER**: Need LT2+LT4 support |
| **Phase 5: UI Display** | 🔜 After Populator (3-4 hrs) | - | Need relay card partials |
| **Phase 6: Commits** | 🔜 Final Step (6-8 hrs) | - | Need MRR/MRS/RL commits |

**Total Remaining**: ~19-26 hours to full relay support

**Current Priority**: Phase5Populator LT2+LT4 format support  
👉 **Detailed Plan**: [`plans/PHASE5_LT2_LT4_SUPPORT_PLAN.md`](./plans/PHASE5_LT2_LT4_SUPPORT_PLAN.md)  
👉 **Daily Tracker**: [`plans/DAILY_PROGRESS.md`](./plans/DAILY_PROGRESS.md)

---

## Phase 3: Relay Enrichment Workflow

**Status**: ✅ Complete  
**Purpose**: Match swimmers to relay leg positions

### What It Does
Separate workflow (Phase 3b) that enriches relay events with swimmer data:
1. Scans source JSON for relay events
2. Detects missing/incomplete swimmer information
3. Provides UI to add/match swimmers per relay leg
4. Generates auxiliary phase3 files
5. Merges auxiliary files into main phase3 data

### Key Files
- `app/services/phase3/relay_enrichment_detector.rb` - Scans for incomplete legs
- `app/services/phase3/relay_merge_service.rb` - Merges auxiliary files
- `app/views/data_fix/_relay_enrichment_panel.html.haml` - UI accordion
- `app/controllers/data_fix_controller.rb#relay_enrichment_scan` - Scan action
- `app/controllers/data_fix_controller.rb#relay_enrichment_merge` - Merge action

### UI Integration
Accordion panel on Phase 3 review page:
- Shows count of incomplete relay legs
- "Scan & Merge" button to process auxiliary files
- Updates phase3.json with merged swimmer data

### Workflow
```
1. User uploads relay meeting file
2. Phases 1-2 complete normally
3. Phase 3: Regular swimmers matched
4. Phase 3b (optional): Relay enrichment
   a. Click "Scan & Merge" button
   b. System detects auxiliary phase3 files
   c. Merges relay swimmer data
   d. Updates main phase3.json
5. Continue to Phase 4
```

---

## Phase 4: Event Recognition

**Status**: ✅ Complete (FIXED 2025-11-10)  
**File**: `app/strategies/import/solvers/event_solver.rb`

### Problem (Before)
- Relay events were completely skipped
- Each relay section created a separate session (23 sessions for 1 file\!)
- No EventType matching

### Solution
Three key improvements:

#### 1. Relay-Only File Detection
```ruby
all_relay = data_hash['sections'].all? do |sec|
  rows = sec['rows'] || []
  rows.any? { |row| row['relay'] == true }
end

if all_relay
  # Special processing: group all sections into ONE session
end
```

#### 2. Italian Title Parsing
```ruby
def parse_relay_event_from_title(title, fin_sesso)
  # "4x50 m Misti" → [200, "MI", "S4X50MI"]
  match = title.match(/(\d+)\s*[xX]\s*(\d+)\s*m/i)
  participants = match[1].to_i  # 4
  phase_length = match[2].to_i  # 50
  total_distance = participants * phase_length  # 200
  
  stroke_code = if title =~ /misti|medley/i
                  'MI'  # ← IMPORTANT: "MI" not "MX"
                elsif title =~ /stile\s*libero|freestyle/i
                  'SL'
                # ... other strokes
                end
  
  gender_prefix = (fin_sesso.upcase == 'X') ? 'M' : 'S'
  event_code = "#{gender_prefix}#{participants}X#{phase_length}#{stroke_code}"
  
  [total_distance, stroke_code, event_code]
end
```

**Key Learning**: Database uses `"MI"` (Misti) for mixed relays, not `"MX"`\!

#### 3. Gender-Based Event Grouping
```ruby
seen = {}  # Deduplicate by relay_code + gender

data_hash['sections'].each do |sec|
  distance, stroke, relay_code = parse_relay_event_from_title(sec['title'], sec['fin_sesso'])
  gender = sec['fin_sesso'].upcase  # F, M, or X
  key = "#{relay_code}-#{gender}"
  
  next if seen[key]  # Skip duplicates
  seen[key] = true
  
  events << {
    'distance' => distance,
    'stroke' => stroke,
    'relay' => true,
    'event_code' => relay_code,
    'gender' => gender,
    'event_type_id' => find_relay_event_type_id(relay_code, gender)
  }
end

sessions << { 'session_order' => 1, 'events' => events }
```

### Test Results
**File**: `2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json`

**Before**:
```
23 sections → 23 sessions, 0-23 unmatched events ❌
```

**After**:
```
23 sections → 1 session, 3 events (F/M/X), all matched ✅

Events:
- S4X50MI (gender: F, event_type_id: 26)
- S4X50MI (gender: M, event_type_id: 26)
- M4X50MI (gender: X, event_type_id: 33)
```

### Relay Event Codes

| Code | Description | Gender | Stroke | EventType ID |
|------|-------------|--------|--------|--------------|
| `S4X50MI` | Same-gender 4x50 Mixed | F or M | MI (Intermixed) | 26 |
| `M4X50MI` | Mixed-gender 4x50 Mixed | X | MI (Intermixed) | 33 |
| `S4X50SL` | Same-gender 4x50 Freestyle | F or M | SL (Freestyle) | 25 |
| `M4X50SL` | Mixed-gender 4x50 Freestyle | X | SL (Freestyle) | 32 |

**Gender Prefix**:
- `S` = Same gender (could be F or M, determined by `fin_sesso`)
- `M` = Mixed gender (always X)

---

## Phase 5: Result Solver

**Status**: ✅ Complete (FIXED 2025-11-10)  
**File**: `app/strategies/import/solvers/result_solver.rb`

### Problem (Before)
- Phase5 JSON was empty for relay files
- Relay events skipped during processing

### Solution
Applied same relay detection logic as EventSolver:
- Relay-only file detection
- Gender-based result grouping
- Result counting per gender

### Test Results
**Same test file** as Phase 4

**Output**:
```json
{
  "sessions": [{
    "session_order": 1,
    "events": [
      {
        "key": "S4X50MI",
        "distance": 200,
        "stroke": "MI",
        "relay": true,
        "session_order": 1,
        "genders": [
          {
            "gender": "F",
            "results_count": 22,
            "categories": {"M45": 8, "M50": 7, "M55": 5, "M60": 2}
          },
          {
            "gender": "M",
            "results_count": 24,
            "categories": {"M45": 10, "M50": 8, "M55": 4, "M60": 2}
          }
        ]
      },
      {
        "key": "M4X50MI",
        "gender": "X",
        "results_count": 1
      }
    ]
  }]
}
```

**Success**: Phase5 JSON now includes relay event structure\!

---

## Phase 5: Populator (ACTIVE WORK)

**Status**: 🎯 In Progress (10-14 hours)  
**File**: `app/strategies/import/phase5_populator.rb`

### ⚠️ BLOCKER DISCOVERED (2025-11-10)

**Issue 1**: Phase5Populator only handles LT4 format
- Current code reads `source_data['events']` (line 72)
- LT4 format has `events` array
- LT2 format has direct entity keys (`meeting_relay_result`, etc.)

**Issue 2**: Test relay file is LT2, not LT4
- File: `2025-06-24-...-4X50MI-l4.json` (misleading name!)
- Has `layoutType: 2` and 787 relay results in `meeting_relay_result` key
- NO `events` array, so line 72 returns empty array
- Even if it had events, line 75 skips all relays

**Impact**: Empty database tables, no relay data populated

**Solution**: Add LT2+LT4 format detection and dual processing paths

👉 **See**: [`plans/PHASE5_LT2_LT4_SUPPORT_PLAN.md`](./plans/PHASE5_LT2_LT4_SUPPORT_PLAN.md) for full solution

### Architecture Clarification

**Phase5 Data Flow**:
```
Source JSON (LT2 or LT4 format)
    ↓
ResultSolver → phase5.json (SUMMARY: result counts only)
    ↓
Phase5Populator → Reads SOURCE file (DETAILED: laps, timings)
    ↓
data_import_* DB tables (full details)
```

**Why read source file?**
- Phase5 JSON = summary only (no lap details)
- Lap/timing data exists ONLY in source file
- Database needs full lap details for Phase 6 commit

### Current State (Line 75)
**Line 75**: `next if event['relay'] == true # Skip relay events for now`

**This must be replaced with**:
1. LT2/LT4 format detection
2. Dual processing paths for each format
3. Relay population logic for both formats

### Required Changes

#### 1. Remove Skip & Route to Handler
```ruby
# CHANGE FROM:
next if event['relay'] == true

# TO:
if event['relay'] == true
  populate_relay_results(event)
  next
end
```

#### 2. Implement `populate_relay_results`
```ruby
def populate_relay_results(event)
  session_order = event['sessionOrder'] || 1
  event_code = event['eventCode']
  results = Array(event['results'])
  
  results.each do |result|
    # 1. Generate import_key
    team_key = result['team']
    import_key = build_relay_import_key(meeting_code, session_order, event_code, team_key)
    
    # 2. Match meeting_program_id (from phase4)
    meeting_program_id = find_relay_meeting_program_id(session_order, event_code, category, gender)
    
    # 3. Match team_id (from phase2)
    team_id = find_team_id_by_key(team_key)
    
    # 4. Create MeetingRelayResult record
    relay_result = GogglesDb::DataImportMeetingRelayResult.create\!(
      import_key: import_key,
      season_id: @season_id,
      meeting_program_id: meeting_program_id,
      team_id: team_id,
      rank: result['rank'],
      # ... timing fields
    )
    
    # 5. Create RelaySwimmer records (4 per result)
    result['relay_swimmers'].each_with_index do |leg, idx|
      swimmer_key = parse_relay_swimmer_key(leg['swimmer'])
      swimmer_id = find_swimmer_id_by_key(swimmer_key)
      
      GogglesDb::DataImportRelaySwimmer.create\!(
        data_import_meeting_relay_result_id: relay_result.id,
        relay_order: idx + 1,
        swimmer_id: swimmer_id,
        stroke_type_id: determine_stroke_type_id(event_code, idx),
        # ... timing fields
      )
    end
    
    # 6. Create RelayLap records (per swimmer lap)
    # ... (similar pattern)
  end
end
```

#### 3. Helper Methods Needed
```ruby
def find_relay_meeting_program_id(session_order, event_code, category, gender)
  # Query phase4 data for matching relay event
end

def build_relay_import_key(meeting_code, session_order, event_code, team_key)
  "#{meeting_code}-#{session_order}-#{event_code}-#{team_key.parameterize}"
end

def determine_stroke_type_id(event_code, leg_order)
  # For mixed relays (MI), map leg order to stroke:
  # 1 → Backstroke (3), 2 → Breaststroke (4),
  # 3 → Butterfly (2), 4 → Freestyle (1)
  # For same-stroke relays, all legs same stroke
end
```

#### 4. Update Stats Tracking
```ruby
@stats = {
  mir_created: 0,
  laps_created: 0,
  relay_results_created: 0,      # NEW
  relay_swimmers_created: 0,      # NEW
  relay_laps_created: 0,          # NEW
  programs_matched: 0,
  relay_programs_matched: 0,      # NEW
  errors: []
}
```

### Stroke Type Mapping (Mixed Relays)

For event code `*4X50MI` (mixed relay):
| Leg | Stroke | `stroke_type_id` |
|-----|--------|------------------|
| 1 | Backstroke (DO) | 3 |
| 2 | Breaststroke (RA) | 4 |
| 3 | Butterfly (FA) | 2 |
| 4 | Freestyle (SL) | 1 |

For other relay types (`*4X50SL`, `*4X50DO`, etc.):
- All legs use the same `stroke_type_id`

**Constants** (`GogglesDb::StrokeType`):
```ruby
FREESTYLE_ID = 1
BUTTERFLY_ID = 2
BACKSTROKE_ID = 3
BREASTSTROKE_ID = 4
REL_INTERMIXED_ID = 10  # For the relay event itself, not individual legs
```

---

## Phase 5: UI Display (TODO)

**Status**: 🎯 After Populator (3-4 hours)  
**Files**: Create new partials

### Required Partials

#### 1. `_relay_result_program_card.html.haml`
Similar structure to `_result_program_card.html.haml`:
- Card header: Event name, category, gender
- Border color: Green if `meeting_program_id` matched, yellow if new
- Collapse/expand button
- Contains relay result rows

#### 2. `_relay_result_row.html.haml`
Shows one team's relay result:
- Rank, team name, total timing
- Match status badges (team_id, program_id)
- Expand button for leg details
- Collapsible leg container

#### 3. `_relay_leg_details.html.haml`
Shows relay legs in table:
- Leg order (1-4)
- Swimmer name (or "Unknown" if no swimmer_id)
- Stroke type
- Split timing (delta)
- Cumulative timing (from_start)

### Controller Changes
**File**: `app/controllers/data_fix_controller.rb#review_results`

Add queries:
```ruby
@relay_result_groups = GogglesDb::DataImportMeetingRelayResult
  .where(season_id: @season.id)
  .includes(:meeting_relay_swimmers, :relay_laps)
  .order(:session_order, :event_code, :rank)
  .group_by { |r| [r.event_code, r.category_code, r.gender_code] }
```

### View Integration
**File**: `app/views/data_fix/review_results_v2.html.haml`

Add after individual results:
```haml
- if @relay_result_groups.present?
  %h3 Relay Results
  .row
    - @relay_result_groups.each do |program_key, results|
      .col-lg-6
        = render 'relay_result_program_card',
                 program_key: program_key,
                 results: results
```

---

## Phase 6: Commits (TODO)

**Status**: 🎯 Final Step (6-8 hours)  
**File**: `app/strategies/import/committers/main.rb`

### Required Methods

#### 1. `commit_relay_results` (Entry Point)
```ruby
def commit_phase5_entities
  # ... existing individual result commits
  
  commit_relay_results  # NEW
end

def commit_relay_results
  relay_results = GogglesDb::DataImportMeetingRelayResult
    .where(season_id: @season_id)
    .includes(:meeting_relay_swimmers, :relay_laps)
    
  relay_results.each do |temp_relay_result|
    commit_meeting_relay_result(temp_relay_result)
  end
end
```

#### 2. `commit_meeting_relay_result`
```ruby
def commit_meeting_relay_result(temp_relay_result)
  # 1. Ensure MeetingProgram exists
  program_id = temp_relay_result.meeting_program_id ||
               ensure_relay_meeting_program(temp_relay_result)
  
  # 2. Check if MRR already exists
  existing_mrr = find_existing_mrr(
    meeting_program_id: program_id,
    team_id: temp_relay_result.team_id
  )
  
  # 3. CREATE or UPDATE
  attributes = normalize_relay_result_attributes(temp_relay_result)
  
  if existing_mrr
    existing_mrr.update\!(attributes)
    @sql_log << SqlMaker.new(row: existing_mrr).log_update
    @stats[:relay_results_updated] += 1
  else
    new_mrr = GogglesDb::MeetingRelayResult.create\!(attributes)
    @sql_log << SqlMaker.new(row: new_mrr).log_insert
    @stats[:relay_results_created] += 1
  end
  
  # 4. Commit relay swimmers
  commit_relay_swimmers(new_mrr || existing_mrr, temp_relay_result)
  
  # 5. Commit relay laps
  commit_relay_laps(new_mrr || existing_mrr, temp_relay_result)
end
```

#### 3. `ensure_relay_meeting_program`
```ruby
def ensure_relay_meeting_program(relay_result)
  event_type = GogglesDb::EventType.find_by(
    code: relay_result.event_code,
    relay: true  # IMPORTANT\!
  )
  
  # ... find category_type, gender_type
  
  program = GogglesDb::MeetingProgram.find_or_create_by\!(
    meeting_session_id: relay_result.meeting_session_id,
    event_type_id: event_type.id,
    category_type_id: category_type.id,
    gender_type_id: gender_type.id
  )
  
  @stats[:relay_programs_created] += 1 if program.previously_new_record?
  program.id
end
```

#### 4. `commit_relay_swimmers`
```ruby
def commit_relay_swimmers(mrr, temp_relay_result)
  temp_relay_result.meeting_relay_swimmers.each do |temp_swimmer|
    attributes = {
      meeting_relay_result_id: mrr.id,
      swimmer_id: temp_swimmer.swimmer_id,
      stroke_type_id: temp_swimmer.stroke_type_id,
      relay_order: temp_swimmer.relay_order,
      # ... timing fields
    }
    
    # Check if already exists
    existing = GogglesDb::MeetingRelaySwimmer.find_by(
      meeting_relay_result_id: mrr.id,
      relay_order: temp_swimmer.relay_order
    )
    
    if existing
      existing.update\!(attributes)
      @sql_log << SqlMaker.new(row: existing).log_update
    else
      new_swimmer = GogglesDb::MeetingRelaySwimmer.create\!(attributes)
      @sql_log << SqlMaker.new(row: new_swimmer).log_insert
      @stats[:relay_swimmers_created] += 1
    end
  end
end
```

#### 5. `commit_relay_laps`
```ruby
def commit_relay_laps(mrr, temp_relay_result)
  # Find relay swimmers for this MRR
  relay_swimmers = GogglesDb::MeetingRelaySwimmer
    .where(meeting_relay_result_id: mrr.id)
    .index_by(&:relay_order)
  
  temp_relay_result.relay_laps.each do |temp_lap|
    relay_swimmer = relay_swimmers[temp_lap.relay_order]
    
    attributes = {
      meeting_relay_swimmer_id: relay_swimmer.id,
      meeting_program_id: mrr.meeting_program_id,
      length_in_meters: temp_lap.length_in_meters,
      # ... timing fields
    }
    
    new_lap = GogglesDb::RelayLap.create\!(attributes)
    @sql_log << SqlMaker.new(row: new_lap).log_insert
    @stats[:relay_laps_created] += 1
  end
end
```

---

## Complete Implementation Roadmap

See [plans/PHASE6_RELAY_COMPLETION_ROADMAP.md](./plans/PHASE6_RELAY_COMPLETION_ROADMAP.md) for:
- Step-by-step implementation guide
- Complete code examples
- Helper method signatures
- Testing checklist
- 15-21 hour estimate breakdown

---

## Testing

### Relay Test File
**Path**: `crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json`

**Contents**:
- 23 sections (all relay events)
- Gender distribution: F=7, M=8, X=8
- Event: 4x50m Misti (mixed relay)

### Verification Commands

**Phase 4 (Events)**:
```ruby
data = JSON.parse(File.read('path-to-phase4.json'))
sessions = data.dig('data', 'sessions')
# Expected: 1 session
events = sessions.first['events']
# Expected: 3 events (F, M, X)
```

**Phase 5 (Populator)** - After implementation:
```ruby
GogglesDb::DataImportMeetingRelayResult.where(season_id: 242).count
# Expected: >0 for relay files

GogglesDb::DataImportRelaySwimmer.count
# Expected: ~4x relay results
```

**Phase 6 (Commit)** - After implementation:
```ruby
GogglesDb::MeetingRelayResult.where(season_id: 242).count
# Expected: matches temp table count

GogglesDb::MeetingRelaySwimmer.count
# Expected: 4 per relay result
```

---

**For detailed implementation**, see [plans/PHASE6_RELAY_COMPLETION_ROADMAP.md](./plans/PHASE6_RELAY_COMPLETION_ROADMAP.md)  
**For recent fixes**, see [plans/FIXES_progress_and_relay_events.md](./plans/FIXES_progress_and_relay_events.md)  
**For architecture**, see [TECHNICAL.md](./TECHNICAL.md)
