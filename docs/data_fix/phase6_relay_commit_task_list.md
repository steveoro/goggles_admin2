# Phase 6 Relay Commit - Task List & Status

**Date Created**: 2025-11-08  
**Feature**: Phase 6 SQL generation and database commit for relay results

---

## Overview

Extend `Import::Committers::Main` to commit relay results from Phase 5 temporary tables to production tables. Currently handles individual results (MIR + Lap) but **not** relay results (MRR + RelayLap + MeetingRelaySwimmer).

---

## Current Status

### ✅ Infrastructure Ready
- [x] Production tables: `meeting_relay_results`, `relay_laps`, `meeting_relay_swimmers`
- [x] Temporary tables: `data_import_meeting_relay_results`, etc. (goggles_db v0.8.11+)
- [x] Individual result commit working in `Main#commit_phase5_entities`
- [x] SQL generation via `SqlMaker`, transaction wrapper, change detection

### ❌ Missing Components

#### 1. Relay Commit Logic in Main
**Status**: 🔴 NOT IMPLEMENTED  
**Current**: Only `relays_due` boolean flag exists (line 914), no commit logic

**Required Methods**:
- `commit_relay_results` - Commit MRR records
- `commit_relay_swimmers` - Commit leg swimmers per relay
- `commit_relay_laps` - Commit lap splits per swimmer
- `find_existing_mrr` - Match existing records for UPDATE vs INSERT
- `normalize_relay_result_attributes` - Sanitize/cast attributes
- `normalize_relay_swimmer_attributes`
- `normalize_relay_lap_attributes`

#### 2. Dependency Order
**Required** (within Phase 5):
```
1. MeetingProgram (shared with individual)
2. MeetingIndividualResult + Lap (existing)
3. MeetingRelayResult → MeetingRelaySwimmer → RelayLap (NEW)
```

#### 3. Matching Logic
```ruby
def find_existing_mrr(program_id:, team_id:, relay_code:)
  GogglesDb::MeetingRelayResult.find_by(
    meeting_program_id: program_id,
    team_id: team_id,
    relay_code: relay_code
  )
end
```

---

## Implementation Plan

### Step 1: Add Relay Commit Methods
**Priority**: HIGH | **Time**: 4-6 hours

**Tasks**:
- [ ] Add `commit_relay_results` to Main
- [ ] Query `DataImportMeetingRelayResult.where(season_id:).includes(:meeting_relay_swimmers, :relay_laps)`
- [ ] Validate team_id, meeting_program_id presence
- [ ] Call `find_existing_mrr` for matching
- [ ] Use `normalize_relay_result_attributes`
- [ ] Generate SQL via `SqlMaker`
- [ ] Track stats: `relay_results_created`, `relay_results_updated`

### Step 2: Relay Swimmer Commit
**Priority**: HIGH | **Time**: 3-4 hours

**Tasks**:
- [ ] Add `commit_relay_swimmers(relay_result)`
- [ ] Iterate `meeting_relay_swimmers` per result
- [ ] Validate swimmer_id, set relay_order (1-4)
- [ ] Use `normalize_relay_swimmer_attributes`
- [ ] Store `meeting_relay_swimmer_id` for lap FK

### Step 3: Relay Lap Commit
**Priority**: HIGH | **Time**: 2-3 hours

**Tasks**:
- [ ] Add `commit_relay_laps(relay_swimmer)`
- [ ] Iterate `relay_laps` per swimmer
- [ ] Use `normalize_relay_lap_attributes`
- [ ] Copy timing fields (delta + from_start)

### Step 4: Normalization Helpers
**Priority**: HIGH | **Time**: 2-3 hours

**Tasks**:
- [ ] `normalize_relay_result_attributes` - Cast booleans, trim strings, pick columns
- [ ] `normalize_relay_swimmer_attributes` - Cast timing, relay_order
- [ ] `normalize_relay_lap_attributes` - Cast timing, lap_order
- [ ] Add unit tests for all helpers

### Step 5: Update commit_phase5_entities
**Priority**: HIGH | **Time**: 1-2 hours

**Tasks**:
- [ ] Add `commit_relay_results` after `commit_individual_results`
- [ ] Ensure transaction wraps both
- [ ] Update stats tracking

### Step 6: Testing
**Priority**: HIGH | **Time**: 3-4 hours

**Tasks**:
- [ ] Unit tests for commit methods
- [ ] Integration test: full Phase 6 with relays
- [ ] Verify SQL generation
- [ ] Test UPDATE vs INSERT logic
- [ ] Test transaction rollback
- [ ] Performance test (50+ relays)

### Step 7: Documentation
**Priority**: MEDIUM | **Time**: 1-2 hours

**Tasks**:
- [ ] Update `phase5_and_6_completion_plan.md`
- [ ] Update `HOWTO_phase6_commit.md`
- [ ] Document dependency order

---

## Edge Cases

### 1. Missing Team ID
**Handling**: Skip relay result, log error, continue transaction

### 2. Missing Swimmer ID (Relay Leg)
**Handling**: Allow nil swimmer_id (relay can exist without all swimmers matched), display warning

### 3. Duplicate Relay Result
**Handling**: Use UPDATE logic if matched, avoid duplicate INSERTs

### 4. Orphaned Relay Laps
**Handling**: Cascade delete if parent relay swimmer deleted

---

## Files to Modify

### Modified
- `app/strategies/import/committers/main.rb` - Add relay commit logic
- `spec/strategies/import/committers/main_spec.rb` - Add relay specs
- `docs/data_fix/phase5_and_6_completion_plan.md` - Update status
- `docs/data_fix/HOWTO_phase6_commit.md` - Document relay commit flow

---

## Success Criteria

✅ `commit_relay_results` method implemented  
✅ Relay swimmers and laps committed  
✅ SQL file contains relay INSERT/UPDATE statements  
✅ Foreign key integrity maintained  
✅ All unit and integration tests passing  
✅ Transaction rollback on error  
✅ Documentation updated  

---

## Related Documents

- [Phase 5 Relay Display Task List](./phase5_relay_display_task_list.md)
- [Phase 3 Relay Enrichment Task List](./phase3_relay_enrichment_task_list.md)
- [Phase 5 & 6 Completion Plan](./phase5_and_6_completion_plan.md)
- [HOWTO Phase 6 Commit](./HOWTO_phase6_commit.md)

---

**Last Updated**: 2025-11-08T01:33:00Z
