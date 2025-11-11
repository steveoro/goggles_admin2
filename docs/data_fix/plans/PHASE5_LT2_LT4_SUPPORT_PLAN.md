# Phase 5: LT2 + LT4 Relay Support Implementation Plan

**Created**: 2025-11-10  
**Status**: 🎯 READY TO IMPLEMENT  
**Estimated Time**: 10-14 hours total

---

## Executive Summary

**Problem Found**:
- Phase5Populator only handles LT4 format (`source_data['events']`)
- Test relay file is LT2 format (has `meeting_relay_result` keys, no `events` array)
- All relay events skipped even when present (line 75)
- "Use Legacy" buttons misleading - should be removed

**Solution**:
1. Add LT2 format detection to Phase5Populator
2. Implement LT2 relay population logic
3. Implement LT4 relay population logic (separate methods)
4. Remove "Use Legacy" buttons from all phase views
5. Update documentation

---

## Architecture Clarification ✅

**Phase 5 Data Flow**:
```
Source JSON (LT2 or LT4)
    ↓
ResultSolver → phase5.json (SUMMARY only: result counts)
    ↓
Phase5Populator → Reads SOURCE file for DETAILED data (laps, timings)
    ↓
data_import_* DB tables (full lap details)
```

**Key Insight**: Phase5Populator **must** read source file because:
- Phase5 JSON = summary only (no lap details)
- Lap/timing data exists ONLY in source file
- Database needs full lap details for commit

---

## Step-by-Step Implementation

### STEP 1: Remove "Use Legacy" Buttons (30 min) 🎯 START HERE

**Goal**: Clean up misleading UI elements

**Files to modify**:
- `app/views/data_fix/review_sessions_v2.html.haml`
- `app/views/data_fix/review_teams.html.haml`
- `app/views/data_fix/review_swimmers_v2.html.haml`
- `app/views/data_fix/review_events_v2.html.haml`
- `app/views/data_fix/review_results_v2.html.haml`

**Actions**:
1. Search each file for "Use Legacy" or "legacy" buttons
2. Remove button elements
3. Remove any associated controller actions if unused
4. Test each phase review page loads correctly

**Verification**:
```bash
# Search for legacy button references
grep -r "Use Legacy" app/views/data_fix/
grep -r "use_legacy" app/views/data_fix/
```

---

### STEP 2: Add Format Detection to Phase5Populator (1 hour)

**Goal**: Detect LT2 vs LT4 source format

**File**: `app/strategies/import/phase5_populator.rb`

**Implementation**:

```ruby
# Add after line 43 (in private section)
def source_format
  @source_format ||= detect_source_format
end

def detect_source_format
  # LT2 has direct entity keys
  if source_data.key?('meeting_individual_result') || source_data.key?('meeting_relay_result')
    :lt2
  # LT4 has events array
  elsif source_data.key?('events')
    :lt4
  else
    raise "Unknown source format: no 'events' or 'meeting_individual_result' found"
  end
end
```

**Update `populate!` method (line 38)**:
```ruby
def populate!
  truncate_tables!
  load_phase_files!
  
  # Route based on source format
  case source_format
  when :lt2
    populate_lt2_results!  # NEW
  when :lt4
    populate_lt4_results!  # Renamed from populate_individual_results!
  end
  
  stats
end
```

**Refactor existing method (line 71)**:
```ruby
# Rename populate_individual_results! → populate_lt4_results!
def populate_lt4_results!
  events = source_data['events'] || []
  # ... rest of existing logic
end
```

---

### STEP 3: Implement LT2 Individual Results (2-3 hours)

**Goal**: Populate individual results from LT2 format

**File**: `app/strategies/import/phase5_populator.rb`

**Add new method**:
```ruby
def populate_lt2_results!
  # LT2 has direct arrays of entities
  individual_results = source_data['meeting_individual_result'] || []
  
  individual_results.each do |mir_data|
    # LT2 structure:
    # {
    #   "meeting_program_id": 123,
    #   "swimmer_id": 456,
    #   "team_id": 789,
    #   "rank": 1,
    #   "minutes": 5,
    #   "seconds": 5,
    #   "hundredths": 84,
    #   ... other fields
    # }
    
    # Match program from phase4 (may need to find by session/event/category/gender)
    program_key = find_program_key_from_lt2_mir(mir_data)
    swimmer_key = find_swimmer_key_from_phase3(mir_data['swimmer_id'])
    import_key = GogglesDb::DataImportMeetingIndividualResult.build_import_key(program_key, swimmer_key)
    
    # Create MIR record
    mir = create_mir_record(
      import_key: import_key,
      result: mir_data,
      swimmer_id: mir_data['swimmer_id'],
      team_id: mir_data['team_id'],
      program_id: mir_data['meeting_program_id'],
      timing_hash: {
        minutes: mir_data['minutes'],
        seconds: mir_data['seconds'],
        hundredths: mir_data['hundredths']
      }
    )
    
    @stats[:mir_created] += 1
    
    # Process laps for this MIR
    create_lap_records_lt2(mir, mir_data, import_key)
  end
end

def create_lap_records_lt2(mir, mir_data, mir_import_key)
  # LT2 laps are in source_data['lap'] array with parent reference
  all_laps = source_data['lap'] || []
  mir_laps = all_laps.select { |lap| lap['meeting_individual_result_id'] == mir_data['id'] }
  
  mir_laps.sort_by { |lap| lap['length_in_meters'] }.each_with_index do |lap_data, idx|
    lap_import_key = GogglesDb::DataImportLap.build_import_key(mir_import_key, idx + 1)
    
    GogglesDb::DataImportLap.create!(
      import_key: lap_import_key,
      parent_import_key: mir_import_key,
      phase_file_path: source_path,
      length_in_meters: lap_data['length_in_meters'],
      minutes: lap_data['minutes'],
      seconds: lap_data['seconds'],
      hundredths: lap_data['hundredths'],
      minutes_from_start: lap_data['minutes_from_start'],
      seconds_from_start: lap_data['seconds_from_start'],
      hundredths_from_start: lap_data['hundredths_from_start']
    )
    
    @stats[:laps_created] += 1
  end
end
```

**Helper method**:
```ruby
def find_program_key_from_lt2_mir(mir_data)
  # Look up meeting_program in phase4 data
  # Return key in format: "session_order-event_code-category-gender"
  # May need to query phase1/phase4 data to reconstruct
  
  # For now, generate from available data
  session_order = mir_data['session_order'] || 1
  event_code = mir_data['event_code'] || "#{mir_data['distance']}#{mir_data['stroke']}"
  category = mir_data['category_code']
  gender = mir_data['gender_code']
  
  "#{session_order}-#{event_code}-#{category}-#{gender}"
end

def find_swimmer_key_from_phase3(swimmer_id)
  return '' unless swimmer_id
  
  swimmers = phase3_data.dig('data', 'swimmers') || []
  swimmer = swimmers.find { |s| s['swimmer_id'] == swimmer_id }
  swimmer&.dig('key') || ''
end
```

---

### STEP 4: Implement LT2 Relay Results (3-4 hours)

**Goal**: Populate relay results from LT2 format

**File**: `app/strategies/import/phase5_populator.rb`

**Update `populate_lt2_results!`** to handle relays:
```ruby
def populate_lt2_results!
  populate_lt2_individual_results!  # Extract previous logic
  populate_lt2_relay_results!       # NEW
end

def populate_lt2_relay_results!
  relay_results = source_data['meeting_relay_result'] || []
  
  relay_results.each do |mrr_data|
    # LT2 relay structure:
    # {
    #   "id": 12345,
    #   "meeting_program_id": 123,
    #   "team_id": 789,
    #   "rank": 1,
    #   "minutes": 2,
    #   "seconds": 8,
    #   "hundredths": 12,
    #   ...
    # }
    
    # Generate import_key
    program_key = find_program_key_from_phase4(mrr_data['meeting_program_id'])
    team_key = find_team_key_from_phase2(mrr_data['team_id'])
    import_key = build_relay_import_key(program_key, team_key)
    
    # Create DataImportMeetingRelayResult
    relay_result = GogglesDb::DataImportMeetingRelayResult.create!(
      import_key: import_key,
      phase_file_path: source_path,
      meeting_program_id: mrr_data['meeting_program_id'],
      team_id: mrr_data['team_id'],
      rank: mrr_data['rank'],
      minutes: mrr_data['minutes'],
      seconds: mrr_data['seconds'],
      hundredths: mrr_data['hundredths'],
      disqualified: mrr_data['disqualified'] || false,
      standard_points: mrr_data['standard_points'] || 0.0,
      meeting_points: mrr_data['meeting_points'] || 0.0
    )
    
    @stats[:relay_results_created] ||= 0
    @stats[:relay_results_created] += 1
    
    # Process relay swimmers (legs)
    create_relay_swimmers_lt2(relay_result, mrr_data)
  end
end

def create_relay_swimmers_lt2(relay_result, mrr_data)
  # Find relay swimmers for this relay result
  all_relay_swimmers = source_data['meeting_relay_swimmer'] || []
  relay_swimmers = all_relay_swimmers.select { |rs| rs['meeting_relay_result_id'] == mrr_data['id'] }
  
  relay_swimmers.sort_by { |rs| rs['relay_order'] }.each do |rs_data|
    swimmer = GogglesDb::DataImportRelaySwimmer.create!(
      data_import_meeting_relay_result_id: relay_result.id,
      relay_order: rs_data['relay_order'],
      swimmer_id: rs_data['swimmer_id'],
      stroke_type_id: rs_data['stroke_type_id'],
      minutes: rs_data['minutes'],
      seconds: rs_data['seconds'],
      hundredths: rs_data['hundredths'],
      minutes_from_start: rs_data['minutes_from_start'],
      seconds_from_start: rs_data['seconds_from_start'],
      hundredths_from_start: rs_data['hundredths_from_start']
    )
    
    @stats[:relay_swimmers_created] ||= 0
    @stats[:relay_swimmers_created] += 1
    
    # Process relay laps for this swimmer
    create_relay_laps_lt2(swimmer, rs_data)
  end
end

def create_relay_laps_lt2(relay_swimmer, rs_data)
  # Find relay laps for this relay swimmer
  all_relay_laps = source_data['relay_lap'] || []
  relay_laps = all_relay_laps.select { |rl| rl['meeting_relay_swimmer_id'] == rs_data['id'] }
  
  relay_laps.each do |rl_data|
    GogglesDb::DataImportRelayLap.create!(
      data_import_relay_swimmer_id: relay_swimmer.id,
      length_in_meters: rl_data['length_in_meters'],
      minutes: rl_data['minutes'],
      seconds: rl_data['seconds'],
      hundredths: rl_data['hundredths'],
      minutes_from_start: rl_data['minutes_from_start'],
      seconds_from_start: rl_data['seconds_from_start'],
      hundredths_from_start: rl_data['hundredths_from_start']
    )
    
    @stats[:relay_laps_created] ||= 0
    @stats[:relay_laps_created] += 1
  end
end
```

**Helper methods**:
```ruby
def build_relay_import_key(program_key, team_key)
  "#{program_key}-RELAY-#{team_key}"
end

def find_program_key_from_phase4(meeting_program_id)
  # Look up in phase4 data by meeting_program_id if available
  # Otherwise construct from session/event data
  "1-S4X50MI-M45-F"  # Example - needs actual lookup
end

def find_team_key_from_phase2(team_id)
  teams = phase2_data.dig('data', 'teams') || []
  team = teams.find { |t| t['team_id'] == team_id }
  team&.dig('key') || ''
end
```

---

### STEP 5: Implement LT4 Relay Results (3-4 hours)

**Goal**: Populate relay results from LT4 format (events array)

**File**: `app/strategies/import/phase5_populator.rb`

**Update existing method (line 74-75)**:
```ruby
def populate_lt4_results!
  events = source_data['events'] || []
  
  events.each_with_index do |event, _idx|
    # CHANGE FROM:
    # next if event['relay'] == true # Skip relay events for now
    
    # TO:
    if event['relay'] == true
      populate_lt4_relay_event(event)
      next
    end
    
    # ... rest of individual result logic
  end
end
```

**Add new method**:
```ruby
def populate_lt4_relay_event(event)
  session_order = event['sessionOrder'] || 1
  event_code = event['eventCode']
  results = Array(event['results'])
  
  results.each do |result|
    # LT4 relay result structure:
    # {
    #   "team": "CSI OBER FERRARI",
    #   "rank": 1,
    #   "timing": "2'08.12",
    #   "relay_swimmers": [
    #     {"swimmer": "ROSSI|MARIO|1978", "timing": "0'32.00", "stroke": "DO"},
    #     {"swimmer": "BIANCHI|LUIGI|1980", "timing": "0'33.50", "stroke": "RA"},
    #     {"swimmer": "VERDI|GIUSEPPE|1975", "timing": "0'31.12", "stroke": "FA"},
    #     {"swimmer": "NERI|PAOLO|1982", "timing": "0'31.50", "stroke": "SL"}
    #   ]
    # }
    
    # Generate import_key
    program_key = build_program_key(session_order, event_code, result['category'], result['gender'])
    team_key = result['team']
    import_key = build_relay_import_key(program_key, team_key)
    
    # Match entity IDs from phase files
    team_id = find_team_id(team_key)
    meeting_program_id = find_meeting_program_id(session_order, event_code, result['category'], result['gender'])
    
    # Parse timing
    timing_hash = parse_timing_string(result['timing'])
    
    # Create relay result
    relay_result = GogglesDb::DataImportMeetingRelayResult.create!(
      import_key: import_key,
      phase_file_path: source_path,
      meeting_program_id: meeting_program_id,
      team_id: team_id,
      rank: result['rank'],
      minutes: timing_hash[:minutes],
      seconds: timing_hash[:seconds],
      hundredths: timing_hash[:hundredths],
      disqualified: result['disqualified'] || false,
      standard_points: result['standard_points'] || 0.0,
      meeting_points: result['meeting_points'] || 0.0
    )
    
    @stats[:relay_results_created] ||= 0
    @stats[:relay_results_created] += 1
    
    # Process relay swimmers (legs)
    create_relay_swimmers_lt4(relay_result, result, event_code)
  end
end

def create_relay_swimmers_lt4(relay_result, result, event_code)
  relay_swimmers = result['relay_swimmers'] || result['legs'] || []
  
  relay_swimmers.each_with_index do |leg, idx|
    # Parse swimmer key
    swimmer_key = leg['swimmer']
    swimmer_id = find_swimmer_id(swimmer_key)
    
    # Determine stroke type
    stroke_type_id = determine_stroke_type_id(event_code, idx)
    
    # Parse leg timing
    leg_timing = parse_timing_string(leg['timing'])
    
    # Compute from_start (cumulative)
    from_start = compute_from_start_for_leg(relay_swimmers, idx)
    
    swimmer = GogglesDb::DataImportRelaySwimmer.create!(
      data_import_meeting_relay_result_id: relay_result.id,
      relay_order: idx + 1,
      swimmer_id: swimmer_id,
      stroke_type_id: stroke_type_id,
      minutes: leg_timing[:minutes],
      seconds: leg_timing[:seconds],
      hundredths: leg_timing[:hundredths],
      minutes_from_start: from_start[:minutes],
      seconds_from_start: from_start[:seconds],
      hundredths_from_start: from_start[:hundredths]
    )
    
    @stats[:relay_swimmers_created] ||= 0
    @stats[:relay_swimmers_created] += 1
    
    # Create relay laps if present
    create_relay_laps_lt4(swimmer, leg)
  end
end

def create_relay_laps_lt4(relay_swimmer, leg_data)
  laps = leg_data['laps'] || []
  
  laps.each do |lap|
    lap_timing = parse_timing_string(lap['timing'])
    
    GogglesDb::DataImportRelayLap.create!(
      data_import_relay_swimmer_id: relay_swimmer.id,
      length_in_meters: lap['length_in_meters'] || 50,
      minutes: lap_timing[:minutes],
      seconds: lap_timing[:seconds],
      hundredths: lap_timing[:hundredths],
      # from_start computed if available
      minutes_from_start: lap['minutes_from_start'],
      seconds_from_start: lap['seconds_from_start'],
      hundredths_from_start: lap['hundredths_from_start']
    )
    
    @stats[:relay_laps_created] ||= 0
    @stats[:relay_laps_created] += 1
  end
end
```

**Stroke mapping helper**:
```ruby
def determine_stroke_type_id(event_code, leg_index)
  # For mixed relays (*MI), map leg order to stroke
  if event_code =~ /MI$/
    case leg_index
    when 0 then 3  # Backstroke (DO)
    when 1 then 4  # Breaststroke (RA)
    when 2 then 2  # Butterfly (FA)
    when 3 then 1  # Freestyle (SL)
    end
  # For single-stroke relays, all legs same stroke
  elsif event_code =~ /SL$/
    1  # Freestyle
  elsif event_code =~ /DO$/
    3  # Backstroke
  elsif event_code =~ /RA$/
    4  # Breaststroke
  elsif event_code =~ /FA$/
    2  # Butterfly
  end
end

def compute_from_start_for_leg(relay_swimmers, current_leg_index)
  # Sum all previous leg timings
  total_hundredths = 0
  
  relay_swimmers[0..current_leg_index].each do |leg|
    leg_timing = parse_timing_string(leg['timing'])
    total_hundredths += leg_timing[:minutes] * 6000 + leg_timing[:seconds] * 100 + leg_timing[:hundredths]
  end
  
  {
    minutes: total_hundredths / 6000,
    seconds: (total_hundredths % 6000) / 100,
    hundredths: total_hundredths % 100
  }
end
```

---

### STEP 6: Update Stats Tracking (30 min)

**File**: `app/strategies/import/phase5_populator.rb`

**Update `initialize` method (line 34)**:
```ruby
def initialize(source_path:, phase1_path:, phase2_path:, phase3_path:, phase4_path:)
  @source_path = source_path
  @phase1_path = phase1_path
  @phase2_path = phase2_path
  @phase3_path = phase3_path
  @phase4_path = phase4_path
  @stats = {
    mir_created: 0,
    laps_created: 0,
    relay_results_created: 0,        # NEW
    relay_swimmers_created: 0,       # NEW
    relay_laps_created: 0,           # NEW
    programs_matched: 0,
    mirs_matched: 0,
    errors: []
  }
end
```

**Update controller flash message** (`app/controllers/data_fix_controller.rb` line 401):
```ruby
flash.now[:info] =
  "Populated DB: #{@populate_stats[:mir_created]} individual results, #{@populate_stats[:relay_results_created]} relay results, #{@populate_stats[:laps_created]} laps, #{@populate_stats[:relay_laps_created]} relay laps"
```

---

### STEP 7: Testing (2 hours)

**Test LT2 relay file**:
```ruby
# Rails console
season = GogglesDb::Season.find(242)
source_path = 'crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json'

populator = Import::Phase5Populator.new(
  source_path: source_path,
  phase1_path: source_path.gsub('.json', '-phase1.json'),
  phase2_path: source_path.gsub('.json', '-phase2.json'),
  phase3_path: source_path.gsub('.json', '-phase3.json'),
  phase4_path: source_path.gsub('.json', '-phase4.json')
)

stats = populator.populate!
puts "Relay results: #{stats[:relay_results_created]}"
puts "Relay swimmers: #{stats[:relay_swimmers_created]}"
puts "Relay laps: #{stats[:relay_laps_created]}"
```

**Verify database**:
```ruby
GogglesDb::DataImportMeetingRelayResult.count  # Should be > 0
GogglesDb::DataImportRelaySwimmer.count        # Should be ~4x relay results
GogglesDb::DataImportRelayLap.count            # Should be > 0
```

**Write specs**:
- `spec/strategies/import/phase5_populator_lt2_spec.rb`
- `spec/strategies/import/phase5_populator_lt4_relay_spec.rb`

---

### STEP 8: Update Documentation (1 hour)

**Files to update**:
1. `/docs/data_fix/PHASES.md` - Update Phase 5 section with LT2+LT4 support
2. `/docs/data_fix/TECHNICAL.md` - Add format detection section
3. `/docs/data_fix/RELAY_IMPLEMENTATION.md` - Update populator status
4. `/docs/data_fix/CHANGELOG.md` - Add entry for LT2+LT4 support

---

## Summary Checklist

- [ ] **Step 1**: Remove "Use Legacy" buttons (30 min)
- [ ] **Step 2**: Add format detection (1 hour)
- [ ] **Step 3**: LT2 individual results (2-3 hours)
- [ ] **Step 4**: LT2 relay results (3-4 hours)
- [ ] **Step 5**: LT4 relay results (3-4 hours)
- [ ] **Step 6**: Update stats tracking (30 min)
- [ ] **Step 7**: Testing (2 hours)
- [ ] **Step 8**: Documentation (1 hour)

**Total**: 10-14 hours

---

## Next Steps After Completion

1. Phase 5 relay UI display (relay card partials)
2. Phase 6 relay commit methods
3. End-to-end testing with both LT2 and LT4 files

See `PHASE6_RELAY_COMPLETION_ROADMAP.md` for Phase 6 details.
