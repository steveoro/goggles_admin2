# Phase 5 Relay Support - Daily Progress Tracker

**Started**: 2025-11-10  
**Target Completion**: TBD  
**Detailed Plan**: See [`PHASE5_LT2_LT4_SUPPORT_PLAN.md`](./PHASE5_LT2_LT4_SUPPORT_PLAN.md)

---

## Quick Status

**Current Blocker**: Phase5Populator only handles LT4 format, test relay file is LT2!

**Work Stream**: Add LT2+LT4 format support to Phase5Populator

**Estimated Total**: 10-14 hours across ~3-4 days

---

## Day 1: Quick Wins & Setup (2-3 hours)

### Session 1: Remove Legacy Buttons (30 min) ✅ COMPLETE
- [x] Remove "Use Legacy" button from `review_sessions_v2.html.haml`
- [x] Remove "Use Legacy" button from `review_teams.html.haml`
- [x] Remove "Use Legacy" button from `review_swimmers_v2.html.haml`
- [x] Remove "Use Legacy" button from `review_events_v2.html.haml`
- [x] Remove "Use Legacy" button from `review_results_v2.html.haml`
- [x] Also removed "use the legacy view" text from alert message
- [ ] Test each phase review page loads without errors
- [ ] Commit: "Remove misleading 'Use Legacy' buttons from all phase views"

**Verification**:
```bash
grep -r "Use Legacy" app/views/data_fix/
# Should return no results
```

### Session 2: Add Format Detection (1 hour) ✅ COMPLETE
- [x] Add `source_format` method to Phase5Populator
- [x] Add `detect_source_format` helper (checks for LT2 vs LT4 keys)
- [x] Update `populate!` method to route by format
- [x] Rename `populate_individual_results!` → `populate_lt4_individual_results!`
- [x] Add `populate_lt4_results!` wrapper method
- [x] Add LT2 stub methods (`populate_lt2_results!`, `populate_lt2_individual_results!`, `populate_lt2_relay_results!`)
- [x] Update stats hash to include relay counters
- [x] Update class documentation
- [x] Add logging for detected format
- [ ] Test with Rails console (see test_format_detection_console.txt)
- [ ] Test with existing LT4 file (regression test)
- [ ] Commit: "Add LT2/LT4 format detection to Phase5Populator"

**Test command**:
```ruby
# Rails console
source_path = 'path/to/lt4-file.json'
populator = Import::Phase5Populator.new(...)
# Should see log: "Detected source format: lt4"
```

### Session 3: Stub LT2 Methods (30 min) ✅ COMPLETE
- [x] Add empty `populate_lt2_results!` method
- [x] Add empty `populate_lt2_individual_results!` method  
- [x] Add empty `populate_lt2_relay_results!` method
- [x] Already done in Session 2!

### Session 4: Fix layoutType Propagation (1 hour) ✅ COMPLETE
**Issue Found**: Phase files don't properly track source layoutType
- [x] Rename `lt_format` → `layoutType` in EventSolver (Phase 4)
- [x] Rename `lt_format` → `layoutType` in ResultSolver (Phase 5)
- [x] Add `layoutType` to Phase1Solver _meta
- [x] Add `layoutType` to TeamSolver (Phase 2) _meta
- [x] Add `layoutType` to SwimmerSolver (Phase 3) _meta
- [x] Update test scripts to use proper LT2/LT4 files
- [x] Fixed test_format_detection_console.txt with correct files

### Session 5: Fix Format Detection Logic (30 min) ✅ CRITICAL FIX!
**Issue Found**: Format detection used wrong discriminant!
- [x] **Root Cause**: Checking for structural keys (`meeting_relay_result`, `events`) is unreliable
- [x] **Problem**: LT4 relay file from Microplus was misdetected as LT2
- [x] **Solution**: Use `layoutType` field directly (the canonical discriminant)
- [x] Fixed `detect_source_format` in Phase5Populator to read `layoutType` field
- [x] Updated both test scripts to verify layoutType detection
- [x] Added structural keys display as "reference only" (not used for detection)
- [x] Updated class documentation

**Key Learning**: The `layoutType` field is the **only reliable** format discriminant, not structural keys!

### Session 6: Add RSpec Tests (30 min) ✅ COMPLETE
**Test Coverage**: Added automated specs for format detection
- [x] Created `spec/requests/data_fix_controller_helpers_spec.rb`
  - Tests `DataFixController#detect_layout_type` with LT2/LT4 fixtures
  - Tests error handling (missing field, corrupt JSON)
  - 8 examples, all passing ✅
- [x] Added `#detect_source_format` tests to `spec/strategies/import/phase5_populator_spec.rb`
  - Tests with Molinella (LT2), Saronno (LT2), and sample-200RA (LT4) fixtures
  - Tests error handling (missing layoutType, unknown values)
  - 8 examples, all passing ✅
- [x] Deleted manual test scripts (replaced with proper RSpec)

**Total Test Coverage**: 16 new specs, 100% passing

**End of Day 1**: Format detection working & FULLY TESTED! 🎉

---

## Day 2: LT2 Individual Results (3-4 hours)

### Session 1: LT2 Individual Results Core (2 hours)
- [ ] Implement `populate_lt2_individual_results!` method
- [ ] Read `source_data['meeting_individual_result']` array
- [ ] Generate `import_key` for each MIR
- [ ] Match swimmer/team IDs from phase files
- [ ] Create `DataImportMeetingIndividualResult` records
- [ ] Add error handling and logging
- [ ] Test with LT2 individual file
- [ ] Commit: "Implement LT2 individual result population"

### Session 2: LT2 Lap Handling (1-2 hours)
- [ ] Implement `create_lap_records_lt2` method
- [ ] Read `source_data['lap']` array
- [ ] Filter laps by parent `meeting_individual_result_id`
- [ ] Create `DataImportLap` records with timing
- [ ] Handle `from_start` timing fields
- [ ] Test lap creation
- [ ] Commit: "Add LT2 lap record creation"

**Verification**:
```ruby
# Test with LT2 individual file
stats = populator.populate!
puts "MIRs: #{stats[:mir_created]}"
puts "Laps: #{stats[:laps_created]}"

GogglesDb::DataImportMeetingIndividualResult.count  # > 0
GogglesDb::DataImportLap.count                      # > 0
```

**End of Day 2**: LT2 individual results working, ready for relay support

---

## Day 3: LT2 Relay Results (3-4 hours)

### Session 1: LT2 Relay Results Core (2 hours)
- [ ] Implement `populate_lt2_relay_results!` method
- [ ] Read `source_data['meeting_relay_result']` array
- [ ] Generate relay `import_key` format
- [ ] Match team/program IDs from phase files
- [ ] Create `DataImportMeetingRelayResult` records
- [ ] Update stats tracking (add relay counters)
- [ ] Commit: "Implement LT2 relay result population"

### Session 2: LT2 Relay Swimmers & Laps (1-2 hours)
- [ ] Implement `create_relay_swimmers_lt2` method
- [ ] Read `source_data['meeting_relay_swimmer']` array
- [ ] Filter by parent `meeting_relay_result_id`
- [ ] Create `DataImportRelaySwimmer` records (4 per result)
- [ ] Implement `create_relay_laps_lt2` method
- [ ] Read `source_data['relay_lap']` array
- [ ] Create `DataImportRelayLap` records
- [ ] Commit: "Add LT2 relay swimmer and lap population"

**Verification**:
```ruby
# Test with LT2 relay file (the 4X50MI file!)
stats = populator.populate!
puts "Relay results: #{stats[:relay_results_created]}"    # 787 expected
puts "Relay swimmers: #{stats[:relay_swimmers_created]}"  # ~3148 (4x787)
puts "Relay laps: #{stats[:relay_laps_created]}"

GogglesDb::DataImportMeetingRelayResult.count  # 787
GogglesDb::DataImportRelaySwimmer.count        # ~3148
```

**End of Day 3**: LT2 relay support complete! Ready for LT4 relay

---

## Day 4: LT4 Relay Results (3-4 hours)

### Session 1: LT4 Relay Event Handling (2 hours)
- [ ] Update `populate_lt4_results!` to route relays
- [ ] Replace relay skip with `populate_lt4_relay_event(event)` call
- [ ] Implement `populate_lt4_relay_event` method
- [ ] Parse LT4 relay result structure from events array
- [ ] Create `DataImportMeetingRelayResult` records
- [ ] Add stroke type determination logic
- [ ] Commit: "Implement LT4 relay result population"

### Session 2: LT4 Relay Legs & Laps (1-2 hours)
- [ ] Implement `create_relay_swimmers_lt4` method
- [ ] Parse relay swimmer data from result['relay_swimmers']
- [ ] Compute cumulative `from_start` timing per leg
- [ ] Implement `determine_stroke_type_id` helper (MI mapping)
- [ ] Create `DataImportRelaySwimmer` records
- [ ] Implement `create_relay_laps_lt4` method
- [ ] Create `DataImportRelayLap` records if lap data present
- [ ] Commit: "Add LT4 relay swimmer and lap population"

**Verification**:
```ruby
# Test with LT4 relay file (if available)
# Or wait for UI to verify with actual data
```

**End of Day 4**: Both LT2 and LT4 relay support complete!

---

## Day 5: Testing & Documentation (2 hours)

### Session 1: Integration Testing (1 hour)
- [ ] Test LT2 individual file end-to-end
- [ ] Test LT2 relay file end-to-end (the 4X50MI file!)
- [ ] Test LT4 individual file (regression test)
- [ ] Test LT4 relay file (if available)
- [ ] Verify all stats counters working
- [ ] Check for any error messages in logs

### Session 2: Specs & Documentation (1 hour)
- [ ] Write spec: `phase5_populator_lt2_spec.rb`
- [ ] Write spec: `phase5_populator_lt4_relay_spec.rb`
- [ ] Update `PHASES.md` with LT2+LT4 support notes
- [ ] Update `RELAY_IMPLEMENTATION.md` populator status to ✅
- [ ] Update `CHANGELOG.md` with new entry
- [ ] Commit: "Add specs and documentation for LT2+LT4 relay support"

**End of Day 5**: Phase5Populator complete with full relay support!

---

## Next Phase: Relay UI Display

**After Phase5Populator complete**:
1. Create relay result card partials (similar to individual cards)
2. Add controller queries for relay data
3. Display relay results in review UI
4. Test with populated relay data

**See**: `PHASE6_RELAY_COMPLETION_ROADMAP.md` for Phase 6 commit logic

---

## Notes & Blockers

**Date** | **Note**
---------|----------
2025-11-10 | Started plan creation. Identified LT2/LT4 format issue.
         | Created detailed 8-step implementation plan.
         | Ready to begin with "Remove Legacy Buttons" quick win.

---

## Quick Reference

**Key Files**:
- Implementation: `app/strategies/import/phase5_populator.rb`
- Controller: `app/controllers/data_fix_controller.rb`
- Test file: `crawler/data/results.new/242/2025-06-24-...-4X50MI-l4.json`

**Helper Commands**:
```bash
# Check for legacy button references
grep -r "Use Legacy" app/views/data_fix/

# Rails console test
rails c
source_path = 'crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json'
populator = Import::Phase5Populator.new(
  source_path: source_path,
  phase1_path: source_path.gsub('.json', '-phase1.json'),
  phase2_path: source_path.gsub('.json', '-phase2.json'),
  phase3_path: source_path.gsub('.json', '-phase3.json'),
  phase4_path: source_path.gsub('.json', '-phase4.json')
)
stats = populator.populate!

# Check database
GogglesDb::DataImportMeetingRelayResult.count
GogglesDb::DataImportRelaySwimmer.count
GogglesDb::DataImportRelayLap.count
```

**Status Legend**:
- ✅ Complete
- 🎯 In Progress  
- ❌ Not Started
- ⚠️ Blocked
