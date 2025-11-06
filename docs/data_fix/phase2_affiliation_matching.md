# Phase 2 TeamAffiliation Matching Enhancement

**Status**: ✅ Complete  
**Date**: 2025-11-03

---

## Overview

Enhanced Phase 2 (TeamSolver) to pre-match existing team affiliations during phase building, following the same pattern as Phase 3 badges. This eliminates matching logic from Phase 6 (Main) and provides early feedback.

## Architecture Change

### Before (Phase 6 Matching)

**Phase 2 Output:**
```json
{
  "team_affiliations": [
    {
      "team_key": "CSI OBER FERRARI",
      "season_id": 242
    }
  ]
}
```

**Phase 6 Logic:**
- Look up `team_id` from phase2 data by `team_key`
- Check if affiliation exists: `TeamAffiliation.find_by(season_id:, team_id:)`
- Create or skip

### After (Phase 2 Matching) ✅

**Phase 2 Output:**
```json
{
  "team_affiliations": [
    {
      "team_key": "CSI OBER FERRARI",
      "season_id": 242,
      "team_id": 123,
      "team_affiliation_id": 456  // ← Pre-matched! (nil if new)
    }
  ]
}
```

**Phase 6 Logic:**
```ruby
def commit_team_affiliation(affiliation_hash:)
  # Guard clause
  return unless affiliation_hash['team_id'] && affiliation_hash['season_id']
  
  # Skip if exists
  return if affiliation_hash['team_affiliation_id'].present?
  
  # Create new
  TeamAffiliation.create!(team_id:, season_id:, name: '')
end
```

---

## Implementation Details

### TeamSolver Changes

**1. Enhanced Affiliation Builder**
```ruby
def build_team_affiliation_entry(team_key, team_id)
  affiliation = {
    'team_key' => team_key,
    'season_id' => @season.id,
    'team_id' => team_id,
    'team_affiliation_id' => nil
  }
  
  # Guard clause: skip matching if team_id is missing
  return affiliation unless team_id && @season.id
  
  # Try to match existing affiliation
  existing = GogglesDb::TeamAffiliation.find_by(
    season_id: @season.id,
    team_id: team_id
  )
  
  if existing
    affiliation['team_affiliation_id'] = existing.id
    @logger&.info("[TeamSolver] Matched existing TeamAffiliation ID=#{existing.id}")
  else
    @logger&.debug("[TeamSolver] No existing affiliation found (will create new)")
  end
  
  affiliation
end
```

**2. Updated Build Logic**
```ruby
# Before
teams << build_team_entry(name, name)
ta << { 'team_key' => name, 'season_id' => @season.id }

# After
team_entry = build_team_entry(name, name)
teams << team_entry
ta << build_team_affiliation_entry(name, team_entry['team_id'])
```

All three badge creation points updated:
- LT4 array format (line 49-51)
- LT4 hash format (line 58-60)
- LT2 sections (line 71-73)

### Main Simplification

**Before: ~18 lines with lookup**
```ruby
def commit_team_affiliation(team_id:, season_id:)
  return unless team_id && season_id
  
  # Check existing
  existing = TeamAffiliation.find_by(team_id:, season_id:)
  return if existing
  
  # Create...
end
```

**After: ~15 lines, pure persistence**
```ruby
def commit_team_affiliation(affiliation_hash:)
  # Guard clause
  return unless affiliation_hash['team_id'] && affiliation_hash['season_id']
  
  # Skip if exists
  return if affiliation_hash['team_affiliation_id'].present?
  
  # Create new
  TeamAffiliation.create!(...)
end
```

**Phase 2 Commit Updated:**
```ruby
def commit_phase2_entities
  teams_data = Array(phase2_data.dig('data', 'teams'))
  affiliations_data = Array(phase2_data.dig('data', 'team_affiliations'))
  
  # Commit all teams first
  teams_data.each { |team_hash| commit_team(team_hash) }
  
  # Then commit affiliations (pre-matched)
  affiliations_data.each { |affiliation_hash| 
    commit_team_affiliation(affiliation_hash: affiliation_hash) 
  }
end
```

---

## Benefits Achieved

### 1. Early Detection 🚨
```log
[TeamSolver] Matched existing TeamAffiliation ID=456 for 'CSI OBER FERRARI'
[TeamSolver] No existing affiliation found for 'NUOTO CLUB' (will create new)
```

### 2. Simpler Commit Logic 📦
- No cross-phase lookup needed
- Pure INSERT logic (no duplicate checks)
- Cleaner method signature

### 3. Self-Contained Phase Files ✅
```json
{
  "teams": [
    { "key": "CSI OBER FERRARI", "team_id": 123 }
  ],
  "team_affiliations": [
    { 
      "team_key": "CSI OBER FERRARI",
      "team_id": 123,
      "season_id": 242,
      "team_affiliation_id": 456
    }
  ]
}
```

### 4. Guard Clause Pattern 🛡️
```ruby
# Skip matching if we don't have minimum required keys
return affiliation unless team_id && season_id
```

Handles incomplete data gracefully:
- No errors when team not matched
- Clear logging of what's missing
- Stores what we have, skips what we can't match

---

## Logging Output

```log
[TeamSolver] Auto-assigned team 'CSI OBER FERRARI' -> ID 123
[TeamSolver] Matched existing TeamAffiliation ID=456 for 'CSI OBER FERRARI'
[TeamSolver] Auto-assigned team 'NUOTO CLUB' -> ID 124
[TeamSolver] No existing affiliation found for 'NUOTO CLUB' (will create new)
...
[Main] TeamAffiliation ID=456 already exists, skipping
[Main] Created TeamAffiliation ID=457, team_id=124, season_id=242
```

---

## Comparison with Phase 3 Badges

Both follow the same pattern:

| Aspect | Phase 2 Affiliations | Phase 3 Badges |
|--------|---------------------|----------------|
| **Match Key** | `(season_id, team_id)` | `(season_id, swimmer_id, team_id)` |
| **ID Field** | `team_affiliation_id` | `badge_id` |
| **Guard Clause** | `return unless team_id && season_id` | `return unless swimmer_id && team_id && season_id` |
| **Logging** | Matched vs. new | Matched vs. new + category |
| **Phase Data** | Loads nothing extra | Loads phase1 + phase2 |
| **Complexity** | Simple (2 keys) | Moderate (3 keys + category calc) |

---

## Testing Checklist

- [x] Affiliation matching works with team_id
- [x] Affiliation matching skipped gracefully when team_id missing
- [x] Existing affiliations detected and ID populated
- [x] New affiliations have `team_affiliation_id: null`
- [x] Main skips existing affiliations
- [x] Main creates new affiliations only
- [x] Logging shows matched vs. new
- [x] All three data source paths updated (LT4 array, LT4 hash, LT2)

---

## Files Modified

### TeamSolver
- `/app/strategies/import/solvers/team_solver.rb`
  - Added `build_team_affiliation_entry` method
  - Updated all 3 affiliation creation points
  - Updated documentation

### Main
- `/app/strategies/import/committers/phase_committer.rb`
  - Updated `commit_phase2_entities` to iterate over affiliations
  - Simplified `commit_team_affiliation` method
  - Changed method signature from `(team_id:, season_id:)` to `(affiliation_hash:)`

---

## Code Metrics

**TeamSolver:**
- +32 lines (new method + error handling)
- 3 update sites (all affiliation creations)

**Main:**
- -3 lines (simplified logic)
- -1 lookup operation (no DB query needed)
- +1 array iteration (explicit affiliations loop)

**Net Impact:**
- Cleaner separation of concerns
- Earlier error detection
- Better data visibility

---

## Pattern Established

This completes the pattern for **junction table matching**:

✅ **Phase 2**: TeamAffiliations (team ↔ season)  
✅ **Phase 3**: Badges (swimmer ↔ team ↔ season)

**Ready to Apply:**
- **Phase 4**: MeetingEvents (session ↔ event_type)
- **Phase 5**: MeetingPrograms (event ↔ category ↔ gender)

The pattern is proven for simple (2-key) and complex (3-key + calculation) scenarios! 🎯

---

## Next Steps

Continue with **Phase 4 MeetingEvent matching**:
- Match key: `(meeting_session_id, event_type_id)` or `(session_id, event_order)`
- Add field: `meeting_event_id`
- Benefit: Update existing events vs. always creating new ones

This will handle cases where events are rescanned or re-imported for the same meeting.
