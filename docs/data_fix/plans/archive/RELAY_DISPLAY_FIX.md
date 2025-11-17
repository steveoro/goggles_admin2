# Relay Display Fix Plan

**Date**: 2025-11-13  
**Issues**: Multiple relay display and data problems identified

---

## Problems Identified

### 1. Unknown Swimmer Issue
**Root Cause**: Swimmer info extracted from `result['swimmers']` array, but swimmer lookup uses different key format than lap swimmer keys.

- `result['swimmers']` has: `"complete_name": "LA MORGIA Andrea"`
- `result['laps']` has: `"swimmer": "M|LA MORGIA|Andrea|1993|Team"`
- Swimmer lookup uses: `"LA|Andrea|1993"` (wrong - should be `"LA MORGIA|Andrea|1993"`)

**Real Issue**: We create MRS from swimmers array but don't extract swimmer info properly from lap keys.

### 2. Relay Data Structure Misunderstanding
**Correct Structure** (per user's clarification):
- `MRR` (MeetingRelayResult): Overall team relay result
- `MRS` (MeetingRelaySwimmer): Individual swimmer's leg timing  
- `relay_laps`: Additional sub-laps within a single MRS leg

**For 4x50m relay**:
- 1 MRR with overall timing
- 4 MRS (one per swimmer, each 50m)
- 4 relay_laps (one per 50m segment)
- NO sub-laps since each leg is exactly 50m

**Current Problem**: MRS timings are hardcoded to 0'00.00 instead of using lap delta.

### 3. Two Separate Tables
Should be merged into ONE table with columns:
`Order | Distance | Swimmer | From Start | Split | Status`

- Drop "Timing" column from Relay Swimmers table
- Drop "Δ Speed" column from Split Times table
- Status shows MRR/MRS/RelayLap match status (ID or "NEW")

### 4. No Results Loaded Issue
Controller doesn't query data properly - likely conditional logic issue.

### 5. Missing Progress Modal
Phase 5 populate doesn't use ActionCable broadcast.

---

## Solution Strategy

### Phase 1: Fix Relay Swimmer Creation (CRITICAL)

**Current flow (WRONG)**:
```ruby
# create_relay_swimmers: Uses result['swimmers'] array
swimmers = result['swimmers'] || []
swimmer_name = swimmer_data['complete_name']  # "LA MORGIA Andrea"
name_parts = swimmer_name.split(' ', 2)       # ["LA", "MORGIA Andrea"]
last_name = name_parts[0]                      # "LA" ← WRONG!
swimmer_key = "#{last_name}|#{first_name}|#{year}"  # "LA|MORGIA Andrea|1993"
```

**Fixed flow**:
```ruby
# create_relay_swimmers: Use laps array with swimmer keys
laps = result['laps'] || []
laps.each_with_index do |lap, idx|
  swimmer_key = lap['swimmer']  # "M|LA MORGIA|Andrea|1993|Team"
  # Parse swimmer key format: "GENDER|LAST|FIRST|YEAR|TEAM"
  parts = swimmer_key.split('|')
  last_name = parts[1]
  first_name = parts[2]
  year = parts[3]
  lookup_key = "#{last_name}|#{first_name}|#{year}"  # "LA MORGIA|Andrea|1993"
  swimmer_id = find_swimmer_id_by_key(lookup_key)
  
  # Parse lap timing for MRS
  delta = parse_timing_string(lap['delta'])
  
  # Create MRS with proper timing
  GogglesDb::DataImportMeetingRelaySwimmer.create!(
    import_key: "#{mrr_import_key}-swimmer#{idx + 1}",
    parent_import_key: mrr_import_key,
    swimmer_id: swimmer_id,
    relay_order: idx + 1,
    minutes: delta[:minutes],
    seconds: delta[:seconds],
    hundredths: delta[:hundredths],
    length_in_meters: lap_distance  # 50m for 4x50
  )
end
```

### Phase 2: Update Relay Lap Creation

```ruby
# Relay laps should still be created, but linked properly to MRS
# For 4x50m, each lap IS the full MRS leg (no sub-laps)
def create_relay_laps(_mrr, result, mrr_import_key)
  laps = result['laps'] || []
  previous_from_start = { minutes: 0, seconds: 0, hundredths: 0 }
  
  laps.each_with_index do |lap, idx|
    distance_str = lap['distance']
    length = distance_str.to_s.gsub(/\D/, '').to_i
    next if length.zero?
    
    delta = parse_timing_string(lap['delta'])
    from_start = compute_timing_sum(previous_from_start, delta)
    
    # Link to MRS by relay_order
    relay_order = idx + 1
    lap_import_key = "#{mrr_import_key}-lap#{relay_order}"
    
    GogglesDb::DataImportRelayLap.create!(
      import_key: lap_import_key,
      parent_import_key: mrr_import_key,
      length_in_meters: length,
      relay_order: relay_order,  # NEW: link to MRS
      minutes: delta[:minutes],
      seconds: delta[:seconds],
      hundredths: delta[:hundredths],
      minutes_from_start: from_start[:minutes],
      seconds_from_start: from_start[:seconds],
      hundredths_from_start: from_start[:hundredths]
    )
    
    @stats[:relay_laps_created] += 1
    previous_from_start = from_start
  end
end
```

### Phase 3: Merge Display Tables

**New unified table structure**:
```haml
%table.table.table-sm.table-bordered
  %thead.thead-light
    %tr
      %th.text-center Order
      %th.text-center Distance
      %th Swimmer
      %th.text-right From Start
      %th.text-right Split
      %th.text-center Status
  %tbody
    - relay_laps.sort_by(&:relay_order).each do |lap|
      :ruby
        # Find MRS for this lap
        mrs = relay_swimmers.find { |rs| rs.relay_order == lap.relay_order }
        swimmer = swimmers_by_id[mrs&.swimmer_id]
        
        # Check for existing MRR/MRS/RelayLap match
        mrs_match_id = mrs&.meeting_relay_swimmer_id
        lap_match_id = lap&.meeting_relay_lap_id
      %tr
        %td.text-center
          %strong= lap.relay_order
        %td.text-center= "#{lap.length_in_meters}m"
        %td
          - if swimmer
            = swimmer.complete_name
            - if mrs_match_id
              %small.ml-2.text-secondary
                ID: #{mrs_match_id}
            - else
              %small.ml-2.badge.badge-primary NEW
          - elsif mrs&.swimmer_id
            %em.text-muted Swimmer ##{mrs.swimmer_id}
          - else
            %span.text-danger MISSING
        %td.text-right
          = lap.from_start_timing.to_s
        %td.text-right
          = lap.to_timing.to_s
        %td.text-center
          - if lap_match_id
            %small.text-secondary ID: #{lap_match_id}
          - else
            %small.badge.badge-primary NEW
```

### Phase 4: Fix Controller Data Loading

**Issue**: Controller might not be loading relay data after populate.

```ruby
# In review_results method, ensure relay data always loads
def review_results
  # ... existing code ...
  
  # Always load relay results if source_path exists
  if File.exist?(source_path)
    @all_relay_results = GogglesDb::DataImportMeetingRelayResult
                         .where(phase_file_path: source_path)
                         .order(:import_key)
                         .limit(1000)
    
    # ... rest of relay loading code ...
  end
end
```

### Phase 5: Add Result Matching

**For MRR**: Match by `meeting_program_id` + `team_id`
**For MRS**: Match by `meeting_relay_result_id` + `swimmer_id` + `relay_order`  
**For RelayLap**: Match by `meeting_relay_result_id` + `length_in_meters` + `relay_order`

```ruby
# In create_mrr_record
def find_existing_mrr(meeting_program_id, team_id)
  return nil unless meeting_program_id && team_id
  
  GogglesDb::MeetingRelayResult
    .where(meeting_program_id: meeting_program_id, team_id: team_id)
    .first
    &.id
end

# In create_relay_swimmers
def find_existing_mrs(mrr_id, swimmer_id, relay_order)
  return nil unless mrr_id && swimmer_id
  
  GogglesDb::MeetingRelaySwimmer
    .where(meeting_relay_result_id: mrr_id, swimmer_id: swimmer_id, relay_order: relay_order)
    .first
    &.id
end

# In create_relay_laps
def find_existing_relay_lap(mrr_id, length, relay_order)
  return nil unless mrr_id
  
  GogglesDb::RelayLap
    .joins(:meeting_relay_swimmer)
    .where(meeting_relay_swimmers: { meeting_relay_result_id: mrr_id, relay_order: relay_order })
    .where(length_in_meters: length)
    .first
    &.id
end
```

---

## Implementation Order

1. ✅ Fix relay lap timing (DONE - previous fix)
2. 🔴 Fix `create_relay_swimmers` to use lap data (CRITICAL)
3. 🔴 Update relay lap creation with relay_order link
4. 🔴 Merge display tables into one
5. 🟡 Add result matching logic
6. 🟡 Fix controller data loading
7. 🟢 Add ActionCable progress (lower priority)

---

## Testing Plan

1. Test with real relay file (4x50MI)
2. Verify swimmer names display correctly
3. Verify timings show properly
4. Verify merged table displays all info
5. Verify match status shows correctly

---

## Expected Outcome

- ✅ Swimmer names extracted from lap keys
- ✅ MRS timings set from lap deltas
- ✅ Single unified table for relay swimmers + laps
- ✅ Status column shows match IDs or "NEW"
- ✅ "MISSING" only for truly missing swimmers
