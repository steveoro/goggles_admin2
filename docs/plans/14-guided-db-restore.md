# Phase 14 — Guided local DB restore

## Goal

When the drift verdict (08) is red, let the operator replace the local development database with a production dump through a guarded wizard, so local again mirrors production, without losing the local-only state (API URL, sign-in, ops data) and without leaving half-finished work pointing at ids that no longer exist.

## Operator-visible outcome

- A "Restore local DB" action on `/db_sync` (and on the red drift inbox item) opens a wizard: preconditions checklist → dump choice and inspection → safety snapshot → typed confirmation → progress page → result.
- The progress page stays up while MySQL is dropped and reloaded; every other page shows "local DB restore in progress" instead of failing.
- Afterwards the operator is still signed in, the API target is still the one chosen, the Outbox has nothing pending, staging tables are empty, the drift pill turns green, and a history row records the run.

## Depends on

- 07: Outbox registry (precondition "Outbox clear"), `Ops::SqlScript` states, `LocalDb::Cli` / `LocalDb::SqlRunner`.
- 08: `Drift::Fingerprint`, `Drift::Verdict`, `DriftCheckJob`, `/db_sync`, `APICapabilities`, and the Outbox states 08 adds (`applied`, `failed`, `withdrawn`, `missing_remote`).

Softer links: 01 (ops DB, `Ops::Setting` `db_epoch`, `Ops.record_event!`, `Ops::Database.backup!(label: 'pre_restore')`); 05 (`DataFix::StagingPurger`, reused here, not extracted again). Jobs that must honour the lock come from 06 (`Health::SeasonRunJob`, `Health::SweepJob`, on the `maintenance` queue), 09 (`DataFixCommitJob` and the pipeline build job), 10 (`DataFixPrepareJob`, `SeasonBoard::PipelinePlanner`), 11 and 13 (`Maintenance::RunJob`, `maintenance` queue; 13 adds no new job class). Phase 14 adds the guard centrally in `ApplicationJob`; whichever of those phases has shipped is covered.

## Invariants that apply here

- `DbRestore::RestoreJob` (and the snapshot job) are enqueued only by a controller action from an operator click, retries disabled (spec-asserted).
- No admin2-only tables in MySQL: the session store, the lock and the restore history live in the ops DB, which a restore never touches.
- "Staging" = the `data_import_*` tables, purged after a restore. No staging-environment logic.
- Status surfaces (including the progress page) make no synchronous remote call and read only the ops DB.
- The wizard takes a dump already on disk; fetching it from production stays a manual step. Restoring production, test-DB rebuilds and engine upgrades stay in the terminal.
- Routine gate; `frozen_string_literal`, en+it keys, CHANGELOG + PATCH per user-visible step, `rubocop -a` clean; never a bare `db:prepare`/`db:migrate`.

## Facts (verified 2026-11-21 by reading)

- Sessions: `config/initializers/session_store.rb:6-8` uses `:active_record_store` (gem `activerecord-session_store` 2.3.0, `Gemfile:33`) on the MySQL primary, table `sessions` (`db/structure.sql:2140`). The production dump contains a `sessions` table, so a restore deletes the operator's session row.
- What a production dump overwrites locally (table list read from `goggles_main/db/dump/production-0426-FinCalabria.sql.bz2`, 115 tables, header `-- /app/db/dump/production.sql`): `sessions`; `users` (incl. `jwt`, unique index `db/structure.sql:2871`); `settings` + `app_parameters` (`framework_urls.api` becomes the production API URL; maintenance flag); `ar_internal_metadata` (`environment` becomes `production`, which makes Rails refuse destructive DB tasks); `schema_migrations`; `import_queues`, `active_storage_*`; all five `data_import_*` tables. Not touched: the ops, queue, cable and cache SQLite DBs, and files under `crawler/data`.
- Where dumps live: production dumps are made by `db:dump` inside the container into `/app/db/dump/production.sql.bz2`, which is `~/Projects/goggles_deploy/backups` on the server (`goggles_main/docker-compose.prod.yml:61,110,160`); the operator copies them by hand to `goggles_main/db/dump/production-NNNN-label.sql.bz2` (3 there, latest 2026-11-16, about 38 MB each, plus 9 `development-NNNN-*` snapshots). `goggles_admin2/db/dump` holds only `.keep`.
- Restore today: `db:rebuild from=<name> to=development` (goggles_db `lib/tasks/db_dump_rebuild_reset.rake:243-283`) bunzips into `tmp/`, drops and recreates the DB, then sources the file through the `mariadb` client; its dump folder is fixed to `Rails.root/db/dump` (:21). Dumps start with a transaction header and may carry the `/*M!999999\- enable the sandbox mode */` line (handled for old clients by `db:dump_remove_sandbox`, :368); the local client is MariaDB 11.8.
- Every request hits MySQL before any action: `ApplicationController` runs `app_settings_row` (AppParameter), `check_jwt_session` and Devise `authenticate_user!` (`app/controllers/application_controller.rb:12-20`).
- Staging purge exists only as a controller action: `DataFixController#purge` (`app/controllers/data_fix_controller.rb:15-37`).
- Solid Queue 1.7.2 supports `SolidQueue::Queue.find_by_name(name).pause/resume/paused?` (`app/models/solid_queue/queue.rb:12-29`); claimed jobs are `SolidQueue::ClaimedExecution`.

## Scope

New:
- `db/ops_migrate/<ts>_create_sessions.rb`, `<ts>_create_restore_runs.rb`
- `config/initializers/session_store.rb` (modified) + `app/models/ops/session_store_setup.rb`
- `app/models/ops/restore_run.rb`
- `app/services/db_restore/{lock,dump_catalog,dump_inspector,preconditions,preserver,loader,post_steps,snapshot}.rb`
- `app/jobs/db_restore/{inspect_job,snapshot_job,restore_job}.rb`
- `app/controllers/db_restore_controller.rb`, `app/controllers/concerns/db_restore_guard.rb`
- `app/views/db_restore/{new,inspect,confirm,show,result}.html.haml`, `app/views/layouts/restore.html.haml` (no MySQL access)
- `config/locales/db_restore.{en,it}.yml`, `docs/db_restore.md` (runbook incl. terminal fallback)
Modified: `app/controllers/application_controller.rb`, `app/jobs/application_job.rb`, `config/queue.yml` (only if the `maintenance` worker from 06 is missing), `config/routes.rb`, `/db_sync` view, `CHANGELOG.md`, `lib/version.rb`.

## Data model (ops migrations)

- `sessions` (ops): `session_id!` (string, unique index), `data` (text), `created_at`, `updated_at` (index). Same shape as the MySQL table so the gem's SQL works unchanged.
- `restore_runs`: `status!` (draft, inspecting, ready, snapshotting, confirmed, loading, post_steps, finished, failed, interrupted, cancelled), `step`, `dump_path`, `dump_sha256`, `dump_bytes`, `dump_taken_at`, `dump_schema_version`, `dump_tables json`, `dump_iq_next_id`, `snapshot_path`, `target_database`, `confirmations json` (ticks, typed name, discarded reviews), `preserved json` (API URL, operator user id; the JWT is stored only until re-applied, then cleared), `progress_bytes`, `log text` (capped), `error text`, `job_id`, `progress_token_digest`, `started_at`, `finished_at`, `user_id`. Index (status), (started_at).
- `Ops::Setting` keys: `db_restore.lock` (run id + since), `db_epoch` (bumped after each restore).

## `DbRestore::Lock` interface (other phases depend on it)

```ruby
DbRestore::Lock.active?          # true while a run is confirmed..post_steps (or interrupted)
DbRestore::Lock.current_run      # Ops::RestoreRun or nil
DbRestore::Lock.acquire!(run)    # ops transaction; raises if another run holds it
DbRestore::Lock.release!(run)
```
- Controllers: `DbRestoreGuard` is `prepend_before_action`-ed in `ApplicationController`, so it runs before `app_settings_row`; when active it renders the restore layout (503, link to the progress page) for HTML and 503 JSON otherwise. Skipped only by `DbRestoreController#show/status`.
- Jobs: `ApplicationJob` gets `around_perform` that, when `Lock.active?`, records an event (`Ops.record_event!`) and returns without running (recurring jobs simply run next time). Jobs enqueued by a click (`DataFixCommitJob`, `Outbox::PushJob`, `Maintenance::RunJob`) are also refused at enqueue by their controllers with a flash. `DbRestore::RestoreJob` is the only job exempt. A spec lists every class under `app/jobs` and asserts it inherits `ApplicationJob`.
- The lock is only in ops: if ops is unavailable the wizard refuses to start.

## Wizard steps and guards

| # | Step | Guard (refuses with the reason shown) |
|---|---|---|
| 0 | Entry `/db_restore/new` | `Rails.env.development?`; primary host is the local socket or `localhost`/`127.0.0.1`; database name is not the production one (`goggles`) and equals the development config; ops available; no other run active |
| 1 | Preconditions | Outbox: no `pending`, `held`, `pushing`, `sent` or `in_doubt` script (push or discard them first); `failed` scripts listed and marked discarded on confirm; no running push run; no claimed `DataFixCommitJob`, `Maintenance::RunJob` (11/13), `Health::SeasonRunJob` or `Health::SweepJob` (06); Data-Fix reviews in progress (sources with phase files in `results.new`, staging rows) listed and need an explicit "discard their staging rows" tick; queues `default`, `background`, `pipeline` and `outbox` paused by the wizard; `maintenance` is not paused because it serves the wizard's own jobs (its other jobs skip through the lock), but its claimed executions other than the wizard's are drained like the others (wait up to 10 min, then refuse) |
| 2 | Choose dump | `DbRestore::DumpCatalog` lists `*.sql.bz2` from configured folders (default `goggles_main/db/dump`, `goggles_admin2/db/dump`; editable in `Ops::Setting db_restore.dump_dirs`); only files whose name starts with `production`; size and mtime shown |
| 3 | Inspect (`InspectJob`) | `DumpInspector` streams `bzcat`: header line names a production dump; `bzip2 -t` integrity; table list includes the expected core tables; `schema_migrations` max version ≤ the local engine's newest migration (else refuse: "update goggles_db first, `./update_engine.sh`"); `import_queues` auto-increment read; dump older than the last `applied` Outbox script → warning listing the scripts that a replay would need (no automatic replay in v1) |
| 4 | Safety snapshot (`SnapshotJob`, optional, default on) | free disk space ≥ 3 × dump size; `mariadb-dump --single-transaction` of the current local DB to `goggles_main/db/dump/development-<NNNN>-pre-restore.sql.bz2` (same header/footer as `db:dump`); file non-empty; also `Ops::Database.backup!(label: 'pre_restore')` of the ops file |
| 5 | Typed confirmation | operator types the target database name; API target shown; a one-time progress token is generated (digest stored) |
| 6 | Load (`RestoreJob`, queue `maintenance`) | lock acquired; `Preserver` captures API URL (operator chooses: keep current or take the dump's), operator user id + JWT, session row needs nothing (ops); `Loader`: drop + create DB via `LocalDb::Cli`, stream `bunzip2 -c` into `mariadb` (sandbox line filtered if the client rejects it), progress by compressed bytes read, written to `restore_runs.progress_bytes` every 2 s |
| 7 | Post-steps (`PostSteps`) | set `ar_internal_metadata.environment = 'development'`; re-apply the preserved API URL and the operator's JWT; maintenance flag off; report pending engine migrations with the command to run (not run automatically); `DataFix::StagingPurger` (05; all sources, all five tables); mark the 09 verdicts stale (`db_epoch` bump); mark `Ops::RemoteWrite` rows before the dump date as covered; resume queues; release lock; `DriftCheckJob.perform_now(trigger: 'post_restore')`; `restore_runs` → finished; `Ops.record_event!` |
| 8 | Result | verdict shown; failure shows the snapshot file and the terminal command to load it |

Interrupted run (process died between 6 and 7): the lock stays `interrupted`; the progress page offers "Resume from load" (re-runs 6 and 7) or "Load safety snapshot". The lock is released only by finishing or by an explicit "Abandon" that requires the typed DB name.

Progress page: `GET /db_restore/:id?token=…` and `GET /db_restore/:id/status.json`, served by `DbRestoreController` with the restore layout, `skip_before_action` for `app_settings_row`, `check_jwt_session`, `authenticate_user!`; access requires a local request (`local_request?` from `APISession`) and the token. Reads only `Ops::RestoreRun`; polls every 2 s (no Cable dependency).

Terminal fallback (documented in `docs/db_restore.md` and shown on step 6): the wizard can stop after step 5 and print `cp <dump> goggles_main/db/dump/ && (cd goggles_main && bin/rails db:rebuild from=<basename> to=development)`; the operator runs it, then clicks "Load done, run post-steps", which runs step 7 after checking `schema_migrations` and the table list.

## Ordered steps

1. **Session store on the ops DB** (user-visible: one forced sign-in; CHANGELOG + PATCH). Ops migration `sessions`; in the initializer, after the ops DB is ready, `ActionDispatch::Session::ActiveRecordStore.session_class = ActiveRecord::SessionStore::SqlBypass` with `SqlBypass.connection_pool = Ops::ApplicationRecord.connection_pool` (the gem's SqlBypass takes a pool, `sql_bypass.rb:50-58`; `ActiveRecord::SessionStore::Session` itself cannot use `connects_to`). Fallback when ops is unavailable: keep MySQL. Request specs: sign-in, API-offline sign-in, sign-out, session survives a MySQL `sessions` truncate. The MySQL `sessions` table is left in place (it belongs to the engine schema). Cookie store rejected: `session[:commit_report]` can exceed 4 KB until 09 moves it to ops.
2. **Lock and guards** (not user-visible). `DbRestore::Lock`, `DbRestoreGuard`, `ApplicationJob` `around_perform`, enqueue refusals; (`DataFix::StagingPurger` comes from 05 and is reused as is.) Specs: a locked app returns 503 for a sample of controllers; each job class under `app/jobs` skips while locked.
3. **Catalog, inspector, preconditions** (user-visible: wizard steps 0-3 as a read-only check; CHANGELOG + PATCH). `restore_runs` migration; `DbRestoreController#new/create/inspect`; `InspectJob` on `maintenance`.
4. **Snapshot, confirmation, load, post-steps, progress page** (user-visible; CHANGELOG + PATCH). `SnapshotJob`, `RestoreJob` (`retry_on` none, `limits_concurrency key: 'local_db_writer', to: 1` (the key shared with `DataFixCommitJob` and `Maintenance::RunJob`)), `Loader`, `Preserver`, `PostSteps`, resume/abandon, terminal fallback, `/db_sync` entry, docs.

## Specs and manual verification

- `preconditions_spec.rb`: one example per refused precondition (non-development env, remote host, production DB name, ops missing, pending/sent/in_doubt script, running push run, claimed commit or maintenance job, reviews without tick, queues not drained, other run active).
- `dump_inspector_spec.rb` with a tiny bz2 fixture: header, schema version, table list, IQ auto-increment; refuses a non-production dump, a corrupt file and a schema newer than the local engine.
- `preserver_spec.rb` / `post_steps_spec.rb` against the test DB: API URL and JWT re-applied, `ar_internal_metadata` reset, staging empty, `db_epoch` bumped, remote writes covered, queues resumed, lock released.
- `loader_spec.rb`: command built as argv with the password in the environment; progress updates; an exception mid-load leaves the run `interrupted` and resume completes it (load stubbed).
- `restore_job_spec.rb`: `queue_as :maintenance`, no retries; enqueued only from `DbRestoreController#confirm` (scan spec).
- Request specs: progress page works with the MySQL primary disconnected (stub `ActiveRecord::Base.connection` to raise), refuses a wrong token or a non-local IP.
- Manual, once, on the operator's machine: point the development config at a scratch database name, restore `production-<latest>` with the snapshot on; the progress page stays up, the operator stays signed in, the badge shows the chosen API target, ops data (Outbox history, findings, events) is intact, the pill ends green. Then restore the real development DB the same way.

## Exit criteria

- One spec per refused precondition, all green.
- A restore into a scratch database keeps the progress page up, leaves ops data intact and ends "in sync".
- The operator stays signed in through a restore; other pages answer "restore in progress" instead of erroring; every job class skips while locked.
- An interrupted load can be resumed or rolled back to the safety snapshot from the UI.
- Routine gate after a restore: sign in → board → crawl → review → commit → report → push → confirm.

## Risks and mitigations

- Dropping the DB while the app runs → lock checked first in every controller and job; progress page reads only ops; queues paused and drained before the drop.
- Wrong target database → hard guards (env, host, name) plus typed name; the production config is never used.
- Dump newer than the local engine → refused at inspection.
- Dump older than scripts already applied remotely → warning with the list; v1 asks the operator to pick a newer dump (no automatic replay).
- Reviews holding ids of rows the restore removes → pending scripts block the restore; reviews need an explicit discard; staging purged; verdicts marked stale.
- Disk space (uncompressed dump about 10× the bz2) → streaming load, no uncompressed temp file; space check before the snapshot.
- Session move signs the operator out once → its own step with specs.
- Credentials → passed through the process environment only; never logged, never in `restore_runs.log`.

## Decisions to confirm

- Restore with unpushed scripts: strict block. Default: block.
- Dump folders: `goggles_main/db/dump` and `goggles_admin2/db/dump`, configurable. Default: both.
- Safety snapshot: on by default, can be skipped with a tick. Default: on.
- API URL after restore: keep the pre-restore value. Default: keep.
- Replay of scripts applied after the dump: not in v1 (warn and refuse to call the result "in sync"). Default: not in v1.
- Engine migrations after restore: reported, not run. Default: reported.

## Out of scope

Fetching dumps from production; restoring production; test-DB rebuilds; engine upgrades; automatic replay; removing the MySQL `sessions` table.

## Rollback note

Step 1 reverts by restoring the initializer (sessions return to MySQL; one more sign-in). Steps 2-4 are additive: removing the routes and the guard concern disables the wizard; ops tables can stay. A failed restore is rolled back by loading the safety snapshot (UI or terminal command printed on the result page).
