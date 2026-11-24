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

## Outcome (done, 0.10.86, 2026-11-23)

Delivered on `feature/modernize-admin-console-ux` together with phase 06 (one commit for both, implemented in parallel in the same working tree; steps 1-10). All six decisions confirmed with their defaults (archived leftovers, held not-applied scripts, sha256 indexed not unique, held scripts re-sequenced on local apply, unverified targets behind a typed label, 5-minute `executed_unreported` delay). Broad non-system run (spec/requests, services, components, jobs, models, tasks, config, views, strategies, routing, helpers, channels, the BS4 and i18n ratchets): 3627 examples, 1 failure (the sidebar expectation of 06's new `data_quality` group, fixed by the coordinator; full suite then green); the new system journey `spec/system/outbox_spec.rb` green in light and dark, with the board, dashboard and shell system specs; rubocop clean on every touched file (except one line of 06's `spec/config/queue_names_spec.rb`), no new haml-lint offenses (the Outbox templates are lint-free). Dry run of the one-time import on the real `crawler/data`: **431 legacy_sent / 19 archived / 1 held / 0 pending** (451 files scanned): the plan's 421 date from 2026-11-21, the operator pushed 10 more commits in `results.sent/262` since (0477-0486, 79 files instead of 69); the other counts are unchanged. Notes for later phases:

- **Names as shipped**: ops tables `sql_scripts` (`Ops::SqlScript`, plus a `previous_state` column used by `missing` → previous state) and `push_runs` (`Ops::PushRun`, statuses `running finished stopped aborted`). Services `Outbox` (module: `data_root`, `data_root_for(path)`, `relative_path`, `season_id_for`, folder constants), `Outbox::{Kinds, Sequence, Writer, Reconciler, Summary, Notifier, Pusher}` as planned, plus `Outbox::ScriptActions` (hold / release / apply locally / discard / resolve, shared `move_to_sent!`), `Outbox::PushPlan` (confirmation data + ordering guard) and `Outbox::InboxSource`; `LocalDb::{Cli, SqlRunner}`; jobs `Outbox::{PushJob, ImportLegacyJob, RemoteStatusJob}`; `OutboxController` (+ redirect-only `PushController < ApplicationController`); components `Outbox::{ScriptRowComponent, StateBadgeComponent, PushConfirmComponent}`; `outbox_controller.js` (frame reload on `outbox-ping` / every 5 s while a run is live, selection, focus scroll); `pages/_outbox.scss`; rake `outbox:import [simulate=0]`, `outbox:reconcile`, `outbox:status`; `config/initializers/outbox.rb` registers `Ops::Rebuilders` `:outbox`. Routes: `outbox`, `outbox_script`, `new_outbox_push` (`/outbox/push/new`), `outbox_push`, `outbox_reconcile`, `{hold,release,apply_locally,discard,resolve}_outbox_script`, `data_fix_retry_archive`; `push_index` kept as the redirect, `push/upload` gone.
- **Writer contract**: `Outbox::Writer.write!(kind:, name:, sql:, folder:, season_id: nil, applied_locally: true, held: false, origin: {}, data_root:)` as in contracts.md, plus two optional keywords: `prefix:` (an explicit rake `index=`: file prefix only, `seq` always allocated) and `held_reason:`. A script written with `applied_locally: false` starts held (`not_applied_locally`). With the ops DB missing (or the insert failing) the file is written all the same and the call returns an `Outbox::Writer::UnregisteredScript` (same readers: `seq`, `rel_path`, `filename`, `absolute_path`, `persisted? == false`), not an `Ops::SqlScript`. The file is written with `File.write` to a dotted temp file then renamed (same bytes as every former producer; specs stubbing `File.write` keep working). `mark_applied_locally!` renumbers a held script only when a higher seq exists (a script written held and applied right away, as `simulate=0` does, keeps its number) and only renames an auto-numbered prefix while in `results.new` (event `outbox.resequenced`). `mark_apply_failed!` holds it with `local_apply_failed`. `Ops::SqlScript#absolute_path` resolves against `data_root` (set by the Writer/Reconciler; default `Outbox.data_root`).
- **Producers**: Phase 6 commit (`before_commit:` of `Import::Committers::Main#commit_all`, called inside the transaction after the error check with `(sql_log + ["\r\n--\r\n", 'COMMIT;']).join("\n")`; new readers `Main#meeting_id`, `Main#committed?`), `SeasonBoard::CalendarLinker`, `SeasonBoard::Backfill`, `TeamManagerSqlCreate` (new `data_root:`; its request spec stubs `Outbox.data_root`), `Health::MeetingCanceller` (06, switched last, kind `cancel_flag`, its own spec unchanged and green; a separate `meeting_canceller_outbox_spec.rb` covers the registration), `process_sql_file` (strips the leading number, numeric subdir → season folder, anything else → `misc`, kind inferred from the name or `kind:`, returns the script), `import:standard_timings` (`results.new/<season>/NNNN-<season>-standard_timings.sql`, held), `normalize:coded_names` (`misc`, kind `normalize`, held unless `simulate=0`). The producers keep the written script in an ivar and `discard!` it when their transaction fails after the write. No class includes `FileCounter` any more: the shim stays (global `current_max` of the folder's data root) and can go in 15.
- **Commit durability**: `CommitArchiver.finalize(source_path:, lt2_source_path:, phase1_path:, phase_paths:, log_full_path:)` no longer writes SQL, is idempotent (moves only existing files, reads the season id from the archived phase 1 file after a partial run) and returns `{ season_id:, done_dir:, moved: }`. `session[:commit_report]` gains `commit_state` (`committed`, `committed_archive_failed`, `failed`), `archive_error`, `script_id` (`commit_success` is true only for `committed`). Events: `datafix.committed` (now with `link_path` to the Outbox script), `datafix.commit_failed`, `datafix.archive_failed` (warning), `datafix.archived` (retry). Phase 06's `enqueue_health_runs(season_id:, commit_state:)` sits on the success path of the same action. `DataFix::CommitsController#retry_archive` skips `set_source_path` and accepts only a JSON path under a `results.new` folder.
- **Kinds** (`Outbox::Kinds.infer`): name rules in order `cancel_flag`, `calendar_link`, `backfill`, `team_manager`, `standard_timings`, `normalize`, `categories`, `check` (`fix_dup_results-`), `merge` (`merge_`, `season_fix`, `dedup_`, relay badge fixes), `fix` (`fix_`, `datafix`), `purge`, `recompute`, `commit` (`-lt4.sql`, `-l4.sql` or a dated `NNNN-YYYY-MM-DD-` name), else `manual`; `goggle_cups` folder → `goggle_cup`. `DiskIndex` asks `Ops::SqlScript.kinds_for` once per build; unregistered files (or no ops DB) fall back to `BOARD_SQL_REGEXP` (06's regexp, kept) → other, then `Kinds.commit_name?` → commit. `other_sql_paths` with `board_sql_paths` kept as alias (the snapshot payload key stays `board_sql_paths`). `DiskIndex::Entry` did not need changes.
- **Reconciler** as planned, with: legacy rows (`legacy_sent`, `archived`) get the lowest free seq numbers in prefix order (they only sort the history), new pending/held rows `Sequence.next!` in prefix order; unknown files in `redo/` or `results.new/old-subseeded/` are held `legacy_folder` by a regular run and archived by the import (also when a regular run registered them first); simulate mode works without the ops DB (empty registry); plan first (hashing outside the lock), then one ops transaction. "Dashboard refresh" = `DashboardController#needs_you` calls `Reconciler.call_throttled(data_root: context.data_dir)` (30 s, setting `outbox.reconciled_at`), not a job.
- **Push**: confirmation always asks the typed label in 07 (`PushPlan#verified?` is false: the port guess is never verified; 08 changes `verified?`/`environment`). `OutboxController#push` refuses without `confirmed=1`, while a run is live, with an invalid JWT, when blocked without override, or with a wrong label; it re-runs the Reconciler first. `Outbox::Pusher` preflight: user + JWT (`Pusher.jwt_valid?`, same check as `APISession#valid_jwt?`), fresh ping of the run's target (unreachable → `aborted`), then every `pushing` row left by an older run becomes `in_doubt` (one run at a time, so none can be live; the Reconciler applies the 10-minute rule otherwise). POST timeouts 10/300 s, `base_url:` = the run's target. Events `push.uploaded` / `push.failed` (same kinds as before; `PushEventRecorder` deleted) and `outbox.push_{started,finished,stopped,aborted}`. Worker `outbox` (1 thread, 1 process) in `config/queue.yml`; `spec/config/queue_names_spec.rb` (06's) extended with the queue and the three jobs.
- **Remote status**: `Outbox::RemoteStatusJob` (default queue, `outbox_remote_status` every 2 minutes, `limits_concurrency` with discard, also enqueued by the page through `enqueue_if_due` at most every 2 minutes) checks only scripts pushed to the configured API URL, 50 per run, with `Ops::BackgroundCredentials.jwt`; a 2xx blank/null body → `executed_unreported`; 401 or no JWT → snapshot `outbox.remote_status` `no_credentials` ("sign in to refresh"), unreachable → `unreachable`; no state change in both.
- **UI**: navigation item `:outbox` (`fa-paper-plane`, `match: %w[outbox push]`, `offline_ok: true`: index, show and the local actions work in an API-offline session; push confirmation/push do not); the navigation spec's offline list now includes `:outbox`. `ActionPaths.link_path(:push)` → `ActionPaths.outbox_focus_path(sql_path)` (`/outbox?focus=<filename>`); 06's health links (`Health::FindingLinks.push_path`, `health/_cancelled_notice`) were repointed to `outbox_focus_path` / `outbox_path(focus:)` by the coordinator. Board header counter → Outbox focused on the first script. Commit report: "Open the Outbox" button and script link (BS5 markup inside the still-BS4 data_fix view). `ImportQueuesGrid`: `batch_sql` column and an "Outbox" link column (`ImportQueuesGrid.outbox_scripts`, set by the controller from the domain). Inbox: `Outbox::InboxSource` in the `pending_sql` slot (`Inbox::Registry.replace`, the 05 `Inbox::Sources::PendingSql` stays registered first and is the no-ops-DB fallback, now linking the Outbox); items `pending_sql` (push band), `outbox_in_doubt` (failed band), `outbox_held` (notice, only when nothing is pending). Compat: `push` dropped from the `.card` overflow list, `app/views/outbox` + `app/components/outbox` in `SWEPT`, `app/views/file_list` baseline 15 → 12, `app/views/push/` deleted. Removed locale keys `data_import.push.*`, `data_import.file.{btn_process_sql_tooltip,confirm_push}`, `shell.nav.push`; new `config/locales/outbox.{en,it}.yml` (also `ops.events.outbox.*` and `ops.events.datafix.{archive_failed,archived}`), `inbox.pending_sql.{held,held_only,in_doubt,resolve,open}`.
- **For 08**: add `applied` / `failed`, retry and withdraw on top of `sent` (the outcome read belongs in `Outbox::RemoteStatusJob#check`, which today only knows "row gone"); replace `PushPlan#environment` / `#verified?` with the API-reported environment (the typed label then applies only to unverified or non-production targets); the drift gate (`Drift::Gate.check(scope: :push)`) belongs in `OutboxController#push` before the run is created and in `Pusher#preflight!`.
- **For 09**: carry over the `before_commit:` callable of `Main#commit_all` and the `retry_archive` action (route `data_fix_retry_archive`) into `DataFix::CommitRunner`; the report states are the `commit_state` values above; `Main#committed?` tells a real commit from a rollback when something fails after the COMMIT.
- **For 11 / 13**: call `Outbox::Writer.write!(kind:, name:, sql:, folder: 'misc', applied_locally:, origin:)`; to apply locally use `LocalDb::SqlRunner.call(path:)` then `Outbox::Writer.mark_applied_locally!` / `mark_apply_failed!` (or `Outbox::ScriptActions.apply_locally!`); add new kinds to `Outbox::Kinds::ALL` (and a name rule if files may appear without the Writer). `Health::MeetingCanceller` is on the Writer already (kind `cancel_flag`, `results.new/<season>/`).
- **For 14**: `bin/rails ops:rebuild` re-registers the Outbox from disk (`:outbox`); after a restore the sequence floor `outbox.last_seq` and the registry stay as they were (only the MySQL side changes); `Outbox::PushJob` must be covered by the `DbRestore` guard through `ApplicationJob`.
- **For 15**: `PushController` no longer inherits `FileListController`; `file_list/_file_table` has no SQL branch any more; `FileCounter` has no user left.
- **Spec guard**: `Outbox.guard_test_path!` (test environment only) makes `Outbox::Writer` writes, `Outbox::ScriptActions` file moves and non-simulated `Outbox::Reconciler` runs raise on the real `crawler/data` (`spec/services/outbox_test_guard_spec.rb`); every producer touched here takes `data_root:` and its specs use temp dirs (or stub `Outbox.data_root` / `SCRIPT_OUTPUT_DIR` / `SeasonBoard::Backfill::DEFAULT_DATA_ROOT`). It does not cover writers outside the Outbox. Found while adding it: `spec/tasks/ops_rake_spec.rb` (non-transactional, stubbed temp ops DB config) ran every registered rebuilder, so the new `:outbox` one read the real `crawler/data` and its rows went to the shared `db/ops/test.sqlite3` (the `Ops::*` models keep their boot-time connection: only `Ops::Database` sees the stubbed config); the `ops:rebuild` examples now unregister the app's rebuilders around each example, and the stray rows were deleted from the test ops DB. Later phases registering rebuilders or using `use_temp_ops_db` with model queries should keep this in mind.
- **Not done**: no `SystemStatus::OutboxProbe` pill (not in the plan; docs/dashboard.md has the example); `ops:status` does not list the new tables (`outbox:status` does).
- **Not verified by hand** (starting the dev server runs the recurring jobs against FIN and the configured API, and pushing must never happen from a test session): the real import (`simulate=0`) and `outbox:reconcile` on the real data, a real push and the remote status polling against a live API, the 5 s live refresh and the `outbox-ping` broadcast in a real browser session, "Apply locally" against the real local DB, a `rake merge:* simulate=0` landing in `results.new/misc/`, a file copied by hand into `results.new/262/` appearing after reload (covered by specs on temp dirs only).

## Rollback note

Each step is a separate commit. Reverting steps 8-10 restores `/push` (the files are still in `results.new/sent` with the same naming). Reverting steps 5-6 restores the `File.write` producers; scripts written meanwhile have normal names and remain pushable. The ops tables can be dropped with `ops:reset`; nothing in MySQL changes in this phase.
