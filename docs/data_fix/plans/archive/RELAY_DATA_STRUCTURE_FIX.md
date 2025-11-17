# Relay Data Structure Fix Plan

**Date**: 2025-11-13  
**Issue**: Phase 5 relay population expects wrong lap data structure

---

## Problem Summary

Our Phase 5 relay implementation was built with an **incorrect assumption** about the lap data structure in LT4 format. We assumed laps would have cumulative `timing`, but real data only has split `delta`.

### What We Expected (WRONG):
```json
"laps": [
  {
    "distance": "50m",
    "timing": "25.00",        ← cumulative (WRONG!)
    "delta": "25.00",         ← split
    "swimmer": "M|ROSSI|Mario|1978|Team"
  },
  {
    "distance": "100m",
    "timing": "50.20",        ← cumulative (WRONG!)
    "delta": "25.20",         ← split
    "swimmer": "F|BIANCHI|Anna|1980|Team"
  }
]
```

### What Real Data Has (CORRECT):
```json
"laps": [
  {
    "distance": "50m",
    "delta": "1'46.01",       ← split time ONLY
    "swimmer": "CORTI|Delia|1938|DLF Nuoto Livorno"
  },
  {
    "distance": "100m",
    "delta": "1'02.46",       ← split time ONLY
    "swimmer": "F|PAGLI|Linda|1950|DLF Nuoto Livorno"
  }
]
```

**Key difference**: Real relay laps have **only `delta` (split time)**, NOT cumulative `timing`.

---

## Root Cause

**File**: `app/strategies/import/phase5_populator.rb`  
**Method**: `create_relay_laps`  
**Line 658-659**:

```ruby
# Parse lap timing from source (this is "from_start" timing)
from_start = parse_timing_string(lap['timing'])  # ← WRONG! lap['timing'] is nil
```

This causes:
1. `lap['timing']` returns `nil` (doesn't exist in real data)
2. `parse_timing_string(nil)` returns `{minutes: 0, seconds: 0, hundredths: 0}`
3. All lap times show as `0'00.00` in UI (see screenshot)
4. `from_start` timing is never computed correctly
5. Speed calculations show `0.0 m/s`

---

## Additional Findings

### 1. LT2 Relay Row Structure

Real LT2 relay rows have:
- **Swimmer fields**: `swimmer1`, `year_of_birth1`, `gender_type1`, ... up to `swimmer8`
- **Lap array**: with `distance`, `delta`, `swimmer` (swimmer key)
- **NO cumulative timing** in laps

### 2. Legacy Data-Fix Already Processed Some Files

The two large relay files in `crawler/data/results.new/242/` have been partially processed by the old data-fix:
- They contain additional entity arrays (`swimmer`, `badge`, `relay_lap`, etc.)
- These use Import::Entity serialization format (row/matches/bindings)
- Can be safely **ignored** during Phase 5 processing
- We only need the `sections` array (LT2 structure)

### 3. Swimmer Enrichment Logic Needs Update

From the notes:
- Missing `swimmer_id` is **normal** for new swimmers (non-blocking)
- Missing `gender_type` or `year_of_birth` **blocks commit** (critical)
- Swimmers with matched IDs should be **removed from enrichment list**
- Badge styling updated to reflect this (primary for missing ID, danger for missing data)

### 4. Modal Progress Not Appearing

Action cable broadcast not being called during Phase 5 populate action.

---

## Fix Strategy

### Phase 1: Fix Relay Lap Logic (CRITICAL - Required for UI to work)

**Change**: Compute cumulative timing from deltas

```ruby
# CURRENT (BROKEN):
from_start = parse_timing_string(lap['timing'])  # nil → 0'00.00
delta = compute_timing_delta(from_start, previous_from_start)

# FIXED:
delta = parse_timing_string(lap['delta'])  # Parse split time
from_start = compute_timing_sum(previous_from_start, delta)  # Compute cumulative
```

**New helper method needed**: `compute_timing_sum`

### Phase 2: Update Test Fixtures

Fix `spec/fixtures/import/sample-relay-4x50sl-l4.json`:
- Remove `timing` field from laps
- Keep only `delta` and `swimmer`
- Tests should still pass after Phase 1 fix

### Phase 3: Document Real Data Structure

Create `docs/crawler/RELAY_DATA_STRUCTURE.md`:
- Document LT2 relay row structure
- Document LT4 normalized structure
- Show real examples from actual files
- Clarify difference vs individual results

### Phase 4: Fix Swimmer Enrichment (Lower Priority)

Update relay enrichment panel logic:
- Filter out swimmers with complete data from enrichment list
- Only show swimmers missing critical fields (gender, year)
- Update consuming logic during merge

### Phase 5: Add Progress Modal (Lower Priority)

Add action cable broadcast during Phase 5 populate.

---

## Implementation Plan

### Step 1: Add `compute_timing_sum` Helper

```ruby
# In Phase5Populator
def compute_timing_sum(timing1, timing2)
  total_hundredths = timing1[:hundredths] + timing2[:hundredths]
  total_seconds = timing1[:seconds] + timing2[:seconds]
  total_minutes = timing1[:minutes] + timing2[:minutes]

  # Handle overflow
  if total_hundredths >= 100
    total_seconds += total_hundredths / 100
    total_hundredths = total_hundredths % 100
  end

  if total_seconds >= 60
    total_minutes += total_seconds / 60
    total_seconds = total_seconds % 60
  end

  { minutes: total_minutes, seconds: total_seconds, hundredths: total_hundredths }
end
```

### Step 2: Fix `create_relay_laps` Method

```ruby
def create_relay_laps(_mrr, result, mrr_import_key)
  laps = result['laps'] || []
  previous_from_start = { minutes: 0, seconds: 0, hundredths: 0 }

  laps.each do |lap|
    distance_str = lap['distance'] || lap['length_in_meters'] || lap['lengthInMeters']
    length = distance_str.to_s.gsub(/\D/, '').to_i
    next if length.zero?

    # FIXED: Parse delta (split time) from source
    delta = parse_timing_string(lap['delta'])
    
    # FIXED: Compute cumulative timing by adding delta to previous
    from_start = compute_timing_sum(previous_from_start, delta)

    lap_import_key = "#{mrr_import_key}-lap#{length}"

    GogglesDb::DataImportRelayLap.create!(
      import_key: lap_import_key,
      parent_import_key: mrr_import_key,
      length_in_meters: length,
      minutes: delta[:minutes],
      seconds: delta[:seconds],
      hundredths: delta[:hundredths],
      minutes_from_start: from_start[:minutes],
      seconds_from_start: from_start[:seconds],
      hundredths_from_start: from_start[:hundredths]
    )

    @stats[:relay_laps_created] += 1
    previous_from_start = from_start  # Update for next lap
  rescue ActiveRecord::RecordInvalid => e
    @stats[:errors] << "RelayLap error for #{lap_import_key}: #{e.message}"
  end
end
```

### Step 3: Update Test Fixture

Remove `timing` from laps in `spec/fixtures/import/sample-relay-4x50sl-l4.json`:

```json
"laps": [
  {
    "distance": "50m",
    "delta": "25.00",
    "swimmer": "M|ROSSI|Mario|1978|Sample Team A"
  },
  {
    "distance": "100m",
    "delta": "25.20",
    "swimmer": "F|BIANCHI|Anna|1980|Sample Team A"
  }
]
```

### Step 4: Update Tests

Verify all 16 relay tests still pass after changes.

### Step 5: Test with Real Data

Test with actual relay file:
```bash
crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json
```

Expected results:
- ✅ Lap split times display correctly
- ✅ Cumulative times calculated correctly
- ✅ Speed calculations show realistic values (1.5-2.5 m/s typical)
- ✅ Final cumulative time matches relay result timing

---

## Testing Checklist

### Unit Tests
- [ ] Add test for `compute_timing_sum` helper
- [ ] Verify existing 16 relay tests still pass
- [ ] Add test for laps with only delta (no timing)

### Integration Tests
- [ ] Load real relay file through Phase 1-4
- [ ] Populate Phase 5 with real data
- [ ] Verify lap times in UI
- [ ] Check speed calculations
- [ ] Verify cumulative times match result timing

### Edge Cases
- [ ] Very long split times (> 1 minute)
- [ ] Relay with missing lap data
- [ ] Relay with incomplete swimmer info

---

## Files to Modify

1. **app/strategies/import/phase5_populator.rb** (~15 lines)
   - Add `compute_timing_sum` method
   - Fix `create_relay_laps` to use delta instead of timing

2. **spec/fixtures/import/sample-relay-4x50sl-l4.json** (~12 lines)
   - Remove `timing` field from all laps
   - Keep only `delta` and `swimmer`

3. **spec/strategies/import/phase5_populator_spec.rb** (~20 lines)
   - Add test for `compute_timing_sum`
   - Add test for delta-only laps

4. **docs/crawler/RELAY_DATA_STRUCTURE.md** (NEW)
   - Document relay data format
   - Show examples from real files

---

## Expected Outcome

After fixes:
- ✅ Relay lap times display correctly in UI
- ✅ Cumulative times calculated properly
- ✅ Speed calculations show realistic values
- ✅ All tests passing
- ✅ Works with both test fixtures and real data files

---

## Priority

**CRITICAL**: This breaks relay display entirely (all times show as 0'00.00)

**Estimated Time**: 1-2 hours for complete fix + testing

---

## Next Actions

1. Implement `compute_timing_sum` helper
2. Fix `create_relay_laps` logic
3. Update test fixture
4. Run tests
5. Test with real data file
6. Document relay data structure
