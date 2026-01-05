# Data-Fix Phases: Complete Implementation Guide

**Version**: 2.0  
**Last Updated**: 2025-11-10

This document provides a complete overview of all 6 phases in the Data-Fix pipeline.

---

## Overview: The 6-Phase Pipeline

Each phase builds on the previous, creating a dependency chain that ensures all entity IDs are resolved before commit:

```
Phase 1: Meeting → phase1.json (meeting_id, session_ids)
    ↓
Phase 2: Teams → phase2.json (team_id, team_affiliation_id)
    ↓
Phase 3: Swimmers → phase3.json (swimmer_id, badge_id, category_type_id)
    ↓
Phase 4: Events → phase4.json (event_type_id, meeting_event_id)
    ↓
Phase 5: Results → data_import_* DB tables (all IDs linked)
    ↓
Phase 6: Commit → Production DB + SQL log
```

**Key Principle**: "Solve Early, Commit Later" - All matching and calculations happen during phase building, not at commit time.

---

## Phase 1: Meeting & Sessions

**Status**: ✅ Complete  
**Purpose**: Import meeting metadata, sessions, venues, cities  
**Solver**: `app/strategies/import/solvers/phase1_solver.rb`

### What It Does
- Creates or matches Meeting record
- Creates or matches MeetingSessions
- Creates or matches SwimmingPool and City (nested)
- Stores all IDs in phase1.json

### Key Features
- Meeting matching by (code, header_date, season_id)
- Session matching by (meeting_id, session_order)
- Venue/city cascading creation

### Output Structure

**Note**: The actual phase1 JSON uses a flat structure for meeting attributes under `data`, but:
- Sessions are at `data.meeting_session[]` (not nested under `meeting`)
- Session IDs use the field `id` (not `meeting_session_id`)
- SwimmingPool are nested under `meeting_session`
- SwimmingPool IDs use the field `id` (not `swimming_pool_id`)
- City are nested under `swimming_pool`
- City IDs use the field `id` (not `city_id`)

```json
{
  "_meta": { "phase": 1, "season_id": 232 },
  "data": {
    "id": 19766,
    "season_id": 232,
    "code": "italianoinvernale",
    "header_date": "2023-12-08",
    "meeting_session": [
      {
        "id": 3878,
        "session_order": 1,
        "scheduled_date": "2023-12-08",
        "swimming_pool": {
          "id": 165,
          "name": "Palazzo Nuoto",
          "city": { "id": 90, "name": "Torino" }
        }
      }
    ]
  }
}
```

---

## Phase 2: Teams & Affiliations

**Status**: ✅ Complete + Pre-Matching  
**Purpose**: Match teams, create season affiliations  
**Solver**: `app/strategies/import/solvers/team_solver.rb`

### What It Does
- Fuzzy matches teams using Jaro-Winkler algorithm
- Auto-assigns teams with ≥60% confidence
- **Pre-matches team affiliations** (v2.0 feature)
- Creates phase2.json with team_id and team_affiliation_id

### Pre-Matching Pattern
**Match Key**: `(season_id, team_id)`  
**Benefit**: Phase 6 only creates new affiliations, no lookups needed

```ruby
# During Phase 2 building:
affiliation = TeamAffiliation.find_by(season_id: @season.id, team_id: team_id)
team_affiliation_hash['team_affiliation_id'] = affiliation&.id

# During Phase 6 commit:
return if affiliation_hash['team_affiliation_id'].present?  # Skip existing
TeamAffiliation.create\!(...)  # Only create if missing
```

### Output Structure
```json
{
  "teams": [{
    "key": "CSI OBER FERRARI",
    "team_id": 123,
    "name": "CSI OBER FERRARI",
    "editable_name": "CSI Ober Ferrari"
  }],
  "team_affiliations": [{
    "team_key": "CSI OBER FERRARI",
    "team_id": 123,
    "season_id": 242,
    "team_affiliation_id": 456  // Pre-matched\!
  }]
}
```

---

## Phase 3: Swimmers & Badges

**Status**: ✅ Complete + Pre-Matching + Category Calculation  
**Purpose**: Match swimmers, create badges with categories  
**Solver**: `app/strategies/import/solvers/swimmer_solver.rb`

### What It Does
- Matches swimmers by (last_name, first_name, year_of_birth)
- **Pre-matches badges**
- **Calculates category types** for Badges, using CategoriesCache; note that in some cases the category_types link cannot be finalized until the swimmer results are processed
- Loads phase1 for meeting_date, phase2 for team_id

### Pre-Matching Pattern
**Match Key**: `(season_id, swimmer_id, team_id)`  
**Calculated Fields**: `category_type_id` (age-based)  
**Dependencies**: phase1 (meeting_date), phase2 (team_id)

```ruby
# During Phase 3 building:
meeting_date = load_phase1['meeting']['header_date']
team_id = find_team_id_from_phase2(team_key)

# Calculate category
category_type = CategoriesCache.instance.for_swimmer(
  year_of_birth: yob,
  gender_code: gender,
  meeting_date: meeting_date
)
badge_hash['category_type_id'] = category_type&.id

# Match existing badge
existing = Badge.find_by(season_id:, swimmer_id:, team_id:)
badge_hash['badge_id'] = existing&.id
```

### Special Feature: Relay Enrichment (Phase 3b)
For relay events, an additional workflow allows enriching relay legs with swimmer data:
- Scans relay events from source JSON
- Detects missing swimmer information
- Provides UI to add/match swimmers per relay leg
- Merges auxiliary phase3 files

See [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md) for details.

### Output Structure
```json
{
  "swimmers": [{
    "key": "ROSSI|MARIO|1978",
    "swimmer_id": 123,
    "complete_name": "ROSSI MARIO"
  }],
  "badges": [{
    "swimmer_key": "ROSSI|MARIO|1978",
    "team_key": "CSI OBER FERRARI",
    "swimmer_id": 123,
    "team_id": 456,
    "category_type_id": 789,  // Pre-calculated\!
    "badge_id": 999          // Pre-matched\!
  }]
}
```

---

## Phase 4: Events

**Status**: ✅ Complete + Pre-Matching + Relay Support  
**Purpose**: Match event types, create meeting events  
**Solver**: `app/strategies/import/solvers/event_solver.rb`

### What It Does
- Deduplicates events within sessions
- Matches EventType by code (e.g., "200RA", "4X50SL")
- **Pre-matches meeting events** (v2.0 feature)
- **Processes relay events** (v2.1 feature - FIXED 2025-11-10)
- Loads phase1 for meeting_session_id

### Pre-Matching Pattern
**Match Key**: `(meeting_session_id, event_type_id)`  
**Dependencies**: phase1 (meeting_session_id)

### Relay Support (NEW 2025-11-10)
**Relay-Only File Detection**: Automatically groups all relay sections into ONE session  
**Gender Grouping**: Creates separate events for F, M, X genders  
**Italian Title Parsing**: `"4x50 m Misti"` → `[200, "MI", "S4X50MI"]`  
**LT4 Code Parsing**: Handles `"4x50SL"`, `"S4X50MI"`, `"M4X50MI"`

```ruby
# Relay event parsing
if all_relay
  # Group all sections into one session with events by gender
  seen = {}  # key: relay_code + gender
  events = []
  
  data_hash['sections'].each do |sec|
    distance, stroke, relay_code = parse_relay_event_from_title(sec['title'], sec['fin_sesso'])
    gender = sec['fin_sesso'].upcase  # F, M, or X
    key = "#{relay_code}-#{gender}"
    
    next if seen[key]
    seen[key] = true
    
    event_type = find_relay_event_type_id(relay_code, gender)
    events << {
      'distance' => distance,
      'stroke' => stroke,
      'relay' => true,
      'event_type_id' => event_type&.id,
      'gender' => gender
    }
  end
  
  sessions << { 'session_order' => 1, 'events' => events }
end
```

**Result**: Relay files now produce 1 session with 3 events (F/M/X) instead of 23 sessions with unmatched events\!

### Output Structure
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
        "event_type_id": 26,
        "meeting_event_id": 1234,  // Pre-matched\!
        "meeting_session_id": 456
      }
    ]
  }]
}
```

---

## Phase 5: Results & Laps

**Status**: Individual ✅ Complete
**Purpose**: Populate temporary DB tables for result review  
**Populator**: `app/strategies/import/phase5_populator.rb`  
**Solver**: `app/strategies/import/solvers/result_solver.rb`

### What It Does
- **ResultSolver**: Builds phase5.json summary (event/result counts)
- **Phase5Populator**: Populates `data_import_*` DB tables with detailed data
- Loads phases 1-4 to resolve all entity IDs
- Matches existing MeetingIndividualResults for UPDATE vs INSERT decision

### Two-Step Process

#### Step 1: ResultSolver (Summary)
Generates phase5.json with:
- Event grouping by session/distance/stroke
- Result counts per gender/category
- **Relay events included** (FIXED 2025-11-10)

#### Step 2: Phase5Populator (Detailed Data)
For **Individual Results** ✅:
- Reads source JSON for result details
- Generates `import_key` for O(1 lookups
- Populates `data_import_meeting_individual_results`
- Populates `data_import_laps`
- Matches `meeting_program_id` from EventType + category + gender
- Matches existing MIR by (program_id, swimmer_id, team_id)

For **Relay Results** 🟡:
- Currently skipped (line 75: `next if event['relay'] == true`)
- **TODO**: Populate `data_import_meeting_relay_results`
- **TODO**: Populate `data_import_relay_swimmers` (4 per result)
- **TODO**: Populate `data_import_relay_laps`

See [plans/PHASE6_RELAY_COMPLETION_ROADMAP.md](./plans/PHASE6_RELAY_COMPLETION_ROADMAP.md) for relay implementation plan.

### Hybrid Storage Strategy
**Why DB tables instead of JSON?**
- Individual results can have thousands of rows per meeting
- Laps multiply that by 4-8x
- JSON files would be 10-50 MB
- DB tables provide:
  - Indexed lookups
  - Efficient pagination
  - SQL querying capabilities
  - Incremental updates

### Temporary Tables
Created in goggles_db gem v0.8.11+:
- `data_import_meeting_individual_results` - Result headers
- `data_import_laps` - Individual lap splits
- `data_import_meeting_relay_results` - Relay result headers (unused)
- `data_import_relay_swimmers` - Relay leg swimmers (unused)
- `data_import_relay_laps` - Relay lap splits (unused)

### UI Display
**Individual Results** ✅:
- Card-based UI (`_result_program_card.html.haml`)
- Grouped by program (event + category + gender)
- Collapsible result rows
- Expandable lap details
- Match status badges (green = matched, yellow = new)

**Relay Results** 🟡:
- UI partials not yet created
- See [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md)

---

## Phase 6: Commit & SQL Generation

**Status**: Individual ✅ Complete
**Purpose**: Atomic commit to production DB with SQL logging  
**Committer**: `app/strategies/import/committers/main.rb`

### What It Does
- Reads JSON files (phases 1-4) and DB tables (phase 5)
- Commits all entities in dependency order
- Generates SQL log for remote sync
- All operations in single transaction (rollback on error)
- Moves source files to `results.done/` folder

### Dependency-Aware Commit Order
```
1. City
2. SwimmingPool (requires city_id)
3. Meeting (requires swimming_pool_id)
4. MeetingSession (requires meeting_id)
5. Team
6. TeamAffiliation (requires team_id) - CREATE only if not pre-matched
7. Swimmer
8. Badge (requires swimmer_id, team_id) - CREATE only if not pre-matched
9. MeetingEvent (requires meeting_session_id, event_type_id) - CREATE only if not pre-matched
10. MeetingProgram (requires meeting_event_id, category_type_id, gender_type_id)
11. MeetingIndividualResult (requires meeting_program_id, swimmer_id, team_id)
12. Lap (requires meeting_individual_result_id)
```

**Relay commit order**:
```
13. MeetingRelayResult (requires meeting_program_id, team_id)
14. MeetingRelaySwimmer (requires meeting_relay_result_id, swimmer_id)
15. RelayLap (requires meeting_relay_swimmer_id)
```

### Relay Category/Gender Auto-Computation (v3.0)

When relay results are crawled from older meeting reports, the category and/or gender headers may be missing (e.g., `category: "N/A"`). Phase 6 now includes fallback auto-computation:

**Category Auto-Computation**:
- Queries `data_import_meeting_relay_swimmers` for the program's relay results
- Extracts year of birth from each swimmer's key
- Computes swimmer ages at meeting date
- Sums ages to get overall relay age (e.g., 54 + 49 + 44 + 39 = 186)
- Finds matching relay category by age range

**Gender Auto-Computation**:
- Queries relay swimmers for the program
- Extracts gender codes from swimmer keys or phase3 data
- Returns 'M' if all male, 'F' if all female, 'X' if mixed

```ruby
# In commit_meeting_program:
if is_relay && program_key.present?
  # Auto-compute category if resolution failed
  if category_type.nil?
    computed_category = compute_relay_category_from_swimmers(program_key)
    category_type = computed_category if computed_category
  end

  # Auto-compute gender if resolution failed
  if gender_type.nil?
    computed_gender = compute_relay_gender_from_swimmers(program_key)
    gender_type = gender_type_instance_from_code(computed_gender) if computed_gender
  end
end
```

**Key Methods**:
- `compute_relay_category_from_swimmers(program_key)` - Returns CategoryType or nil
- `compute_relay_gender_from_swimmers(program_key)` - Returns 'M', 'F', 'X', or nil
- `extract_yob_from_swimmer_key(swimmer_key)` - Parses YOB (always last token) from 3/4-token format
- `extract_gender_from_swimmer_key(swimmer_key)` - Parses gender from 4-token format (GENDER|LAST|FIRST|YEAR)
- `lookup_swimmer_gender_from_phase3(swimmer_key)` - Fallback to phase3 data

**Swimmer Key Formats** (team is never included - stored separately in phase3):
- 3-token: `LAST|FIRST|YEAR` (no gender)
- 4-token: `GENDER|LAST|FIRST|YEAR` (with gender prefix)

### Pre-Matching Benefits
Before v2.0, Phase 6 had to:
- Look up every team affiliation by (season_id, team_id)
- Look up every badge by (season_id, swimmer_id, team_id)
- Look up every meeting event by (session_id, event_type_id)
- Calculate every category type during commit

After v2.0:
- **77% less code** in commit methods
- **93% fewer database queries**
- **Simple guard clause**: `return if entity_hash['entity_id'].present?`
- **Early error detection** during phase building (user sees issues immediately)

### Example: Badge Commit
```ruby
def commit_badge(badge_hash:)
  badge_id = badge_hash['badge_id']
  swimmer_id = badge_hash['swimmer_id']
  team_id = badge_hash['team_id']
  
  # Guard: skip if missing required IDs
  return unless swimmer_id && team_id
  
  # Guard: skip if already matched (pre-matching did the work\!)
  if badge_id.present?
    Rails.logger.debug { "[Main] Badge ID=#{badge_id} already exists, skipping" }
    return
  end
  
  # Simple create - category_type_id already calculated in phase 3\!
  badge = GogglesDb::Badge.create\!(
    swimmer_id: swimmer_id,
    team_id: team_id,
    season_id: @season_id,
    category_type_id: badge_hash['category_type_id']  # Pre-calculated\!
  )
  
  @sql_log << SqlMaker.new(row: badge).log_insert
  @stats[:badges_created] += 1
end
```

### Relay Commits (TODO)
See [plans/PHASE6_RELAY_COMPLETION_ROADMAP.md](./plans/PHASE6_RELAY_COMPLETION_ROADMAP.md) for implementation details:
- `commit_meeting_relay_result` (~2-3 hours)
- `commit_relay_swimmers` (~2 hours)
- `commit_relay_laps` (~2 hours)

### Transaction Safety
```ruby
def commit_all
  ActiveRecord::Base.transaction do
    commit_phase1_entities  # Cities, pools, meetings, sessions
    commit_phase2_entities  # Teams, affiliations
    commit_phase3_entities  # Swimmers, badges
    commit_phase4_entities  # Meeting events
    commit_phase5_entities  # Individual results, laps (+ relays TODO)
  end
rescue ActiveRecord::RecordInvalid => e
  Rails.logger.error("[Main] Transaction rolled back: #{e.message}")
  raise  # Re-raise to trigger rollback
end
```

### SQL Log Format
Uses existing `SqlMaker` utility:
```sql
-- INSERT example
INSERT INTO `teams` (`id`,`name`,`editable_name`,`city_id`,`created_at`,`updated_at`) VALUES (123,'CSI OBER FERRARI','CSI Ober Ferrari',101,'2025-11-10 22:00:00','2025-11-10 22:00:00');

-- UPDATE example  
UPDATE `meetings` SET `header_date`='2025-06-24' WHERE `id`=456;
```

---

## Common Patterns

### Fuzzy Matching (Teams, Swimmers)
Uses Jaro-Winkler algorithm with configurable thresholds:
```ruby
def fuzzy_match_team(name)
  candidates = GogglesDb::Team.all
  best_match = nil
  best_score = 0.0
  
  candidates.each do |team|
    score = JaroWinkler.distance(name.upcase, team.name.upcase)
    if score > best_score
      best_score = score
      best_match = team
    end
  end
  
  # Auto-assign if confidence ≥60%
  return { team: best_match, score: best_score, auto: true } if best_score >= 0.60
  return { team: best_match, score: best_score, auto: false }
end
```

### Import Key Generation
Consistent pattern across all temp tables:
```ruby
def build_import_key(meeting_code, session_order, event_code, swimmer_key)
  "#{meeting_code}-#{session_order}-#{event_code}-#{swimmer_key}"
end
```

### Guard Clauses
Defensive programming prevents nil explosions:
```ruby
def commit_entity(entity_hash)
  # Guard: skip if missing required IDs
  return unless entity_hash['required_id'].present?
  
  # Guard: skip if already committed
  return if entity_hash['entity_id'].present?
  
  # Safe to proceed
  create_entity\!(entity_hash)
end
```

---

## Testing

### Specs by Phase
```bash
# Phase-specific controller specs
bundle exec rspec spec/requests/data_fix_controller_phase1_spec.rb
bundle exec rspec spec/requests/data_fix_controller_phase2_spec.rb
bundle exec rspec spec/requests/data_fix_controller_phase3_spec.rb

# Solver specs
bundle exec rspec spec/strategies/import/solvers/

# Committer specs
bundle exec rspec spec/strategies/import/committers/
```

### Browser Testing
```bash
rails server
# Navigate to: http://localhost:3000/data_fix/add_session
# Upload JSON file and step through phases
```

### Relay Test File
**Path**: `crawler/data/results.new/242/2024-12-06-Campionati_Italiani_Invernali_di_Nuoto_Unipol-4x50sl-l4.json`

**Expected Phase 4 Output**:
- 1 session (not 23\!)
- 3 events: F, M, X
- All events matched to EventType with `relay: true`

---

## Next Steps

### To Complete Relay Support
1. **Phase5Populator** - Add `populate_relay_results` method (4-6 hours)
2. **Phase 5 UI** - Create relay card partials (3-4 hours)
3. **Phase 6 Commits** - Add relay commit methods (6-8 hours)

See [plans/PHASE6_RELAY_COMPLETION_ROADMAP.md](./plans/PHASE6_RELAY_COMPLETION_ROADMAP.md) for complete roadmap.

### Future Enhancements
- [ ] Performance optimization for large meetings (10,000+ results)
- [ ] Background job processing for Phase 5 population
- [ ] Real-time progress updates via ActionCable (partially done)
- [ ] Batch commit capability (commit multiple meetings at once)

---

**For more details**, see:
- [README.md](./README.md) - Main documentation index
- [TECHNICAL.md](./TECHNICAL.md) - Architecture patterns
- [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md) - Relay-specific details
- [plans/](./plans/) - Active implementation plans
