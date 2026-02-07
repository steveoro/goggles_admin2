# Team Merge — Full Duplicate Elimination

## Overview

`Merge::Team` produces a **single-transaction SQL script** that merges a source team into a destination, including inline badge merging for shared swimmers.

This replaces the old multi-step workflow (`check:team` → `merge:badge` × N → `merge:team`).

## Script Phases

1. **Reservation cleanup** — DELETE all source-team reservations (deprecated entities)
2. **Per-season TA processing** — For each source TeamAffiliation:
   - Badge sub-merges for shared badge couples (via `Merge::Badge`)
   - Orphan badge updates (simple `team_id` / `team_affiliation_id` reassignment)
   - Catch-all UPDATE for remaining TA-linked entities
   - DELETE or recycle source TA
3. **Team-only links** — UPDATE `computed_season_rankings`, `goggle_cups`, `individual_records`, `laps`, `meetings`, `relay_laps`, `team_lap_templates`, `user_workshops`
4. **DuplicateResultCleaner** — Safety net per shared season
5. **Destination update** — Overwrite dest team columns, DELETE source team + aliases

## Badge Sub-Merge Options

Each shared badge couple is merged with:
```ruby
Merge::Badge.new(source: src_badge, dest: dest_badge, keep_dest_team: true, force: true)
```
- `keep_dest_team: true` — dest team_id is always used
- `force: true` — category conflicts are overridden (source category wins unless relay-only)
- If a badge sub-merge fails, a warning is logged and processing continues

## Key Classes

| Class | Role |
|-------|------|
| `Merge::Team` | Main strategy — generates the SQL script |
| `Merge::TeamChecker` | Identifies shared seasons, shared badge couples, orphan badges |
| `Merge::Badge` | Handles per-badge duplicate elimination (composed inline) |
| `Merge::DuplicateResultCleaner` | Final safety net for remaining duplicates |

## Usage

```bash
# Analyze and generate script (no DB changes):
bundle exec rake merge:team src=<source_team_id> dest=<dest_team_id>

# Generate AND execute on localhost:
bundle exec rake merge:team src=<source_team_id> dest=<dest_team_id> simulate=0

# Skip overwriting destination columns:
bundle exec rake merge:team src=<source_team_id> dest=<dest_team_id> skip_columns=1
```

Output: `crawler/data/results.new/<index>-merge_teams-<src>-<dest>.sql`

## Related Files

- `app/strategies/merge/team.rb`
- `app/strategies/merge/team_checker.rb`
- `app/strategies/merge/badge.rb`
- `app/strategies/merge/badge_checker.rb`
- `app/strategies/merge/duplicate_result_cleaner.rb`
- `lib/tasks/merge.rake`
- `spec/strategies/merge/team_spec.rb`
- `spec/strategies/merge/team_checker_spec.rb`
