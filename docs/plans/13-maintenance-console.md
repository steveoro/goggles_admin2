# Phase 13 — Maintenance console (remaining operations, season-start checklist)

## Goal

Finish moving terminal-only maintenance into the UI. Phase 13 has four parts:
- Wrap the remaining strategies as `Maintenance::Operation`s.
- Turn every operational rake task into a thin `Maintenance::RakeRunner` caller, proven by recorded output/SQL baselines.
- Replace the hard-coded `DEFAULT_SEASON_ID`.
- Turn `docs/HOWTO_prepare_new_season_at_championship_start.md` into a guided season-start checklist.

With 06 and 11, this completes the operator's requirement: every health finding gets a mitigation in the UI.

## Operator-visible outcome

- `/operations` lists every maintenance operation, each with a form (lookups instead of raw ids), a dry run, an apply and a history.
- The remaining buttons of the 06 check-to-action table appear: `season.badge_fix` (all sure badge merges of a season) and the season-start checklist on `season.setup` findings.
- `/operations/season_start/:season_id`: an ordered checklist that refuses steps whose prerequisites are not met.
- Rake tasks keep their names, arguments, prompts and messages. Their scripts go to `results.new/misc/` with the global Outbox number.

## Depends on

- 11: the whole framework (`Operation`, `Plan`, `Executor`, `OutputCapture`, `RunJob`, `Ops::OperationRun`, confirmation component).
- Through 11: 06 (findings), 07 (`Outbox::Writer`, `LocalDb::SqlRunner`, held scripts), 08 (`Drift::Gate`, API capability detection), 09 (pipeline stale marking).

## Invariants that apply here

- `Maintenance::RunJob` in apply mode is enqueued only by a controller action after an operator click. Retries are disabled. Rake runs the `Executor` inline, because there the operator is at the terminal.
- `plan` never writes. Apply = re-plan, compare the SQL digest with the preview, run `Drift::Gate.check(scope: :operation, ...)` (before planning the apply, never on a dry run), apply locally, register in the Outbox only on success, then trigger a health re-run.
- Scripts are pushed in local-apply order (global seq). Folder `results.new/misc/`, written by `Outbox::Writer.write!` (07; never `register!`, never `results.new/maintenance/`); the season is stored on the Outbox row. The one exception is `standard_timings.import`, which follows 07 into `results.new/<season>/`. Operations use 07's existing kinds (`merge`, `fix`, `purge`, `normalize`, `categories`, `standard_timings`).
- No admin2-only MySQL tables. `db:run` (arbitrary SQL) stays terminal-only.
- "Staging" means the `data_import_*` tables. The staging environment gets no new behaviour.
- Conventions: `# frozen_string_literal: true`, en+it, CHANGELOG + PATCH bump for each user-visible step, `rubocop -a` clean, no bare `db:prepare`/`db:migrate`.

## Scope

New:
- `app/services/maintenance/operations/{meeting_merge,meeting_team_fix,badge_team_fix,badge_swimmer_fix,meeting_purge,coded_names_normalize,categories_clone,standard_timings_import,season_badge_fix}.rb`
- Read-only inspectors (plan only, no apply): `app/services/maintenance/inspectors/{team_check,swimmer_check,badge_check,season_badges,map_team_badges,map_swimmer_mirs,dup_badges_for_team}.rb`
- `app/strategies/merge/season_badge_fixer.rb` (`Merge::SeasonBadgeFixer`, from `merge.rake:427-643`)
- `app/strategies/import/standard_timings.rb` (`Import::StandardTimings`, from `import_standard_timings.rake:43-146, 163-287`)
- `app/services/maintenance/rake_runner.rb`
- `app/controllers/maintenance/season_start_controller.rb`, `app/services/maintenance/season_start/{checklist,step}.rb`, views, `config/locales/maintenance.{en,it}.yml` additions
- `spec/support/rake_parity/` (recorded baselines) + `spec/lib/tasks/*_parity_spec.rb`

Modified:
- `lib/tasks/{check,merge,fix,purge,normalize,import_categories,import_standard_timings,season_board}.rake`: thin callers.
- `app/strategies/merge/meeting.rb:52`: forward `console_output:` to `MeetingChecker.new` (it already accepts the flag at `meeting_checker.rb:45`).
- `lib/tasks/check.rake:20` and `import_standard_timings.rake:12`: `DEFAULT_SEASON_ID = 262` → `SeasonDefaults.default_season_id` (`app/services/season_defaults.rb:15-17`).
- `config/routes.rb` and `Shell::Navigation` (extends 11's Operations item with the season-start checklist).
- `docs/HOWTO_prepare_new_season_at_championship_start.md`, `docs/merge/MERGE_SEMANTICS.md`, `CHANGELOG.md`, `lib/version.rb`.

## Remaining operations

| Key | Strategy call (verified) | Dry run shows | Confirmation | Notes |
|---|---|---|---|---|
| `meeting.merge` | `Merge::Meeting.new(source:, dest:, skip_columns:, console_output: false)` (`meeting.rb:46`), `#prepare` (returns false on checker failure, 65-72), `#sql_log` (`merge.rake:258`); after apply `#verify_merge_result` (`merge.rake:267`) captured into the run | Checker log, `warning_log`, expected counts | typed | Needs the `meeting.rb:52` forwarding fix |
| `meeting.team_fix` | `Merge::TeamInMeeting.new(meeting:, src_team:, dest_team:, full_report:, index:)` (`merge.rake:687`), `#prepare`, `#sql_log` (708). Raises `ArgumentError` on bad input (688-691) → `Plan.errors` | `display_report` text captured (272-332) | confirm | `index:` is the file index in rake; pass the Outbox's next seq for report parity (not verified that it only affects the report) |
| `badge.team_fix` | `Merge::TeamInBadge.new(badges:, new_team:, nuke_team:)` (`fix.rake:93`), `#prepare` (raises on duplicates after printing, `team_in_badge.rb:169-171`), `#sql_log` (98) | Affected rows | confirm; typed when `nuke_team` | |
| `badge.swimmer_fix` | `Merge::SwimmerInBadge.new(badges:, new_swimmer:)` (`fix.rake:162`), `#prepare` (`swimmer_in_badge.rb:140-146`), `#sql_log` (167) | Affected rows | confirm | |
| `meeting.purge` | `Purge::Meeting.new(meeting:, stop_at_events:)` (`purge.rake:63`), `#prepare`, `#single_transaction_sql_log` (77), `#row_counts` | Row counts per table | typed | Replaces the stdin prompt at `purge.rake:67-72` in the UI |
| `coded_names.normalize` | `Normalize::CodedNames.new(limit:)` (`normalize.rake:65`), `#call`, `#change_log`, `#duplicate_pool_ids`, `#stats`, `#single_transaction_sql_log` (80) | Change log, stats, skipped pools | typed | Today it writes to `results.new/normalize/` (`normalize.rake:58, 81`); now `misc/` |
| `categories.clone` | `Import::CategoryCloner.new(src_season:, dest_season:, remove_codes:)` (`import_categories.rake:72`), `#prepare`, `#errors`, `#sql_log` (86) | Inserts, skipped, deletes | confirm; typed with `remove_codes` | Checklist repair tool only (see risks) |
| `standard_timings.import` | New `Import::StandardTimings.new(season:, source: nil)`: `resolve_source_filename` (163-185), `check_data_validity` (189), the row builder `add_insert_row` (270); `Parser::StandardTimingXlsx` unchanged | File used, sheets, validity errors, row count | confirm | Today writes `results.new/000-<season>-standard_timings.sql` and never applies locally (`import_standard_timings.rake:144-145`) |
| `season.badge_fix` | New `Merge::SeasonBadgeFixer.new(season:, include_possible: false, src_team_id: nil, dest_team_id: nil)`. It runs `Merge::BadgeSeasonChecker` and the step 0-3 loop, calling `Merge::Badge.new(source:, dest:, force: true)` or `(…, autofix: true)` per candidate (`merge.rake:626-631`) | Candidate counts per step, per-badge plan | typed | Progress-reporting, cancellable `RunJob`; decisions below |

### `merge:season_fix` behaviour without `src_team` (read, not run)

Confirmed by reading:
- `season_fix` sets `src_team` only when given (`merge.rake:434`), so it is `nil` otherwise.
- `process_merge_badges` then does `src_team = options[:src_team].to_i` (line 607), giving `0`, and skips with `next if src_team && source.team_id != src_team` (line 622). `0` is truthy in Ruby and no badge has `team_id` 0, so **every candidate is skipped**. `dest_team` likewise becomes 0 (608), so the forced branch never fires.
- Steps 0-2 end on "No changes detected" (486-488, 508-510). **Step 3 has no such exit** (517-536). `break if src_team.present?` (535) tests the task-level `nil`, so while `relay_badges` is non-empty the loop re-runs `checker.run` forever.
- Even with a team filter, the same starting `file_index` goes to step 0 and to every pass of step 1 (449, 461, 477). Steps 2-3 pass none and re-read the folder (612). The task also applies every script locally (`simulate: false`, line 637), unlike every other task.

`Merge::SeasonBadgeFixer` fixes the filter (`nil` means no filter), gives step 3 the same no-change exit, and lets the Outbox allocate numbers. A spec covers the no-filter case. The decision below sets the intended behaviour.

## Rake conversion table

`RakeRunner.call(key, env: ENV, out: $stdout, input: $stdin)` does the following:
- Maps ENV to params and prints the same header lines.
- Plans, then prints `plan.console` unchanged.
- Keeps the task's prompt between plan and apply.
- Maps `simulate=1` (the default) to `script_only` and `simulate=0` to `apply`.
- Exits where the task exits today.
- Checks `Drift::Gate.check(scope: :rake, force: ENV['force'] == '1')` before a local apply (08: red blocks unless `force=1`).

Allowed diffs against the baseline are only the output folder and the numeric prefix.

| Task | ENV args | Becomes | Prompt kept | Folder today → after |
|---|---|---|---|---|
| `check:results`, `check:events` | season, mrr, presence | Unchanged output, `DEFAULT_SEASON_ID` → `SeasonDefaults`; doc points to health | — | none |
| `check:team`, `check:swimmer`, `check:badge` | src, dest | Inspectors (= preview of `team/swimmer/badge.merge`) | — | none |
| `check:season` | season, list_teams | Inspector `season_badges` (preview of `season.badge_fix`) | — | none |
| `check:map_team_badges`, `map_swimmer_mirs`, `dup_badges_for_team` | season, team, page… | Read-only inspectors | — | none |
| `check:dup_mir_badges` | meeting_id | Inspector; season form = health `results.dup_mir_per_badge` | — | none |
| `check:dup_mir_swimmers` | meeting_id/season_id, autofix, simulate, index | `results.dedupe` (11); "nothing to do" from `Plan#empty?` (fixes the `size <= 5` guard, `check.rake:399`) | yes (403-408) | root → misc |
| `merge:swimmer` | src, dest, skip_columns, force, simulate, index | `swimmer.merge` (11) | — | root → misc |
| `merge:team` | src, dest, skip_columns, keep_as_alias, … | `team.merge` (11) | — | root → misc |
| `merge:meeting` | src, dest, skip_columns, … | `meeting.merge` | — | root → misc |
| `merge:badge` | src, dest, keep_dest_*, force, autofix, … | `badge.merge` (11); abort rule of `merge.rake:364-367` kept | — | root, but numbered from the season folder (index 331, file 370 without `subdir`) → misc |
| `merge:season_fix` | season, index, possible, src_team, dest_team | `season.badge_fix` | — | `results.new/<season>/` (636-637) → misc |
| `merge:team_in_1_meeting` | meeting, src, dest, simulate, index, full_report | `meeting.team_fix` | yes (697-702) | root → misc |
| `fix:team_in_badge`, `fix:swimmer_in_badge` | badge, team/swimmer, nuke_team, … | `badge.team_fix`, `badge.swimmer_fix` | — | root → misc |
| `fix:nil_swimmers_in_results` | meeting_id/season_id, simulate, index | `results.null_swimmers_fix` (11), season loop in RakeRunner | — | root → misc |
| `purge:meeting` | meeting, stop_at_events, simulate, index | `meeting.purge` | yes (67-72) | root → misc |
| `recompute:ranks` | season/meeting, simulate, index | `ranks.recompute` (11; switched in 11) | — | root → misc |
| `normalize:coded_names` | limit, simulate, index | `coded_names.normalize` | — | `normalize/` → misc |
| `import:categories` | src, dest, remove, simulate, index | `categories.clone` | — | root → misc |
| `import:standard_timings` | season, source | `standard_timings.import` | — | root `000-` → `results.new/<season>/` via Outbox, held |
| `season_board:backfill` | season, simulate | `season_board.backfill` (11) | — | `results.new/<season>/` → misc |
| `db:run` | path | Unchanged, terminal only (07 already uses `LocalDb::SqlRunner`) | — | — |

Out of conversion: `manifests:extract`, `fixtures_*`, `pdfs_from_results`, `solid:prepare`, `ops:*`.

## Season-start checklist

`Maintenance::SeasonStart::Checklist.new(season_id:)` exposes ordered `Step`s, each with `ready?` (prerequisites done), `done?` (derived from data whenever possible) and an action. A step whose prerequisites are not met renders disabled, and its POST is refused (request spec for each step).

1. **Season rows exist locally** for each federation type: `GogglesDb::Season.exists?(id:)`. Created by the goggles_db data migration `data_fix_add_20<yy>_seasons` (HOWTO step 1). Instructions only.
2. **CategoryTypes exist**: `CategoryType.where(season_id:).count.positive?`. Created by `data_fix_add_20<yy>_category_types` (`GogglesDb::CmdCloneCategories`). `categories.clone` is offered only as a repair when the count is 0 and the remote already has the season.
3. **Dev and test migrated, test dump refreshed** (`app:db:migrate`, `RAILS_ENV=test … app:db:dump`; HOWTO step 2). Tick box with operator note; cannot be checked from admin2.
4. **Standard-timings file present** under `crawler/data/standard_timings/<season_id>/` (discovered with `resolve_source_filename`), or uploaded into that folder (path confined to `crawler/data`).
5. **`standard_timings.import`**: preview shows validity errors. Apply runs locally, and the script is registered with `Outbox::Writer.write!(kind: 'standard_timings', name:, sql:, folder: <season id>, season_id:, applied_locally: true, held: true, origin:, data_root:)`, so it starts **held** until step 6.
6. **Remote season exists**: `GET season/:id` through `APIProxy.call` (goggles_api `seasons_api.rb:16-17`), checked on demand (never on page load). When it exists, the step releases the held script for push (HOWTO lines 74-76: pushing earlier fails).
7. **Static calendar URLs checked**: tick box. Where these URLs live is not verified; the step text must name the file once 15's Sources area exists.
8. **`season_board.backfill`** for the new season after the first calendar crawl. `SeasonDefaults.default_season_id` must now return the new id (shown as a check).

Step state is stored in the ops table below. Steps 1, 2, 4, 6 and 8 re-derive `done?` from data on every view.

## Data model

**`season_checklist_items`**: `season_id!`, `step_key!`, unique `(season_id, step_key)`, `status!` (pending|done|skipped), `note`, `done_by`, `done_at`, `operation_run_id`, timestamps.

No other new tables. Operations use 11's `operation_runs`.

## Ordered steps

1. **Rake parity harness** (not user-visible): record console output and SQL for each task in the conversion table on the test DB, with fixed ids (`simulate=1`) and a stubbed stdin, under `spec/support/rake_parity/`.
2. **Operations batch 1** (user-visible, CHANGELOG + PATCH): `meeting.merge` (+ `meeting.rb:52` fix), `meeting.team_fix`, `badge.team_fix`, `badge.swimmer_fix`, `meeting.purge`, and the inspectors.
3. **Operations batch 2** (user-visible, CHANGELOG + PATCH): `coded_names.normalize`, `categories.clone`.
4. **`season.badge_fix`** (user-visible, CHANGELOG + PATCH): `Merge::SeasonBadgeFixer` after the operator decides; progress and cancel on `RunJob`; Fix button on the season's `badges.duplicate.sure` section.
5. **Standard timings** (user-visible, CHANGELOG + PATCH): `Import::StandardTimings`, the operation, held-script handling.
6. **Rake conversion**, one namespace per commit in the order merge, fix, purge, recompute, normalize, import, check, season_board (user-visible only through the folder/prefix change: one CHANGELOG + PATCH for the whole step). Each switch must pass its parity spec. `DEFAULT_SEASON_ID` is replaced in the same step.
7. **Season-start checklist** (user-visible, CHANGELOG + PATCH): page, steps, Fix button on `season.setup` findings. HOWTO rewritten around it; `MERGE_SEMANTICS.md` points to the operations.

## Specs and manual verification

- Parity spec per converted task: identical console text and SQL bodies except for the folder and the `NNNN` prefix.
- One spec per new operation: `plan.sql_lines` equal the strategy's direct output on the existing `spec/strategies/{merge,fix,purge,normalize,import}` fixtures; preview writes nothing (06 no-write subscriber).
- `season_badge_fixer_spec`: no team filter processes every sure candidate; with `src_team_id`, only that team's badges; step 3 terminates when nothing changes; `include_possible: false` by default.
- `standard_timings_spec`: XLSX fixture → same rows as the rake; validity errors abort before any SQL; the script is held until `GET season/:id` succeeds (stubbed).
- Checklist request specs: an out-of-order POST for each step is refused; done steps re-derive from data.
- A grep spec: no file under `lib/tasks/{merge,fix,purge,recompute,normalize,import_categories,import_standard_timings}.rake` calls a strategy's `.new` directly or defines `process_sql_file` logic of its own.
- Manual: run `season.badge_fix` preview on a closed season with sure merges, compare the candidate counts with `check:season`, apply on a scratch copy and confirm the health re-run clears `badges.duplicate.sure`.

## Exit criteria

- The remaining rows of the phase-06 check-to-action table have their button: `season.badge_fix` on duplicate/relay badge findings and the season-start checklist on `season.setup`. Together with 11, every row of that table now ends in a UI action.
- No operational rake task holds business logic of its own; every row of the conversion table passes its parity spec.
- `DEFAULT_SEASON_ID` no longer appears in `lib/tasks`.
- The checklist refuses out-of-order steps.
- Routine gate: sign in → board → crawl → review → commit → report → push → confirm still works.

## Risks and mitigations

- Conversion changes behaviour the operator relies on (texts, exits, prompts). Mitigations: recorded baselines, one namespace at a time, prompts and exits kept in the rake caller.
- `season.badge_fix` without a filter touches hundreds of badges in production once pushed. Mitigations: typed confirmation, progress and cancel, per-step counts in the preview, possible merges off by default.
- `categories.clone` pushed from admin2 can collide with the goggles_db data migration that inserts the same categories on deploy. Mitigation: offered only as a checklist repair when the remote season exists and the local count is 0.
- Applying standard timings locally before the remote season exists keeps local and remote apart for a while. Mitigation: the held state plus the explicit step 6 release.

## Decisions to confirm

- `season.badge_fix` without `src_team`: process every candidate (the task description's intent) or keep today's effective no-op. **Default: process every sure candidate. Possible merges only with an explicit checkbox and a team filter.**
- Bundling: one Outbox script per badge (today) or one per step. **Default: one script per step**, each badge in its own transaction inside the file (keeps the `badge.rb` transaction note at `merge.rake:634-635`).
- Standard timings applied locally. **Default: yes, with the script held until the remote season exists.**
- `simulate=1` in rake keeps writing a script that is not applied. **Default: yes; registered `applied_locally: false`, held in the Outbox.**

## Out of scope

`db:run`; manifest and fixture tasks; a global team-duplicate detector; creating Season rows from admin2 (stays a goggles_db migration); crawling static calendars (15).

## Rollback note

Each namespace switch is its own commit. Reverting one restores the original rake body, and its parity baseline still applies. Operations can be hidden with `operations.enabled`. `season_checklist_items` can be dropped. Scripts already in the Outbox stay valid, because they are ordinary numbered files.
