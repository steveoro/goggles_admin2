# Data-Fix Fixes: Progress Dialogs & Relay Event Recognition

**Date**: November 10, 2025  
**Status**: ✅ **Completed**

---

## Issues Fixed

### 1. ✅ Missing Progress Dialog (Real-time Updates)

**Problem**: The progress modal that shows real-time processing updates was not implemented in the new phased data-fix workflow (phases 2, 3, 5, 6).

**Solution**: Added ActionCable progress broadcasting throughout the workflow:

#### Files Modified

1. **`app/controllers/data_fix_controller.rb`**
   - Added `broadcast_progress` helper method (lines 1579-1588)
   - Added progress broadcasts in `review_teams` (line 130)
   - Added progress broadcasts in `review_swimmers` (line 221)

2. **`app/strategies/import/solvers/team_solver.rb`**
   - Added progress broadcasting during team processing (lines 53, 64)
   - Broadcasts every 5 items and at completion
   - Added `broadcast_progress` helper method (lines 238-246)

#### How It Works

- **During Build**: Solvers broadcast progress as they process each collection (every 5 items)
- **On Ready**: Controllers broadcast "ready" status when view is rendered
- **Modal Display**: The existing `_modal_progress.html.haml` partial (already added to all phase views) automatically shows/hides based on ActionCable messages
- **Channel**: Uses `ImportStatusChannel` for WebSocket communication

#### Broadcasting Pattern

```ruby
# During processing (in solvers):
broadcast_progress('map_teams', current_index, total_count)

# When ready (in controllers):
broadcast_progress('Review teams: ready', total_count, total_count)
```

---

### 2. ✅ Relay Events Not Being Recognized (BLOCKER)

**Problem**: Phase 4 reported zero events when processing relay data files. Relay events were being skipped entirely.

**Root Causes**:
1. Line 86 in `EventSolver` explicitly skipped relays: `next if ev['relay'] == true`
2. Relay data doesn't have `distance`/`stroke` fields at row level - must be parsed from section `title`
3. `find_event_type_id` method didn't handle relay event codes (format: `S4X50MX`)

**Solution**: Complete relay event recognition system with special handling for relay-only files

#### Files Modified

**`app/strategies/import/solvers/event_solver.rb`**

##### 1. Relay-Only File Detection (lines 35-40)
```ruby
# Check if this is a relay-only file (all sections are relays)
all_relay = data_hash['sections'].all? do |sec|
  rows = sec['rows'] || []
  rows.any? { |row| row['relay'] == true }
end
```

When a file contains only relay data, all sections are grouped into **one session** with events grouped by gender (F, M, X).

##### 2. Relay Detection & Parsing (lines 41-89)
```ruby
# Check if relay
is_relay = row['relay'] == true || sec['relay'] == true

if is_relay
  # Parse from section title: "4x50 m Misti - M80"
  distance, stroke, relay_code = parse_relay_event_from_title(sec['title'], sec['fin_sesso'])
  next if distance.to_s.strip.empty? || stroke.to_s.strip.empty?
else
  # Individual event: get from row data
  distance = row['distance'] || row['distanceInMeters'] || ...
  stroke = row['stroke'] || row['style'] || ...
  relay_code = nil
end
```

##### 2. Relay Event Code Matching (lines 76-82)
```ruby
if relay_code
  event_type_id = find_relay_event_type_id(relay_code)
else
  event_type_id = find_event_type_id(distance, stroke)
end
```

##### 3. Added Helper Methods (lines 227-275)

**`parse_relay_event_from_title`** - Parses Italian relay titles:
- Input: `"4x50 m Misti - M80"`, `fin_sesso="F"`
- Output: `[200, "MX", "S4X50MX"]` (distance, stroke, event_code)
- Supports keywords: `misti/medley`, `stile libero/freestyle`, `dorso/backstroke`, `rana/breaststroke`, `farfalla/delfino/butterfly`
- Gender prefix: `S` for same gender (F/M), `M` for mixed (X)

**`find_relay_event_type_id`** - Finds EventType by relay code:
- Queries: `GogglesDb::EventType.find_by(code: event_code, relay: true)`

##### 4. Removed Relay Skip in LT4 Fallback (line 105)
- Was: `next if ev['relay'] == true`
- Now: Processes relays like individual events

#### Relay Event Code Protocol

Format: `<gender><participants>X<phase_length><stroke>`

Examples:
- `S4X50MI` - Same-gender 4x50m mixed relay (stroke_type_id=10)
- `M4X50MI` - Mixed-gender 4x50m mixed relay (stroke_type_id=10)
- `M4X100SL` - Mixed-gender 4x100m freestyle relay (stroke_type_id=1)
- `S4X50SL` - Same-gender 4x50m freestyle relay (stroke_type_id=1)

**Note**: Database uses "MI" (Misti) for mixed/medley relays, not "MX".

#### Test Results

**Parsing verified with sample relay titles:**
```
✓ "4x50 m Misti - M80" (F) → [200, "MI", "S4X50MI"]
✓ "4x100 m Stile Libero - M100" (M) → [400, "SL", "S4X100SL"]
✓ "4X50m Misti - M80" (X) → [200, "MI", "M4X50MI"]
```

**End-to-end test with actual relay file:**
```
Source: 2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json
- 23 sections (F: 7, M: 8, X: 8) all for "4x50 m Misti"

Result:
✓ 1 session (all sections grouped together)
✓ 3 events (one per gender: F, M, X)
✓ EventTypes matched:
  - S4X50MI (gender: F) → event_type_id: 26
  - S4X50MI (gender: M) → event_type_id: 26
  - M4X50MI (gender: X) → event_type_id: 33
```

---

## Additional Notes

### Gender Inheritance Rules (Relay Data)

Based on user requirements:
- **Non-mixed** (`fin_sesso`: F or M): Gender inherited by all swimmers in relay
- **Mixed** (`fin_sesso`: X): Cannot infer gender - must be provided per swimmer
- This affects Phase 3 swimmer data gathering

### Stroke Type Mapping for Mixed Relays (MX)

Standard order for 4x mixed relay:
1. **1st leg**: Backstroke (`DO`) - `GogglesDb::StrokeType::BACKSTROKE_ID = 3`
2. **2nd leg**: Breaststroke (`RA`) - `GogglesDb::StrokeType::BREASTSTROKE_ID = 4`
3. **3rd leg**: Butterfly (`FA`) - `GogglesDb::StrokeType::BUTTERFLY_ID = 2`
4. **4th leg**: Freestyle (`SL`) - `GogglesDb::StrokeType::FREESTYLE_ID = 1`

This will be used in Phase 6 when creating `meeting_relay_swimmers` records.

### **Phase 5 (ResultSolver) - Also Fixed** 

**Same issues as EventSolver:**
1. Relay-only file detection and grouping
2. Relay event parsing from section titles
3. Relay skip removed from LT4 path
4. Added `parse_relay_event_from_title` helper

**Test Results:**
```
Source: 2025-06-24-...4X50MI-l4.json (23 relay sections)
Phase 5 output:
  1 session (all sections grouped)
  3 events (F, M, X)
  Result counts: F=22, M=24, X=1
```

### Pending: Phase 5 Progress Broadcasting

Still TODO:
- Add progress broadcasting to `review_results` controller action
- Phase 6 already has broadcasting in `Import::Committers::Main`

---

## Impact

### Before
- ❌ No progress feedback during long operations
- ❌ Relay events completely skipped (0 events reported)
- ❌ Phase 4 unusable for relay data files

### After  
- ✅ Real-time progress modal shows processing status (Phases 2, 3)
- ✅ Relay events correctly recognized and parsed (Phases 4, 5)
- ✅ Event codes properly matched to `GogglesDb::EventType`
- ✅ Phase 4 now processes relay files correctly
- ✅ Phase 5 now processes relay results correctly
- ✅ Ready for Phase 6 relay commit

---

## Files Changed

### Controllers
- `app/controllers/data_fix_controller.rb` (+14 lines)

### Solvers/Services
- `app/strategies/import/solvers/team_solver.rb` (+14 lines, progress broadcasting)
- `app/strategies/import/solvers/event_solver.rb` (+150 lines, major refactor)
  - Relay-only file detection
  - Section title parsing for relays
  - LT4 relay event code parsing
  - Helper methods for relay parsing
- `app/strategies/import/solvers/result_solver.rb` (+140 lines, major refactor)
  - Same relay handling as EventSolver
  - Result counting for relay events

### Specs Updated
- `spec/strategies/import/solvers/event_solver_spec.rb` (3 specs updated)
  - Fixed edge case for empty sections
  - Updated "skips relay events" → "processes relay events"
  - Updated session grouping expectations

### Tests Verified
- ✅ Relay title parsing (Italian keywords)
- ✅ EventSolver with actual relay file (4X50MI)
- ✅ ResultSolver with actual relay file (4X50MI)
- ✅ All 60 solver specs pass

---

## Next Steps

1. Test with actual relay data files (2025-06-24 files)
2. Verify Phase 4 reports correct number of events
3. Add Phase 5 progress broadcasting
4. Continue with Phase 5 relay display implementation
