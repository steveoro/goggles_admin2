# Technical Architecture & Patterns

**Last Updated**: 2025-11-10  
**Version**: 2.0 - Pre-Matching Pattern Established

This document describes the technical architecture, design patterns, and implementation details of the Data-Fix pipeline.

---

## Core Architecture Principles

### 1. "Solve Early, Commit Later"

**Philosophy**: All matching, calculation, and validation happens during phase building, not at commit time.

**Benefits**:
- **User sees errors immediately** during phase review (not after hours of processing)
- **Commit layer is pure persistence** - no business logic
- **77% less code** in Phase 6
- **93% fewer database queries** during commit

**Example**:
```ruby
# OLD (v1.0) - Matching at commit time
def commit_badge(badge_hash)
  swimmer = Swimmer.find_by(...)  # DB query
  team = Team.find_by(...)        # DB query
  category = calculate_category(...) # Computation
  affiliation = TeamAffiliation.find_by(...)  # DB query
  
  Badge.create\!(swimmer:, team:, category:, affiliation:)
end

# NEW (v2.0) - Matching at build time
def commit_badge(badge_hash)
  return if badge_hash['badge_id'].present?  # Already matched\!
  Badge.create\!(badge_hash.slice(...))       # Simple insert
end
```

### 2. Hybrid Storage Strategy

**Problem**: Phase 5 can have 10,000+ results with 50,000+ laps - JSON files would be 10-50 MB.

**Solution**: Use appropriate storage for each phase's data size:

| Phase | Data Size | Storage | Reason |
|-------|-----------|---------|--------|
| 1-4 | Small (KB) | JSON files | Easy to review, version control friendly |
| 5 | Large (MB) | DB tables | Indexed queries, pagination, incremental updates |
| 6 | N/A | Production DB | Final persistence |

**Implementation**:
```ruby
# Phase 4 (Events) - JSON
File.write(phase4_path, JSON.pretty_generate(events_data))

# Phase 5 (Results) - DB tables
GogglesDb::DataImportMeetingIndividualResult.create\!(
  import_key: key,
  swimmer_id: swimmer_id,
  timing: timing,
  # ... 20+ fields
)
```

### 3. Self-Contained Phase Files

**Principle**: Each phase file contains all IDs needed for the next phase.

**No cross-phase lookups at commit**: Phase 6 reads sequentially, never looks back.

**Example Phase Flow**:
```
Phase 1 → meeting_id: 123, meeting_session_id: 456
Phase 2 → (loads phase1) → team_id: 789, team_affiliation_id: 999
Phase 3 → (loads phase1+2) → swimmer_id: 111, badge_id: 222, category_type_id: 333
Phase 4 → (loads phase1) → event_type_id: 444, meeting_event_id: 555
Phase 5 → (loads phase1-4) → Populates DB with all IDs linked
Phase 6 → (reads JSON 1-4 + DB 5) → Commits sequentially
```

### 4. Guard Clauses Everywhere

**Principle**: Fail gracefully when data is missing.

**Pattern**:
```ruby
def process_entity(data)
  # Guard: skip if required data missing
  return unless data['required_field'].present?
  
  # Guard: skip if already processed
  return if data['entity_id'].present?
  
  # Safe to proceed
  perform_operation(data)
end
```

---

## Pre-Matching Pattern (v2.0)

### Overview

**What**: Resolve entity IDs during phase building instead of commit time.  
**When**: Phases 2, 3, 4  
**Why**: Faster commits, early error detection, simpler code

### Implementation

Each solver performs matching and stores the resolved ID in the phase file:

```ruby
# Generic pre-matching pattern
def build_entity_with_matching(entity_data)
  # 1. Build base entity structure
  entity_hash = { 'key' => key, 'name' => name, ... }
  
  # 2. Guard: skip if missing required data for matching
  return entity_hash unless can_match?(entity_data)
  
  # 3. Attempt to match existing entity
  existing = find_existing_entity(entity_data)
  entity_hash['entity_id'] = existing&.id
  
  # 4. Return with ID (or nil if not found)
  entity_hash
end
```

### Phase-Specific Examples

#### Phase 2: Team Affiliation
```ruby
def build_team_affiliation_entry(team_key, team_id)
  affiliation = {
    'team_key' => team_key,
    'season_id' => @season.id,
    'team_id' => team_id
  }
  
  return affiliation unless team_id  # Guard
  
  existing = GogglesDb::TeamAffiliation.find_by(
    season_id: @season.id,
    team_id: team_id
  )
  affiliation['team_affiliation_id'] = existing&.id
  affiliation
end
```

#### Phase 3: Badge + Category Calculation
```ruby
def build_badge_entry(swimmer_data, team_key)
  # Load dependencies
  meeting_date = @phase1_data.dig('meeting', 'header_date')
  team_id = find_team_id_from_phase2(team_key)
  swimmer_id = find_swimmer_id(swimmer_data)
  
  badge = {
    'swimmer_id' => swimmer_id,
    'team_id' => team_id,
    'season_id' => @season.id
  }
  
  # Calculate category (NEW in v2.0\!)
  category_type = GogglesDb::CategoriesCache.instance.for_swimmer(
    year_of_birth: swimmer_data['year_of_birth'],
    gender_code: swimmer_data['gender_type_code'],
    meeting_date: meeting_date
  )
  badge['category_type_id'] = category_type&.id
  
  # Match existing badge
  return badge unless swimmer_id && team_id  # Guard
  existing = GogglesDb::Badge.find_by(
    season_id: @season.id,
    swimmer_id: swimmer_id,
    team_id: team_id
  )
  badge['badge_id'] = existing&.id
  badge
end
```

#### Phase 4: Meeting Event
```ruby
def enhance_event_with_matching\!(event_hash, session_order)
  # Resolve session_id from phase1
  meeting_session_id = find_meeting_session_id_by_order(session_order)
  event_hash['meeting_session_id'] = meeting_session_id
  
  # Guard: skip if missing keys
  return unless meeting_session_id && event_hash['event_type_id']
  
  # Match existing meeting event
  existing = GogglesDb::MeetingEvent.find_by(
    meeting_session_id: meeting_session_id,
    event_type_id: event_hash['event_type_id']
  )
  event_hash['meeting_event_id'] = existing&.id
end
```

### Commit-Side Handling

Phase 6 checks for pre-matched IDs and skips if present:

```ruby
def commit_team_affiliation(affiliation_hash:)
  team_affiliation_id = affiliation_hash['team_affiliation_id']
  
  # If already matched, nothing to do\!
  if team_affiliation_id.present?
    Rails.logger.debug { "[Main] TeamAffiliation #{team_affiliation_id} exists, skipping" }
    return
  end
  
  # Only create if not pre-matched
  GogglesDb::TeamAffiliation.create\!(
    team_id: affiliation_hash['team_id'],
    season_id: affiliation_hash['season_id']
  )
end
```

---

## Fuzzy Matching

### Algorithm: Jaro-Winkler Distance

**Why Jaro-Winkler?**
- Better for short strings (team/swimmer names)
- Weights matches at the start of strings higher
- Returns 0.0-1.0 similarity score

**Implementation**:
```ruby
require 'jaro_winkler'

def fuzzy_match_team(search_name)
  candidates = GogglesDb::Team.all
  
  best_match = nil
  best_score = 0.0
  
  candidates.each do |team|
    score = JaroWinkler.distance(
      normalize_name(search_name),
      normalize_name(team.name)
    )
    
    if score > best_score
      best_score = score
      best_match = team
    end
  end
  
  {
    team: best_match,
    score: best_score,
    auto_assignable: best_score >= 0.60  # 60% threshold
  }
end

def normalize_name(name)
  name.to_s.upcase.strip
end
```

### Thresholds

| Entity | Auto-Assign Threshold | Manual Review Range |
|--------|----------------------|---------------------|
| Teams | ≥60% | 40-60% shown as candidates |
| Swimmers | ≥70% (with YOB match) | 50-70% shown as candidates |

**Color Coding in UI**:
- **Green** (≥threshold): Auto-assigned, user can override
- **Yellow** (below threshold): Requires manual selection
- **White**: No match found, will create new entity

---

## Import Key Pattern

### Purpose
Unique identifier for temporary table records, enabling:
- O(1) lookups without sequential IDs
- Deduplication
- Matching across multiple sources

### Format
```
"<meeting_code>-<session_order>-<event_code>-<entity_key>"
```

### Examples

**Individual Result**:
```ruby
meeting_code = "regcsi"
session_order = 1
event_code = "200RA"
swimmer_key = "ROSSI|MARIO|1978"

import_key = "regcsi-1-200RA-ROSSI|MARIO|1978"
```

**Relay Result**:
```ruby
import_key = "regcsi-1-S4X50MI-CSI_OBER_FERRARI"
```

### Implementation
```ruby
module GogglesDb
  class DataImportMeetingIndividualResult < ApplicationRecord
    def self.build_import_key(program_key, swimmer_key)
      "#{program_key}-#{swimmer_key}"
    end
    
    # Unique index in migration:
    # add_index :data_import_meeting_individual_results, :import_key, unique: true
  end
end
```

---

## Relay Event Processing (v2.1)

### Challenge

**Problem**: Italian Microplus relay files have unusual structure:
- 23 separate sections (one per heat)
- Each section has only relay: true flag
- Event details in Italian titles: "4x50 m Misti Femminile"
- Gender scattered across sections (F, M, X)

**Bad Outcome**: 23 sessions with unmatched events

### Solution

**Relay-Only File Detection**:
```ruby
all_relay = data_hash['sections'].all? do |sec|
  rows = sec['rows'] || []
  rows.any? { |row| row['relay'] == true }
end
```

**If relay-only, special processing**:
1. Group ALL sections into ONE session
2. Parse event details from Italian title
3. Deduplicate by gender (F, M, X)
4. Create 3 events total (one per gender)

**Title Parsing**:
```ruby
def parse_relay_event_from_title(title, fin_sesso)
  # "4x50 m Misti" → [200, "MI", "S4X50MI"]
  match = title.match(/(\d+)\s*[xX]\s*(\d+)\s*m/i)
  return [nil, nil, nil] unless match
  
  participants = match[1].to_i  # 4
  phase_length = match[2].to_i  # 50
  total_distance = participants * phase_length  # 200
  
  stroke_code = if title =~ /misti|medley/i
                  'MI'  # Mixed relay
                elsif title =~ /stile\s*libero|freestyle/i
                  'SL'  # Freestyle
                # ... other strokes
                end
  
  gender_prefix = (fin_sesso.to_s.upcase == 'X') ? 'M' : 'S'
  event_code = "#{gender_prefix}#{participants}X#{phase_length}#{stroke_code}"
  
  [total_distance, stroke_code, event_code]
end
```

**Event Type Matching**:
```ruby
def find_relay_event_type_id(event_code, gender)
  GogglesDb::EventType.find_by(
    code: event_code,
    relay: true
  )&.id
end
```

**Result**:
```
Before: 23 sections → 23 sessions, 0-23 unmatched events
After:  23 sections → 1 session, 3 events (F/M/X), all matched\!
```

---

## Timing Handling

### Challenge: Delta vs From-Start

**Source Data**: Microplus provides cumulative timing ("from start")
**Database Needs**: Both delta (lap split) and cumulative

**Example**:
```
Lap 1: 00:30.00 from start → delta: 00:30.00
Lap 2: 01:02.50 from start → delta: 00:32.50
Lap 3: 01:35.00 from start → delta: 00:32.50
Lap 4: 02:08.12 from start → delta: 00:33.12
```

### Solution: Dual Column Storage

**Migration** (goggles_db):
```ruby
add_column :data_import_laps, :minutes_from_start, :integer
add_column :data_import_laps, :seconds_from_start, :integer
add_column :data_import_laps, :hundredths_from_start, :integer
```

**Computation**:
```ruby
def compute_lap_timings(laps)
  previous_timing = Timing.new(0)
  
  laps.each do |lap|
    from_start = Timing.new(lap['timing'])
    delta = from_start - previous_timing
    
    lap['reaction_time'] = delta.to_hundredths  # Delta
    lap['minutes'] = delta.minutes
    lap['seconds'] = delta.seconds
    lap['hundredths'] = delta.hundredths
    
    lap['minutes_from_start'] = from_start.minutes  # Cumulative
    lap['seconds_from_start'] = from_start.seconds
    lap['hundredths_from_start'] = from_start.hundredths
    
    previous_timing = from_start
  end
end
```

---

## Error Handling

### Graceful Degradation

**Principle**: Never crash the entire process due to one bad record.

**Pattern**:
```ruby
def process_batch(records)
  records.each do |record|
    begin
      process_record(record)
      @stats[:success] += 1
    rescue StandardError => e
      @stats[:errors] << "Record #{record['key']}: #{e.message}"
      Rails.logger.error("[Processor] ERROR: #{e.message}")
      # Continue with next record
    end
  end
end
```

### Transaction Safety (Phase 6)

**All-or-nothing commit**:
```ruby
def commit_all
  ActiveRecord::Base.transaction do
    commit_phase1_entities
    commit_phase2_entities
    commit_phase3_entities
    commit_phase4_entities
    commit_phase5_entities
  end
rescue ActiveRecord::RecordInvalid => e
  @stats[:errors] << e.message
  Rails.logger.error("[Main] Transaction rolled back: #{e.message}")
  raise  # Re-raise to trigger rollback
end
```

**Benefit**: Database is never in partial state - either all entities commit or none do.

---

## Performance Optimizations

### 1. Eager Loading

**Problem**: N+1 queries when displaying results
```ruby
# BAD
results.each do |result|
  puts result.swimmer.name  # Query per result\!
end
```

**Solution**: Eager load associations
```ruby
# GOOD
results = DataImportMeetingIndividualResult
  .includes(:swimmer, :team, :laps)
  .where(season_id: season_id)

results.each do |result|
  puts result.swimmer.name  # No additional queries
end
```

### 2. Indexed Lookups

**Import Key Index**:
```ruby
add_index :data_import_meeting_individual_results, :import_key, unique: true
```

**Composite Indexes**:
```ruby
add_index :badges, [:season_id, :swimmer_id, :team_id], unique: true
add_index :meeting_events, [:meeting_session_id, :event_type_id], unique: true
```

### 3. Batch Inserts

For large datasets, use `insert_all`:
```ruby
# Instead of:
laps.each { |lap| DataImportLap.create\!(lap) }

# Use:
DataImportLap.insert_all(laps)  # Single query
```

### 4. Pagination

For UI display:
```ruby
@results = DataImportMeetingIndividualResult
  .where(season_id: season_id)
  .page(params[:page])
  .per(50)
```

---

## Testing Patterns

### Unit Tests (Solvers)

**Pattern**: Test with minimal fixtures
```ruby
RSpec.describe Import::Solvers::TeamSolver do
  let(:season) { create(:season) }
  let(:solver) { described_class.new(season: season) }
  
  it 'matches existing teams' do
    existing_team = create(:team, name: 'CSI OBER FERRARI')
    
    result = solver.match_team('csi ober ferrari')
    
    expect(result[:team]).to eq(existing_team)
    expect(result[:score]).to be >= 0.9
  end
end
```

### Integration Tests (Controller)

**Pattern**: Test full workflow
```ruby
RSpec.describe DataFixController, type: :request do
  let(:source_file) { fixture_file_upload('sample_meeting.json') }
  
  it 'processes all phases' do
    post data_fix_add_session_path, params: { source_file: source_file }
    
    expect(response).to redirect_to(data_fix_review_sessions_path)
    expect(Meeting.count).to eq(1)
    expect(MeetingSession.count).to be > 0
  end
end
```

### Temporary Test Scripts

For quick verification during development:
```ruby
# /tmp/test_event_solver.rb
require_relative 'config/environment'

season = GogglesDb::Season.find(242)
solver = Import::Solvers::EventSolver.new(season: season)

source_path = 'crawler/data/results.new/242/relay-file.json'
solver.build\!(source_path: source_path, lt_format: 4)

phase4_path = source_path.gsub('.json', '-phase4.json')
data = JSON.parse(File.read(phase4_path))

puts "Sessions: #{data['data']['sessions'].size}"
puts "Events: #{data['data']['sessions'].sum { |s| s['events'].size }}"
```

---

## File Organization

### Solvers
`app/strategies/import/solvers/`
- `phase1_solver.rb` - Meeting & sessions
- `team_solver.rb` - Teams (Phase 2)
- `swimmer_solver.rb` - Swimmers & badges (Phase 3)
- `event_solver.rb` - Events (Phase 4)
- `result_solver.rb` - Results summary (Phase 5a)

### Populators
`app/strategies/import/`
- `phase5_populator.rb` - DB table population (Phase 5b)

### Committers
`app/strategies/import/committers/`
- `main.rb` - Phase 6 orchestrator

### Services
`app/services/`
- `phase_file_manager.rb` - Phase JSON read/write
- `phase3/relay_enrichment_detector.rb` - Relay swimmer detection
- `phase3/relay_merge_service.rb` - Merge auxiliary phase3 files

### Views
`app/views/data_fix/`
- `review_sessions_v2.html.haml` - Phase 1 UI
- `review_teams.html.haml` - Phase 2 UI
- `review_swimmers_v2.html.haml` - Phase 3 UI
- `review_events_v2.html.haml` - Phase 4 UI
- `review_results_v2.html.haml` - Phase 5 UI

---

**For implementation examples**, see [PHASES.md](./PHASES.md)  
**For relay-specific details**, see [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md)  
**For current status**, see [README.md](./README.md)
