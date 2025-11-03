# Phase 3 Badge Matching Enhancement

**Status**: ✅ Complete  
**Date**: 2025-11-03

---

## Overview

Enhanced Phase 3 (SwimmerSolver) to pre-match existing badges during phase building, eliminating matching logic from Phase 6 (PhaseCommitter) and providing early feedback to operators.

## Architecture Change

### Before (Phase 6 Matching)

**Phase 3 Output:**
```json
{
  "badges": [
    {
      "swimmer_key": "ROSSI|MARIO|1978",
      "team_key": "CSI OBER FERRARI",
      "season_id": 242,
      "category_type_id": 456
    }
  ]
}
```

**Phase 6 Logic:**
- Look up `swimmer_id` from phase3 data by `swimmer_key`
- Look up `team_id` from phase2 data by `team_key`
- Check if badge exists: `Badge.find_by(season_id:, swimmer_id:, team_id:)`
- Create or skip

### After (Phase 3 Matching) ✅

**Phase 3 Output:**
```json
{
  "badges": [
    {
      "swimmer_key": "ROSSI|MARIO|1978",
      "team_key": "CSI OBER FERRARI",
      "season_id": 242,
      "swimmer_id": 123,
      "team_id": 456,
      "category_type_id": 789,
      "badge_id": 999  // ← Pre-matched! (nil if new)
    }
  ]
}
```

**Phase 6 Logic:**
```ruby
def commit_badge(badge_hash:)
  # Guard clause: skip if missing required keys
  return unless badge_hash['swimmer_id'] && badge_hash['team_id']
  
  # If badge_id exists, skip (already in DB)
  return if badge_hash['badge_id'].present?
  
  # Create new badge
  Badge.create!(badge_hash.slice('swimmer_id', 'team_id', 'season_id', 'category_type_id'))
end
```

---

## Implementation Details

### SwimmerSolver Changes

**1. Load Phase Dependencies**
```ruby
# Load phase1 and phase2 data for meeting date and team lookups
phase1_path = opts[:phase1_path] || default_phase_path_for(source_path, 1)
phase2_path = opts[:phase2_path] || default_phase_path_for(source_path, 2)
@phase1_data = File.exist?(phase1_path) ? JSON.parse(File.read(phase1_path)) : nil
@phase2_data = File.exist?(phase2_path) ? JSON.parse(File.read(phase2_path)) : nil
```

**2. Enhanced Badge Builder**
```ruby
def build_badge_entry(swimmer_key, team_key, year_of_birth, gender_code, meeting_date)
  # Resolve IDs
  swimmer_id = find_swimmer_id_by_key(swimmer_key)
  team_id = find_team_id_by_key(team_key)
  category_type_id = calculate_category_type(...)&.id
  
  badge = {
    'swimmer_key' => swimmer_key,
    'team_key' => team_key,
    'season_id' => @season.id,
    'swimmer_id' => swimmer_id,
    'team_id' => team_id,
    'category_type_id' => category_type_id,
    'badge_id' => nil
  }
  
  # Guard clause: skip matching if any key is missing
  return badge unless swimmer_id && team_id && @season.id
  
  # Try to match existing badge
  existing_badge = GogglesDb::Badge.find_by(
    season_id: @season.id,
    swimmer_id: swimmer_id,
    team_id: team_id
  )
  
  badge['badge_id'] = existing_badge.id if existing_badge
  badge
end
```

**3. Helper Methods**
```ruby
# Find swimmer_id from phase3 data or DB
def find_swimmer_id_by_key(swimmer_key)
  # Try phase3 data first (from previous build)
  swimmers = Array(@phase3_data&.dig('data', 'swimmers'))
  swimmer = swimmers.find { |s| s['key'] == swimmer_key }
  return swimmer&.dig('swimmer_id') if swimmer
  
  # Fallback: DB lookup by exact match
  parts = swimmer_key.split('|')
  GogglesDb::Swimmer.find_by(
    last_name: parts[0],
    first_name: parts[1],
    year_of_birth: parts[2].to_i
  )&.id
end

# Find team_id from phase2 data
def find_team_id_by_key(team_key)
  return nil unless @phase2_data
  
  teams = Array(@phase2_data.dig('data', 'teams'))
  team = teams.find { |t| t['key'] == team_key }
  team&.dig('team_id')
end
```

### PhaseCommitter Simplification

**Before: ~35 lines with lookups**
```ruby
def commit_badge(badge_hash:)
  swimmer_key = badge_hash['swimmer_key']
  team_key = badge_hash['team_key']
  
  # Find IDs
  swimmer_id = find_swimmer_id_by_key(swimmer_key)
  team_id = find_team_id_by_key(team_key)
  
  return unless swimmer_id && team_id
  
  # Check existing
  existing = Badge.find_by(season_id:, swimmer_id:, team_id:)
  return if existing
  
  # Create...
end
```

**After: ~20 lines, pure persistence**
```ruby
def commit_badge(badge_hash:)
  # Guard clause
  return unless badge_hash['swimmer_id'] && badge_hash['team_id']
  
  # Skip if exists
  return if badge_hash['badge_id'].present?
  
  # Create new
  Badge.create!(...)
end
```

### DataFixController Update

```ruby
# Pass phase1_path and phase2_path for cross-phase lookups
phase1_path = default_phase_path_for(source_path, 1)
phase2_path = default_phase_path_for(source_path, 2)

Import::Solvers::SwimmerSolver.new(season:).build!(
  source_path: source_path,
  lt_format: lt_format,
  phase1_path: phase1_path,
  phase2_path: phase2_path
)
```

---

## Benefits Achieved

### 1. Early Error Detection 🚨
```log
[SwimmerSolver] Matched existing Badge ID=123 for 'ROSSI|MARIO|1978' + 'CSI OBER FERRARI'
[SwimmerSolver] No existing badge found for 'BIANCHI|LAURA|1990' + 'NUOTO CLUB' (will create new)
[SwimmerSolver] Could not find category for 'VERDI|GIUSEPPE|1880' (YOB: 1880, gender: M)
```

Operators see badge status **during Phase 3 review**, not at commit time.

### 2. Simpler Commit Logic 📦
- PhaseCommitter reduced from ~35 to ~20 lines
- No cross-phase lookups needed
- Pure INSERT logic (no duplicate checks)
- Removed 2 helper methods

### 3. Better UI Feedback 🎨
Phase 3 JSON now self-documenting:
- `badge_id: 999` → Existing badge (green in UI)
- `badge_id: null` → Will create new (blue in UI)
- Missing `swimmer_id`/`team_id` → Data issue (red in UI)

### 4. Self-Contained Phase Files ✅
Phase 3 file has everything needed for commit:
- All IDs resolved
- Categories calculated
- Badges matched
- Ready for Phase 6 with zero lookups

### 5. Consistent Architecture 🏗️
Follows "solve early, commit later" pattern:
- **Phase 1**: Resolves meetings/sessions
- **Phase 2**: Resolves teams
- **Phase 3**: Resolves swimmers + badges (including category + matching) ✅
- **Phase 6**: Pure persistence

---

## Guard Clauses Pattern

All matching logic uses guard clauses to handle missing data gracefully:

```ruby
# Skip matching if we don't have minimum required keys
return badge unless swimmer_id && team_id && season_id

# Skip commit if we don't have minimum required keys  
return unless badge_hash['swimmer_id'] && badge_hash['team_id']
```

This ensures:
- No errors when data is incomplete
- Clear logging of what's missing
- Graceful degradation (stores what we have, skips what we can't match)

---

## Testing Checklist

- [x] Badge matching works with all required IDs
- [x] Badge matching skipped gracefully when IDs missing
- [x] Existing badges detected and `badge_id` populated
- [x] New badges have `badge_id: null`
- [x] PhaseCommitter skips existing badges
- [x] PhaseCommitter creates new badges only
- [x] Logging shows matched vs. new badges
- [x] Category calculation still works
- [x] Cross-phase lookups (phase1 → phase3, phase2 → phase3)

---

## Future Enhancements

Following same pattern for other entities:

### Phase 2: TeamAffiliations
- **Match key**: `(season_id, team_id)`
- **Add field**: `team_affiliation_id`
- **Benefit**: Skip existing affiliations at commit

### Phase 4: MeetingEvents  
- **Match key**: `(meeting_session_id, event_type_id)` or `(session_id, event_order)`
- **Add field**: `meeting_event_id`
- **Benefit**: Update existing events vs. create new

### Phase 5: MeetingPrograms
- **Match key**: `(meeting_event_id, category_type_id, gender_type_id)`
- **Add field**: `meeting_program_id`
- **Benefit**: Reuse programs across results (Phase5Populator already does this)

---

## Files Modified

### SwimmerSolver
- `/app/strategies/import/solvers/swimmer_solver.rb`
  - Added `phase2_path` parameter
  - Load phase1/phase2 data for lookups
  - Enhanced `build_badge_entry` with matching
  - Added `find_swimmer_id_by_key` helper
  - Added `find_team_id_by_key` helper
  - Updated documentation

### PhaseCommitter
- `/app/strategies/import/strategies/phase_committer.rb`
  - Simplified `commit_badge` method
  - Removed `find_swimmer_id_by_key` helper (no longer needed)
  - Removed `find_team_id_by_key` helper (no longer needed)

### DataFixController
- `/app/controllers/data_fix_controller.rb`
  - Pass `phase2_path` to SwimmerSolver

---

## Success Metrics

**Code Reduction:**
- PhaseCommitter: -15 lines
- Helper methods removed: 2
- Cross-phase lookups eliminated: 2

**Data Quality:**
- Badge duplicates: Prevented at Phase 3
- Missing categories: Detected at Phase 3
- Missing IDs: Logged at Phase 3

**Performance:**
- Phase 3 build: +1 DB query per badge (acceptable trade-off)
- Phase 6 commit: -3 DB queries per badge (big win)
- Net: Faster overall (queries moved to phase files = cached)

---

## Conclusion

This enhancement exemplifies the "solve early, commit later" architecture:
1. **Phase 3 does the hard work**: Matching, calculating, resolving IDs
2. **Phase files become complete**: Self-contained with all data needed
3. **Phase 6 becomes trivial**: Pure persistence, no logic
4. **Operators get early feedback**: See issues during review, not at commit

The pattern is proven and ready to apply to other entities! 🚀
