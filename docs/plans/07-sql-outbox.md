# Phase 07 — SQL Outbox

## Goal

Register every SQL script that changes the local DB, from any producer, in one ordered registry in the ops DB, and replace the Push file browser with one Outbox page that pushes scripts in local-apply order through a clicked background job.

## Operator-visible outcome

- `/outbox` lists every script waiting to be pushed, in global sequence order, with its kind (commit, calendar link, backfill, team manager, merge, fix, ...), folder, size, origin link and a SQL preview. No folder to pick.
- "Push next" / "Push all (N)" open a confirmation page naming the target URL and environment; the push runs as a job with live progress, stops on the first error and never skips a lower-numbered script without an explicit override.
- Season board "Push", the board header counter, the commit report and the inbox item open the Outbox focused on the right script.
- Terminal rake tasks land in the Outbox too (`results.new/misc/` for cross-season scripts); a script dropped by hand into `results.new` is adopted.
- After a push the script reads "sent, not verified"; when the remote queue row disappears it reads "executed, outcome not reported". Applied/failed arrive in phase 08.

## Depends on

- 01: ops DB (`Ops::ApplicationRecord`, `Ops.safely`, `Ops::Event`, `Ops::Setting`, `lib/tasks/ops.rake`), system-spec harness.
- 04: shell, `Shell::Navigation` (this phase adds the Outbox entry and replaces Push), `Shell::APITarget`.
- 05: `Inbox::Registry` (this phase replaces the 05 `:pending_sql` source through `Inbox::Registry.replace(:pending_sql, <source class>)`, which takes a key and a class (05's interface), the class reading `Outbox::Summary.call`); background JWT rule (last signed-in admin's `users.jwt`, "sign in to refresh" when expired).

Softer links (not hard dependencies): 02 (`push#prepare` and the results.sent → results.done second push are already deleted; the port guess says only "production"/"unknown"); 06 (this phase moves the 06 `meeting_cancel` writer, `Health::MeetingCanceller`, onto `Outbox::Writer`; until 11 replaces it with `meeting.set_cancelled`); `Ops::Snapshot` comes from 01.

## Invariants that apply here

- `Outbox::PushJob` is enqueued only by `OutboxController#push` from an operator click; never by a scheduler, planner, callback or another job; retries disabled (spec-asserted). No bulk commit.
- Scripts are pushed in local-apply order (`seq`), never by file prefix alone.
- No admin2-only tables in MySQL: the registry lives in the ops SQLite DB. File conventions (`NNNN-<base>-lt4.sql`, `results.new/sent/done/<season>`) stay readable by `SeasonBoard::DiskIndex` and `SeasonBoard::Backfill`.
- No cross-DB atomicity: write MySQL and disk first, ops last; the Reconciler converges. Disk decides pending vs sent; the registry holds what disk cannot (remote id, target, outcome).
- Status surfaces make no synchronous remote call and render API-offline.
- "Staging" means the `data_import_*` tables; no staging-environment behaviour.
- Routine gate must keep passing; `frozen_string_literal`, en+it keys, CHANGELOG + PATCH bump per user-visible step, `bundle exec rubocop -a` clean. Never a bare `bin/rails db:prepare`/`db:migrate`: ops migrations run through `bin/rails ops:prepare`.

## Facts this plan is built on (verified 2026-11-21)

- Push is synchronous in the request: `app/controllers/push_controller.rb:98-116` (glob loop, stop on first error, redirect to the bare index at :115); success means `new.id > 0` (:198), then rename new → sent (:203-210).
- `FileCounter#compute_file_counter` (`app/controllers/concerns/file_counter.rb:30-44`) is per folder pair, string-max of the path, never reads results.done. The disk shows one global sequence: 421 scripts in `results.sent` (222=34, 232=6, 242=17, 244=1, 252=185, 262=69, goggle_cups=2, misc=107), highest prefix 0476.
- Five hand-rolled writers, all with `File.write`: `DataFix::CommitArchiver.finalize` (`app/services/data_fix/commit_archiver.rb:21`, name computed in `app/controllers/data_fix/commits_controller.rb:74-81`), `SeasonBoard::CalendarLinker#write_sql_file` (`app/strategies/season_board/calendar_linker.rb:116-133`), `SeasonBoard::Backfill#write_sql_file` (`app/strategies/season_board/backfill.rb:410-417`), `TeamManagerSqlCreate#write_sql_file` (`app/strategies/team_manager_sql_create.rb:139-148`), `process_sql_file` (`lib/tasks/merge.rake:552-567`, used by merge, fix, purge, recompute, check, normalize, import_categories rakes), plus the direct write in `lib/tasks/import_standard_timings.rake:144-146` (`000-<season>-standard_timings.sql` at the results.new root, never applied locally).
- The rake counter `auto_index_from_script_output_dir` (`lib/tasks/merge.rake:574-577`) reads only `results.new[/subdir]/*.sql`. `process_sql_file` writes first and applies locally only with `simulate=0` (via `execute_sql_file`, `lib/tasks/db.rake:55-81`, which interpolates the DB password on the command line and calls `exit 1` on failure, leaving the written file pushable).
- Phase 6 order today: `Import::Committers::Main#commit_all` commits its own MySQL transaction (`app/strategies/import/committers/main.rb:109-142`), then `CommitArchiver.finalize` writes the SQL and moves files (`commits_controller.rb:112-120`). A failure in `finalize` is reported as "Phase 6 commit failed" although the local DB is already committed and the script may not exist.
- `SeasonBoard::DiskIndex` treats any `NNNN-*.sql` in a season folder as a source script except backfill/calendar-link names (`app/services/season_board/disk_index.rb:31,34,173-183`); `RowFlags` sets `pushed` from `sql_sent_paths` (`row_flags.rb:71`); `StateResolver#rule_sql_pending` (`state_resolver.rb:80-85`).
- Links to the bare push index: `app/components/season_board/row_component.rb:104-105`, `app/views/season_board/index.html.haml:26`, `app/views/data_fix/commit_phase6_report.html.haml:11`, `app/views/home/_data_import.html.haml:28`, `app/views/push/_file_tabs.html.haml:5,10`; upload links in `app/views/file_list/_file_table.html.haml:1-13,100-106`.
- On-disk counts for the one-time import (read-only `find -L ... -name '*.sql' | wc -l`): `results.sent` 421, `results.new/old-subseeded` 15, `results.new/normalize` 1 (`0002-normalize_coded_names.sql`), `crawler/data/redo` 4 (0178, 0180-0182), `results.new` root 0, `results.new/misc` 0 (exists, empty). Not scanned: `results.done` 1 (`0000-252-standard_timings.sql`), `results.done.2024` 358, `results.done.2025` 551, `results.backup` 1, `results.old` 0. No two scanned scripts share content (sha256 check); duplicated prefixes exist (0035, 0037, 0180-0182, 0395).
- `config/queue.yml` serves only `default` and `background` today (06 adds `maintenance`); line 8: other queue names are never picked up. `spec/config/queue_names_spec.rb` is created in 06 and extended here.

## Scope

New files:
- `db/ops_migrate/<ts>_create_sql_scripts.rb`, `db/ops_migrate/<ts>_create_push_runs.rb`
- `app/models/ops/sql_script.rb`, `app/models/ops/push_run.rb` (state machine as plain methods with guard clauses; no new gem)
- `app/services/outbox/{writer,sequence,reconciler,kinds,pusher,summary,notifier}.rb`
- `app/services/local_db/{cli,sql_runner}.rb`
- `app/jobs/outbox/{push_job,import_legacy_job,remote_status_job}.rb`
- `app/controllers/outbox_controller.rb`; views `app/views/outbox/{index,show,push_new}.html.haml` (native Bootstrap 5)
- `app/components/outbox/{script_row_component,state_badge_component,push_confirm_component}.{rb,html.haml}`
- `app/javascript/controllers/outbox_controller.js` (live refresh, selection)
- `lib/tasks/outbox.rake` (`outbox:import [simulate=0]`, `outbox:reconcile`, `outbox:status`)
- `config/locales/outbox.en.yml`, `config/locales/outbox.it.yml`; `docs/outbox.md`

Modified:
- `app/controllers/concerns/file_counter.rb` (shim over `Outbox::Sequence`)
- `app/strategies/import/committers/main.rb` (`before_commit:` hook, see step 5), `app/controllers/data_fix/commits_controller.rb`, `app/services/data_fix/commit_archiver.rb`
- `app/strategies/season_board/{calendar_linker,backfill}.rb`, `app/strategies/team_manager_sql_create.rb`, the 06 "flag cancelled" writer
- `lib/tasks/{merge,db,import_standard_timings,normalize}.rake`
- `app/services/season_board/disk_index.rb` (+ `disk_index/entry.rb`), `app/components/season_board/row_component.rb`, `app/views/season_board/index.html.haml`, `app/views/data_fix/commit_phase6_report.html.haml`, the 05 inbox pending-SQL source
- `app/controllers/push_controller.rb` (reduced to a redirect), `app/views/push/*`, `app/views/file_list/_file_table.html.haml` (SQL branch removed), `config/routes.rb`
- `app/grids/import_queues_grid.rb` (`batch_sql` column; the API JSON already carries it)
- `config/queue.yml` (new `outbox` worker), `config/recurring.yml` (`outbox_remote_status`)
- `docs/season_board.md`, `CHANGELOG.md`, `lib/version.rb`

## Data model (ops migrations)

`sql_scripts`

| column | type | notes |
|---|---|---|
| seq | integer, not null | global local-apply order; unique index |
| rel_path | string, not null | under `crawler/data`, updated on moves; unique index |
| filename | string, not null | basename |
| folder | string, not null | `<season_id>`, `misc`, `goggle_cups`, `normalize`, `old-subseeded`, `redo` |
| season_id | integer | nil for cross-season |
| kind | string, not null | `Outbox::Kinds`: commit, calendar_link, backfill, team_manager, cancel_flag, merge, fix, purge, recompute, normalize, standard_timings, categories, check, goggle_cup, manual |
| sha256 | string, not null | content identity, index (not unique: identical content may legitimately reappear) |
| byte_size, file_mtime | integer, datetime | stat-only rescans |
| state | string, not null | see state machine |
| held_reason | string | `not_applied_locally`, `local_apply_failed`, `operator`, `legacy_folder` |
| applied_locally | boolean | nil = unknown (adopted files) |
| single_transaction | boolean | false when extra COMMITs or DDL are found |
| origin | json | producer, source_base, fin_event_id, meeting_id, calendar_id, rake task + args, commit report ref |
| target_api_url, target_env | string | set at push |
| remote_iq_id | integer | index |
| push_attempts | integer, default 0 | |
| pushed_at, remote_checked_at, resolved_at | datetime | |
| last_error | text | truncated 4 KB |
| changed_after_push | boolean, default false | |
| note | text | operator note (discard, archive) |

Indexes: (state, seq), season_id, kind, remote_iq_id.

`push_runs`: `user_id`, `target_api_url`, `target_env`, `script_ids json`, `status` (running, finished, stopped, aborted), `pushed_count`, `stopped_at_script_id`, `error text`, `override_order boolean`, `job_id`, `started_at`, `finished_at`. Index started_at.

Ops settings used: `outbox.last_seq` (sequence floor), `outbox.legacy_imported_at`.

## State machine (until 08)

```
  Writer / Reconciler (results.new)            Reconciler (results.sent, import)
        |                                              |
        v                                              v
  +-----------+  hold/release  +--------+         +-------------+
  |  pending  |<-------------->|  held  |         | legacy_sent |  (terminal, History)
  +-----------+                +--------+         +-------------+
        | PushJob: before POST                      archived, discarded, missing:
        v                                           terminal
  +-----------+  POST ok: rename to results.sent   +--------------------------+
  |  pushing  |----------------------------------->| sent ("not verified")    |
  +-----------+                                    +--------------------------+
     |  POST rejected (4xx/unreachable)                 | GET import_queue/:id -> null
     |  -> back to pending, last_error, run stopped     v
     |  stale > 10 min                             +--------------------------+
     v                                             | executed_unreported      |
  +-----------+  operator resolves                 | "executed, outcome not   |
  | in_doubt  |----> sent | pending | discarded    |  reported" (terminal)    |
  +-----------+                                    +--------------------------+
```

| From | Event | To | Guard |
|---|---|---|---|
| pending | hold | held | — |
| held | release | pending | `applied_locally` true, or operator ticks "push without local apply" |
| held (`not_applied_locally`) | "Apply locally" (`LocalDb::SqlRunner`) | pending, re-sequenced | runner success; failure → held `local_apply_failed` |
| pending | push run reaches it | pushing | no lower `seq` in pending/pushing/in_doubt unless held or override |
| pushing | POST returns `new.id > 0` | sent | file renamed into `results.sent/<folder>/` |
| pushing | POST rejected | pending | run stops |
| pushing | older than 10 min, no live run | in_doubt | never re-posted automatically |
| sent | remote row gone | executed_unreported | only after `pushed_at` + 5 min |
| pending, held | discard | discarded | note required; file moved to `results.new/discarded/` (not scanned) |
| any registered | file missing on rescan | missing | reappears → previous state |

Phase 08 adds `applied`, `failed`, retry and withdraw on top of `sent`.

## Ordered steps

1. **Ops tables and models** (not user-visible). Migrations, `Ops::SqlScript` (scopes `needs_push` = pending+held+pushing+in_doubt by seq, `on_server`, `history`), `Ops::PushRun`, `Outbox::Kinds` (name → kind regexps, e.g. `/-lt4\.sql\z/` commit, `/calendar_link-/`, `/season_board_backfill-/`, `/team_manager-/`, `/meeting_cancel-|calendar_cancel-/` (`cancel_flag`), `/merge_|season_fix/`, `/standard_timings/`; `single_transaction?` scan for >1 `COMMIT;` or `CREATE|ALTER|DROP|TRUNCATE`). Model specs.
2. **`Outbox::Sequence` + FileCounter shim** (not user-visible). `Outbox::Sequence.next!(data_root:)` runs one ops transaction (SQLite `BEGIN IMMEDIATE` acts as the cross-process mutex): `max(outbox.last_seq, registry max seq, highest integer prefix under results.new/**, results.sent/**, redo/) + 1`, stores it in `outbox.last_seq`, returns it. `current_max(data_root:)` reads only. `FileCounter#compute_file_counter(curr_dir, sent_dir)` keeps its signature and returns `current_max`, deriving `data_root` as the path prefix before `results.new` in `curr_dir` (so specs with a temp `data_root`, e.g. `spec/strategies/season_board/calendar_linker_spec.rb:7,38-41`, stay isolated). `auto_index_from_script_output_dir` returns `current_max + 1`. When ops is unavailable both fall back to the disk-only max. `%04d` stays.
3. **`Outbox::Reconciler` + one-time import** (user-visible only through `rake outbox:import`; CHANGELOG + PATCH). Scan roots exactly `crawler/data/results.new/**`, `crawler/data/results.sent/**`, `crawler/data/redo/`; never `results.done*`, `results.backup`, `results.old`, `results.new/discarded`. Stat-only unless size/mtime changed. Rules: unknown file in results.new → pending, kind inferred, `applied_locally: nil`, held `not_applied_locally` when the kind defaults to not applied (normalize, standard_timings); unknown in results.sent → legacy_sent; registered file moved by hand new → sent → legacy_sent + event; sent → new → pending with `changed_after_push` and a confirmation warning; pending file edited → re-hash; sent/legacy file edited → `changed_after_push`; gone → missing. `Outbox::ImportLegacyJob` / `rake outbox:import` (simulate by default) registers: 421 results.sent scripts → legacy_sent; 15 `results.new/old-subseeded` + 4 `redo` → archived (note "pre-Outbox leftover"); `results.new/normalize/0002-normalize_coded_names.sql` → held, `applied_locally: false`. Expected dry-run report: 421 / 19 / 1 / 0 pending. Runs on Outbox page load (throttled 30 s), before every push run, from `rake outbox:reconcile`, from the 05 dashboard refresh and from `rake ops:rebuild` (registered as `Ops::Rebuilders.register(:outbox, ...)`, 01's registry).
4. **`LocalDb::Cli` + `LocalDb::SqlRunner`** (not user-visible). Extract `execute_sql_file` from `lib/tasks/db.rake:55-81`: same `(echo 'START TRANSACTION;'; cat file; echo 'COMMIT;') | mariadb` wrapper, but via `Open3.capture3` with an argv array and the password in `MYSQL_PWD` (never on the command line), returning `Result(success?, stderr, duration)` instead of `exit 1`. `db:run` and `execute_sql_file` become thin callers; `db:run` also tells the registry (`Outbox::Writer.mark_applied_locally!(path)`).
5. **`Outbox::Writer` and commit durability** (user-visible; CHANGELOG + PATCH). `Outbox::Writer.write!(kind:, name:, sql:, folder:, season_id: nil, applied_locally: true, held: false, origin: {}, data_root: Outbox.data_root) -> Ops::SqlScript` (a script written with `held: true` starts in the held state) allocates `seq`, writes `results.new/<folder>/<%04d seq>-<name>.sql` atomically (tmp file + rename), hashes, inserts the row through `Ops.safely` (a missing row is later repaired by the Reconciler from the file). `sql` is written verbatim, so each producer's bytes stay identical. `Writer.discard!(script)` deletes file and row for callers whose MySQL transaction rolls back after the write. `Writer.mark_applied_locally!(path_or_script)` re-sequences a held script to the next `seq` (renaming its prefix while still in results.new) so it is pushed in local-apply order.
   Phase 6 (minimal change; the full commit runner is phase 09): add an optional `before_commit:` callable to `Import::Committers::Main#commit_all`, invoked inside `ActiveRecord::Base.transaction` after the `@stats[:errors]` check with the final SQL text (log + closing `COMMIT;`). `CommitsController#commit_phase6` passes a lambda calling `Writer.write!(kind: 'commit', name: File.basename(source_path, '.json'), folder: <season dir>, ...)`, so a failed write rolls the local commit back and no committed change exists without its script; the name computation at `commits_controller.rb:74-81` goes away. `CommitArchiver.finalize` stops writing SQL (drop `sql_full_path`/`sql_content`) and only moves files, purges staging rows and appends the log. A failure there yields the new report state **"committed, archiving failed"** (`session[:commit_report][:commit_state]` = `committed_archive_failed`, distinct from `failed`), shows the script link and a "Retry archiving" action (`DataFix::CommitsController#retry_archive`, idempotent: moves only files still in results.new). An `Ops::Event` is written for each outcome. Phase 09's `DataFix::CommitRunner` later carries over the `before_commit:` callable in `Import::Committers::Main#commit_all` and the `retry_archive` action.
6. **Switch the other producers, one commit each** (not user-visible except folders; CHANGELOG + PATCH on the rake step). `CalendarLinker` (kind `calendar_link`, still inside its transaction, `discard!` in the rescue), `Backfill` (kind `backfill`), `TeamManagerSqlCreate` (kind `team_manager`; its spec writes into the real `crawler/data/results.new/<season>` (`spec/strategies/team_manager_sql_create_spec.rb:10-13`): pass `data_root:` so the spec uses a temp dir), the 06 "flag cancelled" writer `Health::MeetingCanceller` (kind `cancel_flag`; it keeps writing `NNNN-meeting_cancel-<id>.sql` / `NNNN-calendar_cancel-<id>.sql` into `results.new/<season>/` through `Outbox::Writer.write!`, still inside its controller transaction with `discard!` in the rescue; phase 11 later replaces it with `meeting.set_cancelled`, which writes to `results.new/misc/`). `process_sql_file`: strips a leading `\d+-` from `file_name`, routes `subdir` that is a season id to that season folder and everything else (root, `normalize`) to `misc`, registers `applied_locally: !simulate`; with `simulate=0` it writes held, runs `LocalDb::SqlRunner`, then `mark_applied_locally!` (failure → held `local_apply_failed`, task exits non-zero). An explicit `index=` is kept as the file prefix only; `seq` is always allocated. `import:standard_timings` writes `results.new/<season>/NNNN-<season>-standard_timings.sql`, held `not_applied_locally`. `normalize:coded_names` lands in `misc`, held unless `simulate=0`.
7. **DiskIndex by kind** (user-visible: board counts; CHANGELOG + PATCH). `scan_sql_dir` asks the registry (`Ops::SqlScript.kind_for(rel_path)`, one query per build) and treats only `commit` scripts as source SQL; fallback when ops is unavailable: `-lt4`/`-l4` suffix. Non-commit scripts in a season folder join `board_sql_paths` (renamed `other_sql_paths`, alias kept), so a pending team-manager or merge script no longer creates an unmatched entry. `SeasonBoard::Backfill::SQL_FILE_REGEXP` already matches only `-lt4.sql` and stays as is.
8. **Outbox page, read-only** (user-visible; CHANGELOG + PATCH). Routes: `GET /outbox`, `GET /outbox/:id`, `POST /outbox/reconcile`, `POST /outbox/:id/{hold,release,apply_locally,discard,resolve}`. Sections: Needs push (by seq, blockers marked), On the server (sent, executed_unreported), History (collapsed: legacy_sent, archived, discarded, missing). Default filter `SeasonDefaults.default_season_id` + `misc`, but pending scripts of any folder are never hidden. `focus=<filename>` scrolls to and highlights a row. Live refresh: `Outbox::Notifier.ping` over `AppNotificationsChannel` + Turbo frame reload (same pattern as `SeasonBoard::Notifier`). Navigation registry: Outbox replaces Push. `GET /push/index` redirects to `/outbox`. After this phase `PushController` is redirect-only and inherits `ApplicationController`, no longer `FileListController` (phase 15 relies on this to delete `FileListController`). Repoint the five links; `link_action_path` for `:push` becomes `outbox_path(focus: File.basename(action[:sql_path]))`. The inbox pending-SQL source (05) is replaced via `Inbox::Registry.replace(:pending_sql, ...)` by a source that reads `Outbox::Summary.call` → `{ pending:, held:, in_doubt:, sent_unverified:, oldest_pending: Ops::SqlScript }`. Ops missing → a "run `bin/rails ops:prepare`" notice plus the disk-derived list.
9. **Push** (user-visible; CHANGELOG + PATCH). `config/queue.yml`: add a worker `queues: outbox, threads: 1, processes: 1` (with a comment; never `default`, reserved for quick jobs so the hourly watcher is not delayed, nor `background`, held up to 30 min by a crawl). `Outbox::PushJob` (`queue_as :outbox`, `limits_concurrency key: 'outbox_push', to: 1, duration: 2.hours`, `retry_on` none, `discard_on StandardError` after recording). `GET /outbox/push/new?ids[]=|scope=all_pending` → confirmation: ordered list, total bytes, target URL, environment from `Shell::APITarget` (port guess labelled "unverified"; 08 replaces it), reachability + maintenance flag + API version from a fresh `APIProxy.ping`, JWT validity. Unverified or non-production target: type the environment label to proceed. `POST /outbox/push` re-runs the Reconciler and the ordering guard, creates the `Ops::PushRun`, enqueues. `Outbox::Pusher` per script: re-hash (changed → stop), set `pushing` (persisted before the POST), `APIProxy.call(method: :post, url: 'import_queue/batch_sql', jwt:, payload: { data_file: File.open(path) })` with the clicking operator's `users.jwt` read at run time; on `new.id` store id, target, `pushed_at`, rename into `results.sent/<folder>/`, ping; otherwise `last_error = result.error_detail`, back to pending, run `stopped`. Unreachable or expired JWT aborts before the first POST. In-doubt rows show the remote import-queue grid link and three choices (mark sent with an id, return to pending, discard). Remove `push#upload`, `push/_file_tabs`, the `.sql` branch of `file_list/_file_table`; add the `batch_sql` column to `ImportQueuesGrid`; batch rows link to the Outbox entry by `remote_iq_id`.
10. **Vanished-row polling** (user-visible; CHANGELOG + PATCH). `Outbox::RemoteStatusJob` (queue `default`, recurring `outbox_remote_status` every 2 minutes in `config/recurring.yml`, also triggered by the Outbox page) returns at once when no script is `sent`; otherwise `GET import_queue/:id` per sent script with the stored admin JWT (expired → snapshot "sign in to refresh", no state change). Null body after 5 minutes → `executed_unreported`. Docs: `docs/outbox.md`, `docs/season_board.md` (Push action, folders).

## Specs and manual verification

- `spec/services/outbox/sequence_spec.rb`: temp data root with scripts in `results.new/262`, `results.sent/misc` and `redo/` → global max; 3- and 4-digit prefixes; `results.done` ignored; two threads allocate distinct numbers.
- FileCounter regression: `calendar_linker_spec`, `backfill_spec`, `team_manager_sql_create_spec` green with the shim; one example proves the first script in an empty season folder continues the global sequence.
- `writer_spec.rb`: golden files per producer (commit, calendar_link, backfill, team_manager, merge, standard_timings) byte-identical to the pre-change output; row has kind/folder/sha256; `discard!`; raise inside the producer transaction leaves neither file nor row; `mark_applied_locally!` re-sequences.
- `commits_controller` request spec: a stubbed failing `Writer.write!` rolls the local commit back (no `meetings` row) and reports `failed`; a failing `CommitArchiver.finalize` reports `committed_archive_failed` with the script registered; retry archiving completes.
- `reconciler_spec.rb`: one example per rule; second run changes nothing; excluded folders untouched. `import_legacy_job_spec.rb` on a fixture tree; manual dry run on the real `crawler/data` must print 421 legacy_sent, 19 archived, 1 held, 0 pending.
- `disk_index_spec.rb`: a pending `NNNN-team_manager-*.sql` or merge script in a season folder is counted as other SQL, not unmatched; a commit script still drives `sql_pending`; `state_resolver_spec`, `builder_spec`, `backfill_spec` unchanged and green.
- `pusher_spec.rb` (stubbed `APIProxy`): three scripts, the second rejected → first sent and moved, second pending with `last_error`, third untouched, run `stopped`; lower pending seq blocks a single push unless held or override; changed file stops the run; unreachable aborts before POST.
- `push_job_spec.rb`: `queue_as` is `outbox`, no retry, concurrency key; a stale `pushing` becomes `in_doubt` and is never re-posted. A spec scanning `app/` asserts `Outbox::PushJob.perform_later` appears only in `OutboxController`. Queue spec: every job's `queue_as` is served by `config/queue.yml`.
- `spec/requests/outbox_controller_spec.rb`: default season filter still lists a pending `misc` script; `/push/index` redirects; push without confirmation refused; unverified target needs the typed label. `spec/requests/push_controller_spec.rb` rewritten to the redirect.
- `remote_status_job_spec.rb`: no-op with nothing sent; null body → `executed_unreported`; expired JWT → unchanged.
- System journey (01 harness): commit a fixture meeting → report link → Outbox entry → push with stubbed API → "On the server".
- Manual: `rake merge:swimmer ... simulate=0` from a terminal lands in `results.new/misc/` and in the Outbox; a file copied by hand into `results.new/262/` appears after reload.

## Exit criteria

- A commit, a calendar link and a rake merge done in that order are listed and pushed in that order with one click.
- A script dropped by hand into `results.new` is adopted and pushable; `rake outbox:reconcile` reports no unknown file under the three scan roots.
- The one-time import matches the counts above; archive folders are untouched.
- A Phase 6 commit never reports success without a registered script; "committed, archiving failed" is shown as its own state.
- Board and backfill specs unchanged and green; the board "Push" action opens the row's script.
- No job pushes without an operator click (spec); `/push/index` redirects.
- Routine gate: sign in → board → crawl → review → commit → report → push (from the Outbox) → confirm ("sent, not verified", then "executed, outcome not reported").

## Risks and mitigations

- Ops and MySQL cannot share a transaction → producers write inside their MySQL transaction exactly where `File.write` ran; `discard!` in rescue; Reconciler repairs a missing row.
- Crash between a successful POST and the local update → `pushing` persisted first; stale rows become `in_doubt`, never auto re-posted (explicit-id INSERTs would fail, UPDATE-only scripts would apply twice).
- Re-sequencing held scripts renames files the operator may know by number → only while in results.new, logged as an event.
- Season filter hiding a lower pending script → pending scripts are always listed; "push all" is always the global queue.
- Specs or rake writing into the real `crawler/data` → every producer takes `data_root:`; a spec guard fails when a test writes under `Rails.root/crawler/data`.
- Ops DB missing → Outbox shows disk-derived states and the setup notice; Writer still writes the file.

## Decisions to confirm

- Stray scripts (old-subseeded 15, redo 4): archived, never pushed. Default: archived.
- `normalize/0002` and new not-applied-locally scripts: held until "Apply locally" or an explicit "push without local apply". Default: held.
- sha256 indexed but not unique; `rel_path` unique. Default: as stated (the master plan calls sha256 the natural key; moves are still tracked by it).
- Held scripts re-sequenced (and renamed) when applied locally. Default: yes.
- Pushing to an unverified or non-production target: allowed behind the typed label. Default: allowed.
- `executed_unreported` delay: 5 minutes after `pushed_at`. Default: 5.

## Out of scope

Applied/failed outcome, retry, withdraw, environment from the API (08); drift gate (08); commit as a job (09); maintenance operations from the UI (11); moving or renaming files already in `results.sent`; any change under `results.done*`.

## Rollback note

Each step is a separate commit. Reverting steps 8-10 restores `/push` (the files are still in `results.new/sent` with the same naming). Reverting steps 5-6 restores the `File.write` producers; scripts written meanwhile have normal names and remain pushable. The ops tables can be dropped with `ops:reset`; nothing in MySQL changes in this phase.
