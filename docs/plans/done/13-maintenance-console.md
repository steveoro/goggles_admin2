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

## Outcome (done, 0.10.93, 2026-11-24)

Delivered on `feature/modernize-admin-console-ux` (steps 1-7 in one pass, one PATCH for the whole phase), in the same working tree as phase 12 (Data-Fix wizard UX), implemented in parallel. All four decisions confirmed with their defaults: `season.badge_fix` without `src_team` processes every sure candidate, the possible merges only with their checkbox AND a source team; one Outbox script per step, each badge in its own transaction inside the file; standard timings applied locally with the script held until the remote season exists; rake `simulate=1` keeps writing a script registered `applied_locally: false`, held `not_applied_locally`. Rake parity recorded first (step 1, below), before any task body changed. Targeted runs with a private ops test DB (`OPS_DATABASE_URL=sqlite3:tmp/ops_p13.sqlite3`), no full suite (the coordinator runs it): the phase-13 set (`spec/services/maintenance/**`, `spec/jobs/maintenance`, `spec/requests/maintenance/**`, `spec/components/maintenance`, `spec/tasks/**` with the eight parity specs, `spec/models/ops`, `spec/requests/health`, the lookup request spec, navigation, i18n parity, BS4 ratchet, `spec/config`, `spec/strategies/merge/{season_badge_fixer,meeting}_spec.rb`, `spec/strategies/import/standard_timings_spec.rb`, `spec/strategies/recompute`, the commit report Fix links spec, phase 10's automation boundary spec) **467 examples, 2 failures**: the two specs asserting the default ops DB path (`spec/models/ops/{application_record,database}_spec.rb`, expected with `OPS_DATABASE_URL`; **19 examples, 0 failures** when rerun on the default ops DB). Earlier broad run (also `spec/strategies/{merge,normalize,purge,fix,parser}`, `spec/strategies/import/category_cloner_spec.rb`, `spec/services/health`): 1035 examples, the same 2 plus 6 of 07's `spec/tasks/outbox_rake_spec.rb` (it tested the removed `process_sql_file`; rewritten on the RakeRunner path, 5 examples green). Neighbours (`spec/services/outbox`, `spec/jobs`, `spec/routing`, `spec/components`, `spec/views`, the Outbox / dashboard / inbox / shell request specs, `spec/services/inbox`, `SeasonDefaults`): **822 examples, 0 failures, 24 pending** (existing pending). Rubocop clean on every Ruby file touched (111 files, `lib/tasks/*.rake` included); haml-lint clean on every new or touched template. No system spec added or changed; no SCSS change (no CSS rebuild).

- **Parity (step 1)**: harness `spec/support/rake_parity/harness.rb` (`RakeParity`: run a task with ENV, stubbed stdin and `SCRIPT_OUTPUT_DIR` in a temp data root, inside the spec transaction; normalize the temp root, the `NNNN-` prefixes, the Outbox seq, `-- Generated:` and other timestamps, durations; tokens for the ids of rows a case creates) and `RakeParity::Fixtures` (fixed goggles_test ids: season 182, badges 115299 / 115303, meetings 1 / 5 / 18211 / 18222 / 18289 / 18315, teams 1 / 2 / 54 / 913 / 1193 / 1270 / 1292, swimmers 23 / 142, seasons 252 / 262; deterministic copies of existing rows; an XLSX built with caxlsx; `hide_leftover_seasons!` deletes, inside the transaction only, the 923 factory seasons left on the shared goggles_test DB: `Merge::BadgeChecker.map_categories_x_seasons` reads "the latest 12 seasons of the type" and crashed on them). 39 baselines in `spec/support/rake_parity/baselines/*.txt` (1.5 MB, exit status + output + every script), recorded with the pre-13 bodies and replayed green on them (determinism check) before the switch; replayed by `spec/tasks/{merge,fix,purge,recompute,normalize,import,check,season_board}_parity_spec.rb` (39 examples). Re-record only on purpose (`RAKE_PARITY_RECORD=1`; after a goggles_test reload the old bodies are gone, so a re-record pins the converted tasks).

| Task | Cases (simulate=1) | Result |
|---|---|---|
| `merge:swimmer` | 142→23 (checker issues: aborted), `force=1` (530 KB), invalid ids | identical |
| `merge:team` | 1→2 | identical |
| `merge:meeting` | 1→5 (checker progress dots, warnings log of 115 lines) | identical (warnings log file path included) |
| `merge:badge` | created sure copy of 115299 (2 MIRs moved) → 115299; `autofix=1` on 115303 put on a relay category | identical |
| `merge:team_in_1_meeting` | 18289, 913→1270, answer `y` / `n` | identical |
| `merge:season_fix` | `src_team=1292`, one sure copy + one relay-only badge (the former body applied each badge: here through ActiveRecord in the transaction) | **changed by decision**: header lines identical; replayed with `simulate=0` and the same stand-in, each former per-badge script appears verbatim, in order, inside the two step scripts (`season_fix_182-step1-sure`, `-step2-relay_only`) |
| `fix:team_in_badge` | 115303 → team 1193; missing team | identical |
| `fix:swimmer_in_badge` | 115303 → swimmer 142 | identical |
| `fix:nil_swimmers_in_results` | meeting 18315 (2 NULL swimmers); season 192 (nothing to fix) | identical |
| `purge:meeting` | 18222 `y`; `stop_at_events=1` `y`; not confirmed | identical |
| `recompute:ranks` | meeting 18211 (two ranks swapped) | identical (former name `<season>-recompute_ranks` kept) |
| `normalize:coded_names` | `limit=25` with two codes to normalize; `limit=25` nothing to do | identical; **deviation** for the empty batch: same report, then "Nothing to do", no empty script |
| `import:categories` | 252→262 `remove=M25,U20` | identical |
| `import:standard_timings` | season 262, `source=` XLSX fixture (4 rows); unknown season | identical (same folder `results.new/262/`, held) |
| `check:results` ×3, `check:events` | season 182, `mrr presence`, default season | identical (lines compared sorted: the meetings are ordered by date only, ties come back in any order, also before 13) |
| `check:team`, `check:swimmer`, `check:badge`, `check:season list_teams=1`, `check:map_team_badges`, `check:map_swimmer_mirs`, `check:dup_badges_for_team`, `check:dup_mir_badges`, `check:dup_mir_swimmers` (report; `autofix=1` `y`) | as listed | identical |
| `season_board:backfill` | season 182, simulate (empty crawl root and watcher snapshot) | identical |

  No task left unconverted. `db:run`, `manifests:extract` (only `DEFAULT_SEASON_ID` → `SeasonDefaults`), fixtures, `pdfs_from_results`, `solid:prepare`, `ops:*` are out of the conversion as planned.
- **Names as shipped.**
  - Operations (appended to `Maintenance::Registry::CLASS_NAMES`): `Maintenance::Operations::{MeetingMerge, MeetingTeamFix, BadgeTeamFix, BadgeSwimmerFix, MeetingPurge, CodedNamesNormalize, CategoriesClone, StandardTimingsImport, SeasonBadgeFix}` with the plan's keys and confirmations (`meeting.team_fix`, `badge.swimmer_fix`, `categories.clone`, `standard_timings.import`: checkbox; `badge.team_fix`: checkbox, typed `NUKE TEAM <id>` with `nuke_team`; `categories.clone`: typed `CLONE <src> INTO <dest>` with `remove_codes`; the others typed: `MERGE <src> INTO <dest>`, `PURGE <id>`, `NORMALIZE`, `FIX SEASON <id>`). Inspectors (`Maintenance::Inspector` < `Operation`, `Registry::INSPECTOR_CLASS_NAMES`): `Maintenance::Inspectors::{TeamCheck, SwimmerCheck, BadgeCheck, SeasonBadges, MapTeamBadges, MapSwimmerMirs, DupBadgesForTeam, DupMIRBadges}` (keys `team.check`, `swimmer.check`, `badge.check`, `season.badges`, `team.map_badges`, `swimmer.map_mirs`, `team.dup_badges`, `meeting.dup_mir_badges`; `MIR` is an inflection acronym).
  - Strategies: `Merge::SeasonBadgeFixer` (`#prepare` plans one step: `STEPS` possible / sure / relay_only / relay, `#counts`, `#planned` / `#deferred` / `#failed` `Outcome`s, `#sql_log`, `#more_to_do?`, `PROGRAM_INSERT_REGEXP`) and `Import::StandardTimings` (`#call { |event, value| }`, `#resolve_source_filename`, `#check_data_validity`, `#errors` / `#validity_errors`, `#sql_log`, `.event_label_to_code`, `BASE_DIR`). `Merge::Meeting` forwards `console_output:` to its checker.
  - Framework: `Maintenance::Operation.param(name, type, form: false, lookup:)` (`Field#form`, `#lookup`), `.form_fields`, `.inspector?`, `.checklist_only?`, `.season_wide?`, class attribute `cancellable`, `#captured_output`, `#plan_exception`, `#outbox_folder`, `#held_reason`, `#after_local_apply(plan)`, `#report_progress`; `Maintenance::Cancelled`; `Maintenance::Executor` options `script_text:`, `script_prefix:`, `script_name:`, `origin:`, readers `#operation`, `#plan`, `#after_apply_output`, `PROGRESS_INTERVAL` (1 s); `Ops::OperationRun` columns `progress`, `cancel_requested_at` (`db/ops_migrate/20261124900001_add_progress_to_operation_runs.rb`), refusal reason `cancelled`, `#progress_hash`, `#progress_percent`, `#cancellable?`, `#request_cancel!`.
  - Rake: `Maintenance::RakeRunner` (`.call(task_name, env:, out:, input:, data_root:, sql_runner:, gate:)`, `Stop`, `TaskError`, `PrintingSqlRunner`, `SCRIPT_TEXT`, `#check_gate!`), `Maintenance::RakeTasks` (`TASKS`, `.fetch`, `Base`) and the adapters `Maintenance::RakeTasks::{MergeTasks, FixTasks, PurgeTasks, RecomputeTasks, NormalizeTasks, ImportTasks, CheckTasks, SeasonBoardTasks}::*`. Each task body is `status = Maintenance::RakeRunner.call('<task>', data_root: SCRIPT_OUTPUT_DIR.dirname); exit(status) if status`.
  - Checklist: ops table `season_checklist_items` → `Ops::SeasonChecklistItem` (`db/ops_migrate/20261124900002_create_season_checklist_items.rb`), `Maintenance::SeasonStart::{Checklist, Step}` (`STEP_KEYS`, `HOWTO_PATH`, class attribute `standard_timings_dir`), `Maintenance::SeasonStartController` (`index`, `show`, `step` with `perform` confirm / skip / reopen / upload / check_remote / operation / repair), views `maintenance/season_start/{index,show,_step_actions}`.
  - UI: routes `cancel_maintenance_run` (`POST /operations/runs/:id/cancel`), `season_start_index` (`/operations/season_start`), `season_start` (`/operations/season_start/:season_id`), `season_start_step` (`POST .../steps/:step_key`); navigation item `:season_start` (contextual child of `:operations`, `fa-list-check`); `/operations` gains the Read-only checks card, the checklist button and the checklist-only label; run page progress (`%progress`) and Cancel; `operation_lookup_controller.js` (local lookups on the id fields, `/lookup/{swimmers,meetings,badges,teams,seasons}`); `LookupController` domains swimmers / meetings / badges (with `label`); the season-wide Fix button on a health section (`Operation.season_wide?`) and the `:season_start` link of `season.setup` (`Health::FindingLinks`, icon in `FindingActionsComponent::ICONS`); `OperationRunsGrid` filter lists the inspectors too. Locales: `maintenance.{en,it}.yml` (`index.*`, `params.*`, `facts.*`, `run.*` progress/cancel/inspector, `refusals.cancelled`, `operations.<17 new keys>`, `rake.*`, `lookup.*`, `season_start.*`), `outbox.held_reasons.remote_season_missing`.
- **Review follow-up (same delivery)**, four findings of the independent review, all confirmed against the code and fixed (targeted run after the fixes: the phase-13 set plus `spec/services/outbox`, the Outbox controller spec, the fixer and importer specs, **530 examples, 2 failures**: the same two default-ops-path specs):
  - (a) A script with several transaction blocks was not atomic: `LocalDb::SqlRunner`'s outer `START TRANSACTION` is committed by the first inner one, so a failing badge left the earlier badges committed locally with no Outbox script. `Maintenance::ScriptBlocks.split` finds the blocks; the Executor runs a multi-block script block by block (`tmp/maintenance/<run id>.sql` holds the blocks that ran) and, when block k fails after blocks 1..k-1 ran, registers exactly those as a `-- PARTIAL LOCAL APPLY ...` script and fails the run (`applied_locally` true, `summary['partial']`, the dry run consumed: `Ops::OperationRun#consuming_applies`); the next dry run plans what is left. Only `season.badge_fix` produces several blocks: every script of the 39 recorded rake baselines is one block (spec), the team and swimmer merges inline the badge and cleaner SQL without their transaction lines.
  - (b) When the Outbox registration fails after a local apply, the run now fails with `applied_locally` true and the kept SQL path (`summary['unregistered_sql_path']`, `#unregistered_sql_path`); the run page (outcome `applied_unregistered`) and the rake task (`maintenance.rake.applied_unregistered`) say the SQL RAN, was not registered, where it is and how to register it without running it again; a failed script-only write says nothing ran (`maintenance.rake.not_written`); "Transaction rolled back" is printed only when the local run itself failed.
  - (c) A standard-timings script written with `simulate=1` and applied later from the Outbox ("Apply locally", `db:run`) became pending: the Executor now stores the operation's hold in the script origin (`held_after_local_apply`) and `Outbox::Writer.mark_applied_locally!` puts such a script back to held `remote_season_missing` (scripts without the key keep the 07 behaviour).
  - (d) A released standard-timings script kept its old seq although later scripts may already be pushed: `Outbox::ScriptActions.release!` now resequences a `remote_season_missing` hold (`RESEQUENCE_ON_RELEASE`, `Outbox::Writer.resequence!` made public; the file prefix is renamed in `results.new`), so the Outbox order is the push order (spec on `Outbox::PushPlan`). Chosen over a hold blocking the higher seqs, which would stop every other push until the deploy; the standard-timings INSERTs depend on no later script. An operator hold keeps its seq on release (07 behaviour, spec).
- **Deviations from the plan** (the code won):
  - The rake tasks already wrote through `Outbox::Writer` into `results.new/misc/` since 07 (`process_sql_file`): the "root → misc" column of the conversion table was done; only `merge:season_fix` (`results.new/<season>/` → misc) and `season_board:backfill` with `simulate=0` (its own file in `results.new/<season>/` → misc) change folder. `process_sql_file`, `auto_index_from_script_output_dir` and `process_merge_badges` are gone; `execute_sql_file` stays for `db:run`.
  - Parity specs live in `spec/tasks/*_parity_spec.rb` (the existing rake spec folder), not `spec/lib/tasks/`. Baselines are recorded on fixed goggles_test ids, but the rows a case creates (badge / MIR copies) get tokens, and the factory seasons left on the shared test DB are hidden inside the transaction (see above).
  - `season.badge_fix` plans ONE step per run (= one script per step, the decision), instead of looping inside one plan: a step can only be planned on the data left by the previous one. A badge touching a badge, or a new meeting program, already planned in the step is deferred to the next run (Merge::Badge checks the programs on the current data and the former task applied every badge at once for that reason). The UI suggests the operation again while candidates are left; the rake task with `simulate=0` loops (apply, re-plan) until nothing is left or the planned set repeats (`MAX_ROUNDS` 50), with `simulate=1` (now its default too) it writes the first step only. A badge whose `Merge::Badge` raises is reported as failed (the former task crashed). `possible=1` without `src_team` is refused in the rake too (the former task only warned).
  - The operations keep the former rake file names where they differed (`RakeRunner` passes `script_name:`: `<season>-recompute_ranks`), and the rake script bytes (`SCRIPT_TEXT`: lines joined with "\r\n" plus the final newline, not `Plan#sql_text`'s "\r\n").
  - A plan without statements writes no script any more (the Executor refuses `empty`): `normalize:coded_names` with nothing to change prints "Nothing to do" instead of writing an empty transaction. `check:dup_mir_swimmers` uses `Plan#empty?` (the `size <= 5` guard is gone) and inherits the null-swimmers precondition of `results.dedupe` (refused with an open `results.null_swimmers` finding).
  - `results.dedupe` and `results.null_swimmers_fix` gained rake-only params (`form: false`): `season_id` (the season mode of the two tasks: one script, as before), `report` / `report_only` (dedupe: the cleaner report before the prompt, the report without autofix); `meeting.merge` has the rake-only `console_output` (the checker progress the task printed); `meeting.team_fix` the rake-only `index` (only numbers the suggested commands: checked, `Merge::TeamInMeeting` reads it nowhere else). `Operation.permitted` now takes the form fields only, so a request can never set them.
  - `simulate=0` order changed: the script runs locally first and is registered only afterwards ("--> Executing script..." before "File ... saved (Outbox: pending, seq N)"); a failed local apply registers nothing (before: the file stayed, held `local_apply_failed`) and exits 1. `simulate=0` of the merge/fix/purge/recompute/normalize/import/check tasks now checks the DB sync gate (scope `:rake`, red stops unless `force=1`, any warning printed): `force=1` is also the checker override of `merge:swimmer` / `merge:badge`, so forcing a checker conflict also overrides a red gate (one switch, as the plan's `ENV['force'] == '1'`). `fix:nil_swimmers_in_results simulate=0` no longer prints the per-meeting dots. `merge:meeting simulate=0` prints the post-merge verification after the script lines (captured by `after_local_apply`).
  - The tasks writing a script need the ops DB (their runs are the `/operations` history, origin `rake`); without it they print `maintenance.rake.ops_unavailable` and exit 1 (before: the file was written unregistered). The read-only `check:*` reports and `season_board:backfill simulate=1` plan without any run row (no ops DB needed, no history). The two new rake messages are i18n texts (default locale, like the 08 `db_sync.gate.rake_*` lines).
  - The "lookups instead of raw ids" are local lookups on the id fields (`/lookup`, LookupController extended), not the TomSelect autocomplete: a search box with a native `<datalist>` and the resolved name under the id; badges are resolved by id only (no name to search).
  - `categories.clone` is listed on `/operations` without a form link ("from the season-start checklist"); its form still opens from the checklist repair (or by URL). The checklist offers the repair only when the local count is 0 and the last remote check of step 6 found the season.
  - Step 6 stores its outcome on the step row (done = found and no standard-timings script of the season still held `remote_season_missing`, a new `Ops::SqlScript::HELD_REASONS` entry); step 5 is done when the season has local `StandardTiming` rows; step 8 when `SeasonDefaults.default_season_id` is the season and a succeeded `season_board.backfill` apply exists for it; step 4 when the file is found as the import finds it (`Checklist.standard_timings_dir`). Uploads keep the basename only (sanitized, `.xlsx` / `.csv`), confined to `crawler/data/standard_timings/<season>/`. Step 7 can't name the static calendar file yet (15). The step POST of a step not ready, already done from the data, or with another action is refused with a flash (redirect), never 500.
  - `DEFAULT_SEASON_ID` was also in `lib/tasks/manifests.rake` (out of the conversion): replaced there too (exit criterion).
- **For 15**: the Sources area should name the static calendar URLs in checklist step 7 (`maintenance.season_start.steps.static_calendars.body`). `FileCounter` still has no user (07's note); `process_sql_file` is gone (its rows in the producers table of `docs/outbox.md` were updated). The parity baselines depend on goggles_test: after a test dump reload, re-record them (`RAKE_PARITY_RECORD=1`), knowing that they then pin the converted tasks.
- **Not verified by hand** (the dev server would run the recurring jobs against FIN and the configured API, the dev DB is a production copy, and no rake task may run on it): any rake task or operation on the development DB; `bin/rails ops:prepare` on the development ops DB (the two new migrations ran only on the test ops DBs); `LocalDb::SqlRunner` running a phase-13 script with the MariaDB client (every spec stubs it or runs the statements through ActiveRecord in the transaction); `season.badge_fix` on a real closed season with sure merges (the plan's manual check: preview counts vs `check:season`, apply on a scratch copy, health re-run clearing `badges.duplicate.sure`), and its progress bar / Cancel under the `maintenance` worker in a browser; the local lookups and the checklist pages in a browser (request specs only, no system spec); `GET season/:id` against a live API (stubbed) and the release of a real held standard-timings script followed by a push; a real push after a release (the order is proven on `Outbox::PushPlan` only); a real partial apply of a season badge fix with the MariaDB client (the block runs use a stand-in).

## Rollback note

Each namespace switch is its own commit. Reverting one restores the original rake body, and its parity baseline still applies. Operations can be hidden with `operations.enabled`. `season_checklist_items` can be dropped. Scripts already in the Outbox stay valid, because they are ordinary numbered files.
