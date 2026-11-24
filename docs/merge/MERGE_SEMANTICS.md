# Merge semantics across Merge classes

This document describes the common source/destination contract shared by all
merge strategies in `goggles_admin2` and the specific columns each class
overwrites.

> **From the UI (phases 11 and 13):** every merge and fix strategy also runs as a maintenance operation (`/operations`,
> or the **Fix** buttons of the data health findings): `Merge::Badge` => `badge.merge`, `Merge::Swimmer` =>
> `swimmer.merge`, `Merge::Team` => `team.merge`, `Merge::Meeting` => `meeting.merge`, `Merge::TeamInMeeting` =>
> `meeting.team_fix`, `Merge::TeamInBadge` => `badge.team_fix`, `Merge::SwimmerInBadge` => `badge.swimmer_fix`,
> `Merge::SeasonBadgeFixer` (the former `merge:season_fix` loop) => `season.badge_fix`, `Merge::DuplicateResultCleaner`
> => `results.dedupe`; the checkers (`TeamChecker`, `SwimmerChecker`, `BadgeChecker`, `BadgeSeasonChecker`,
> `DupBadgesForTeamChecker`) are the read-only inspectors (`team.check`, `swimmer.check`, `badge.check`,
> `season.badges`, `team.dup_badges`). Same calls and options as the `merge:*` / `fix:*` / `check:*` rake tasks, which
> since phase 13 are thin callers of the same operations (`Maintenance::RakeRunner`): a dry run first (checker log,
> warnings, errors, SQL), then a confirmed local apply that registers the script in the SQL Outbox
> (`results.new/misc/`). See `app/services/maintenance/operations/` and the data health section of
> `docs/season_board.md`.

## Common contract

Every merge follows the same identity rule:

- **Source row** (`src`): the row whose data is being moved.
- **Destination row** (`dest`): the row whose `id` survives after the merge.
- The source row is deleted, the destination row is kept, and source values
  (according to the class-specific rules below) are written into the
  destination row.
- `skip_columns` / `keep_dest_*` / `force` options only change which column
  values are written; they never swap the row roles.

```text
[SOURCE] ------------------------> [DESTINATION]
- to be purged (ID disappears)  /  - to be kept (ID remains)
- values overwrite destination,   /  - destination ID is retained
  according to parameters
```

## `Merge::Swimmer`

- Destination `id` is retained.
- `skip_columns=true` suppresses the final `UPDATE swimmers` entirely.
- When `skip_columns=false` (default) the following source columns overwrite
  the destination:
  - `last_name`
  - `first_name`
  - `year_of_birth`
  - `complete_name`
  - `nickname`
  - `associated_user_id`
  - `gender_type_id`
  - `year_guessed`
- Contact columns (`phone_mobile`, `phone_number`, `e_mail`) are intentionally
  not overwritten.
- Rake task: `merge:swimmer src=<id> dest=<id> [skip_columns=1] [force=1]`

## `Merge::Meeting`

- Destination `id` is retained.
- `skip_columns=true` suppresses the final `UPDATE meetings` entirely.
- When `skip_columns=false` (default) only the three boolean flags are updated:
  `results_acquired`, `manifest`, `startlist`.
- The update uses OR logic: each flag is set to `1` if the source has it `true`
  and the destination does not; existing `true` flags on the destination are
  never reset to `0`.
- No other meeting columns (description, notes, etc.) are overwritten.
- Rake task: `merge:meeting src=<id> dest=<id> [skip_columns=1]`

## `Merge::Badge`

- Destination `id` is retained.
- There is no `skip_columns` option. The class uses `keep_dest_columns`,
  `keep_dest_category`, `keep_dest_team`, `force` and `autofix`.
- The final `UPDATE badges` only changes these columns when they differ:
  - `team_id`
  - `team_affiliation_id`
  - `category_type_id`
- Other badge columns (`number`, `off_gogglecup`, `fees_due`, etc.) are
  intentionally not overwritten.
- `keep_dest_columns` and `keep_dest_team` keep the destination's
  `team_id` and `team_affiliation_id`.
- `keep_dest_category` keeps the destination's `category_type_id`.
- `force` uses all source key values (`team_id`, `team_affiliation_id`,
  `category_type_id`).
- Rake task:
  `merge:badge src=<id> dest=<id> [keep_dest_columns=1] [keep_dest_category=1]
  [keep_dest_team=1] [force=1] [autofix=1]`

### Sub-merge usage

- `Merge::Team` calls `Merge::Badge` with `keep_dest_team: true, force: true`.
  This keeps the destination (kept) team on the badge while allowing any
  category conflict to be resolved from the source badge.
- `Merge::Swimmer` calls `Merge::Badge` with `force: true`. This overwrites the
  destination badge's team/category/affiliation with the source badge values
  during the swimmer merge.
