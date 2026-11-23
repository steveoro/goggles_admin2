# Phase 08 — Remote loop closure + drift indicator

## Goal

Make the remote executor safe and observable so a pushed script ends "applied" or "failed" with the server's error text, let the API say which environment it is, and show whether the local DB still mirrors production (count and max id per table), with a gate before local commits and pushes. Cross-project: goggles_main and goggles_api change; goggles_db does not.

## Operator-visible outcome

- Outbox rows move from "sent" to **applied** or **failed** (MariaDB error text shown), with Retry and Withdraw actions; scripts behind a failed one stay queued and are marked "blocked by #NNNN".
- The top-bar API badge shows the environment reported by the API (`production`, `development`); the port guess stays only as fallback, labelled "unverified".
- A DB sync pill (green / amber / red / unknown) in the shell and dashboard, and a `/db_sync` page explaining each table difference, admin2's own remote writes, and the last checks.
- Phase 6 commit is refused on red (link to `/db_sync`); the push confirmation shows the verdict.

## Depends on

- 07: Outbox registry, `Outbox::RemoteStatusJob`, `Outbox::Pusher`, `push_runs`, `LocalDb::SqlRunner`.

Softer links (reached through 07's own dependencies): 05 (`Ops::RemoteWrite` hooked into `APIProxy.call`, the `drift_v0` snapshot that `Ops::DbFingerprint` rows replace here, background JWT rule, `Inbox::Registry`); 04 (`Shell::APITarget`, `SystemStatus::Probe` registry, the `api.status:<base_url>` snapshot key whose payload this phase extends with `environment` and `capabilities`); 01 (`Ops::Snapshot`).

## Invariants that apply here

- Push, commit, apply and restore jobs are enqueued only by a controller action from an operator click, retries disabled; this phase adds no such job. `DriftCheckJob` and `Outbox::RemoteStatusJob` only read.
- Scripts pushed in local-apply order; the server now also runs them in id order and stops at the first failure.
- Dashboard and status surfaces make no synchronous remote call: drift values shown in the UI come from `Ops::DbFingerprint` rows, never `Rails.cache` (Solid Cache exists only in development; test uses the null store).
- No admin2-only tables in MySQL; no goggles_db migration.
- "Staging" = `data_import_*` tables. No staging-environment logic, no staging port.
- Timestamps are never compared for equality: generated scripts write `NOW()` (`app/strategies/sql_maker.rb:85,122`). Compare count and max id; remote `max_updated_at` is compared only with the time of the last applied script.
- Routine gate; repo conventions in each of the three repos.

## Facts (verified by reading; nothing executed)

goggles_main `app/jobs/import_processor_job.rb` (by reading, **not executed**):
- `perform` (:37-43) takes the SQL branch whenever any `batch_sql` row exists, so micro-transaction rows (users' chrono recordings) are not processed while any batch row is present.
- `exec_sql` marks the row `done: true` before running (:51); raises on failure (:81); passes the DB password on the command line (:72-73); writes the temp file into `db/dump/` (:63), which in production is the backups volume (`goggles_main/docker-compose.prod.yml:61,110,160`).
- `handle_macrotransaction_batch_row` (:110-126) toggles maintenance with no `ensure`: a raise at :81 leaves maintenance on, and the next run sees `maintenance_was_on` and never turns it off (inference). Every run deletes all done rows first (:116-119), failed ones included; batch rows iterate with no ORDER BY (:120).
- `handle_microtransaction_row` deletes **all** done rows (:132), batch rows included.
- Scheduled every 3 minutes (`config/recurring.yml` `import_processor`, queue `iq`); worker `queues: "*"`, 3 threads (`config/queue.yml`); `ApplicationJob` has no retry/concurrency limit. Overlap of two runs on a long script is an inference (not executed).

goggles_api:
- `GET status` returns only `msg` and `version` (`app/api/goggles/api.rb:59-77`; `entities/status_entity.rb:7-8`).
- `POST import_queue/batch_sql` stores the attachment, returns `{ msg, new: { id } }` (`import_queues_api.rb:162-186`; :141-144 says it cannot validate).
- `GET import_queue/:id` returns the model's `to_hash`/`to_json` (goggles_db `application_record.rb:94-114`), not the entity; null body when not found (:37-43). `PUT import_queue/:id` has no `error_messages` param (:60-75). The list (:244-262) has no `batch_sql` filter and `done=false` is dropped by `filtering_hash_for`'s `blank?` (`api_helpers.rb:96-107`).
- `tools/latest_updates` returns newest rows of 12 tables, no counts or max ids (`tools_api.rb:251-285`).
- Every JWT call increments API daily-use counters (`api_helpers.rb:36-49`).
- Docs: the API Blueprint folder was removed; documentation is Swagger from entity annotations and `desc` blocks (`goggles_api/README.md:31`, `add_swagger_documentation` in `api.rb:122`).
- ActiveStorage `blob.checksum` is a base64 MD5; that is what `data_file_checksum` exposes.

## Endpoint payloads

`GET /api/v3/status` (public, unchanged keys plus two):
```json
{ "msg": "OK", "version": "C7-0.10.73-2026MMDD", "environment": "production",
  "capabilities": ["iq_batch_outcome", "iq_batch_filters", "db_fingerprint"] }
```

`GET /api/v3/import_queue/:id` (admin) — existing `to_hash` plus, for batch rows:
```json
{ "id": 9123, "batch_sql": true, "done": false, "process_runs": 1,
  "error_messages": "ERROR 1062 (23000) at line 412: Duplicate entry ...",
  "data_file_name": "0477-2026-11-22-Trofeo_X-lt4.sql",
  "data_file_checksum": "q1w2e3...==", "data_file_byte_size": 245113,
  "created_at": "...", "updated_at": "..." }
```
Outcome encoding (no new column): queued = `done:false, error_messages:nil, process_runs:0`; running = `done:false, process_runs>0, error nil`; applied = `done:true, error nil`; failed = `done:false, error present`; gone = null body.

`GET /api/v3/import_queues?batch_sql=true&done=false` (admin): working Boolean filters, same row shape, `Total` header.

`PUT /api/v3/import_queue/:id` accepts `error_messages` (String, may be empty) alongside `process_runs`: retry in place = `{ "error_messages": "", "process_runs": 0 }`.

`GET /api/v3/tools/db_fingerprint[?tables=laps,relay_laps][&light=1]` (admin JWT, fixed whitelist, server cache 60 s per param set):
```json
{ "environment": "production", "generated_at": "2026-11-22T10:00:00Z",
  "schema_version": "20261027120100", "db_version": "2.10.12",
  "import_queue": { "next_id": 9124, "batch_queued": 0, "batch_failed": 0 },
  "tables": { "laps": { "count": 4120331, "max_id": 4188002, "max_updated_at": "..." } } }
```
Light mode: `tables.<name>` = `{ "max_id": n }` (PK index lookup only). Unknown table → 422 with `X-Error-Detail`. Whitelist (import-owned and user-touched): meetings, meeting_sessions, meeting_events, meeting_programs, meeting_individual_results, meeting_relay_results, meeting_relay_swimmers, laps, relay_laps, meeting_team_scores, swimmers, teams, team_affiliations, badges, calendars, swimming_pools, cities, managed_affiliations, standard_timings, category_types, users.

## Scope

goggles_main: `app/jobs/import_processor_job.rb`, `spec/jobs/import_processor_job_spec.rb`, `CHANGELOG.md`, `lib/version.rb`.
goggles_api: `app/api/goggles/api.rb`, `entities/status_entity.rb`, `entities/import_queue_entity.rb` (Swagger docs of the new fields), `import_queues_api.rb`, `tools_api.rb`, new `app/api/goggles/entities/db_fingerprint_entity.rb`, specs `spec/api/goggles/{api,import_queues_api,tools_api}_spec.rb`, `CHANGELOG.md`, `lib/version.rb`.
goggles_admin2:
- New: `app/services/api_capabilities.rb` (`APICapabilities`, `API` acronym inflection), `app/services/outbox/remote_status.rb`, `app/services/drift/{tables,fingerprint,verdict,gate}.rb`, `app/jobs/drift_check_job.rb`, `app/models/ops/db_fingerprint.rb`, `db/ops_migrate/<ts>_create_db_fingerprints.rb`, `db/ops_migrate/<ts>_add_outcome_to_sql_scripts.rb`, `app/controllers/db_sync_controller.rb`, `app/views/db_sync/show.html.haml`, `app/components/drift/indicator_component.{rb,html.haml}`, `config/locales/db_sync.{en,it}.yml`, `docs/db_sync.md`.
- Modified: `Ops::SqlScript`, `Outbox::RemoteStatusJob`, `Outbox::Pusher`, `OutboxController` + views, `Shell::APITarget`, `app/controllers/data_fix/commits_controller.rb`, `config/routes.rb`, `config/recurring.yml`, the inbox sources (push failed, drift red), `app/grids/import_queues_grid.rb` (`data_file_name`, `error_messages` excerpt), `CHANGELOG.md`, `lib/version.rb`.

## Data model (ops migrations)

- `sql_scripts`: add `remote_outcome_at` (datetime), `remote_error` (text), `withdrawn_at` (datetime); states gain `applied`, `failed`, `withdrawn` and `missing_remote` (on top of 07's pending, held, pushing, sent, in_doubt, executed_unreported, legacy_sent, archived, discarded, missing); `sent` now means "queued on the server".
- `db_fingerprints`: `taken_at!`, `trigger` (schedule, manual, gate, post_push), `mode` (full, light), `api_base_url`, `target_env`, `api_version`, `schema_version_local`, `schema_version_remote`, `local json`, `remote json`, `verdict!` (green, amber, red, unknown), `reasons json` (code + table + numbers, rendered through i18n), `pending_scripts_count`, `remote_writes_count`, `error text`. Index (taken_at), (verdict, taken_at). Keep the last 200.

## Ordered steps

1. **goggles_main: failing specs first** (not user-visible). In `spec/jobs/import_processor_job_spec.rb` add examples that encode the target behaviour, run them against the current job and record which fail (this turns the read-only findings into executed evidence): maintenance flag false after a failing script; two batch rows run in id order; a failed row is kept with `error_messages` and `done: false`; later rows are not run; a micro-transaction row is processed while a failed batch row exists; an applied row survives the next run. Factory: `import_queue_with_static_data_file` (goggles_db `spec/factories/goggles_db/import_queues.rb:40`).
2. **goggles_main: rewrite the job** (production-visible; CHANGELOG + version per repo). `perform` runs `process_batch_sql` then `process_microtransactions`, independently; a batch failure never prevents the micro path.
   - `process_batch_sql`: purge batch rows `done: true` with `updated_at < 14.days.ago` (attachment purge + delete, no maintenance toggle); if any batch row is failed (`done: false`, error present) → log "blocked" and return; a row with `done: false, process_runs > 0, error nil` was interrupted → set `error_messages: 'interrupted: outcome unknown'` and return; `rows = with_batch_sql.where(done: false).order(:id)`; return when empty (no maintenance window); otherwise toggle maintenance once (only if it was off) and restore it in `ensure`; per row: `process_runs += 1` before running, run, success → `done: true, error_messages: nil` (attachment kept until retention), failure → `error_messages: stderr.truncate(60_000)` and stop. No raise.
   - `process_microtransactions`: unchanged logic, but its cleanup becomes `without_batch_sql.deletable.delete_all` so retained or failed batch rows are never deleted.
   - `limits_concurrency key: 'import_processor', to: 1, duration: 30.minutes, on_conflict: :discard` (solid_queue 1.7.2 supports `on_conflict`); password through `MYSQL_PWD` in the `Open3.capture3` env; temp file in `Dir.tmpdir` instead of `db/dump`.
3. **goggles_api** (production-visible). Status keys; `data_file_*` merged into `to_hash` in the two import-queue GETs (no engine change); `batch_sql` and `done` filters handled in `import_queues_api.rb` with `params.key?` (local fix; `filtering_hash_for` is shared by every list endpoint, so it is not changed); `error_messages` on PUT; `tools/db_fingerprint` (`reject_unless_authorized_admin`, whitelist constant, `Rails.cache.fetch(['db_fingerprint', tables, light], expires_in: 60.seconds)`, schema version from `connection_pool.migration_context.current_version`). Swagger `desc`/entity docs.
4. **Release** (operator). goggles_api and goggles_main in one tag (`goggles_deploy/deploy/deploy_prod.sh:60-62` pulls both images with the same `TAG`); admin2 last. Before tagging: run the current admin2 Push flow against the upgraded local API + main job; the file is accepted, executed, and a broken script shows its error in `/api_import_queues`. Both CHANGELOGs state that a failed script now blocks later scripts until it is retried or deleted.
5. **admin2: capabilities and environment badge** (user-visible; CHANGELOG + PATCH). `APICapabilities.for(base_url)` reads the last `APIProxy.ping` result stored as `Ops::Snapshot` (key `api.status:<base_url>`), refreshed by the 04 ping snapshot job and by the push confirmation; `environment`, `capabilities`, `supports?(:iq_batch_outcome)`. `Shell::APITarget` shows the API's environment; mismatch with the operator label → warning; fallback "unverified" port guess.
6. **admin2: outcomes** (user-visible; CHANGELOG + PATCH). `Outbox::RemoteStatus.map(json)` → applied / failed / sent / running / gone. With `iq_batch_outcome`: failed → state `failed`, `remote_error`, file moved back to `results.new/<folder>/` (board row returns to "SQL to push"), inbox item "push failed"; applied → `applied`; gone → `executed_unreported` only without the capability, else `missing_remote` shown as "deleted on server". Actions: **Retry** (file unchanged: `PUT {error_messages: '', process_runs: 0}`, state `sent`; file edited: requires Withdraw first), **Withdraw the rest** (DELETE each later `sent` row that has not run, return them to `pending`; needed so a re-pushed fix keeps id order on the server), **Discard**. In-doubt rows (07) are resolved by listing `import_queues?batch_sql=true` and matching `data_file_checksum` with `Digest::MD5.base64digest(File.binread(path))`.
7. **admin2: drift** (user-visible; CHANGELOG + PATCH). `Drift::Tables` (whitelist, `COMMIT_TABLES` = tables `Import::Committers::Main` inserts into, owner class: import-owned vs user-touched). `Drift::Fingerprint.local(tables:, light:)` runs `COUNT(*)`, `MAX(id)`, `MAX(updated_at)` locally; `.remote(...)` calls the endpoint with the stored admin JWT. `Drift::Verdict.call(local:, remote:, outbox:, remote_writes:)`:
   - green: count and max id equal; or "local ahead by N" when scripts are pending/sent and remote max id ≤ local on every table;
   - amber: count differs with equal max id; `Ops::RemoteWrite` rows since the last green; remote `max_updated_at` later than the last applied script; fingerprint older than 2 h; non-blocking unknowns;
   - red: remote max id > local on an import-owned or user-touched table admin2 inserts into (collision risk, e.g. laps added by users); any `failed` script, or a failed script with `single_transaction: false` ("may be partially applied"); schema version mismatch;
   - unknown: API unreachable, JWT expired, or no `db_fingerprint` capability.
   `DriftCheckJob` (inherits `ApplicationJob`; queue `default`, recurring `drift_check` every 30 minutes, plus "Check now" on `/db_sync`, plus after each push run) stores an `Ops::DbFingerprint`; the `drift_v0` snapshot from 05 is no longer written. Navigation: this phase adds the "DB sync" item to `Shell::Navigation`. `Drift::IndicatorComponent` (pill) reads only the last row. `/db_sync`: per-table local/remote/diff, reasons, remote writes since the last green, history.
8. **admin2: gates** (user-visible; CHANGELOG + PATCH). See interface below. `CommitsController#commit_phase6` calls `Drift::Gate.check(scope: :commit, acknowledged: params[:drift_ack] == '1')` before building `Import::Committers::Main`; block → redirect to the review page with a flash linking `/db_sync`; warn → the commit button posts again with the tick. The push confirmation renders the verdict; `OutboxController#push` re-checks with `scope: :push` (red warns and needs the tick: the server now stops and reports a colliding script).

## `Drift::Gate` interface (phases 09, 10, 11 depend on it)

```ruby
result = Drift::Gate.check(scope:, acknowledged: false, force: false, tables: nil)
# scope: :commit | :push | :prepare | :operation | :board_write | :rake
result.level        # :ok | :warn | :block
result.allowed?     # ok, or warn && acknowledged, or force (rake only)
result.verdict      # Ops::DbFingerprint used (fresh light check if the last one is > 10 min old)
result.reasons      # Array of { code:, table:, local:, remote: }
```
Unknown (API unreachable / no capability) is `:warn` for every scope. Red is `:block` for `:commit`, `:operation`, `:prepare`; `:warn` for `:push` and `:board_write`. `:rake` blocks on red unless `force=1`.
- Phase 09 (`DataFix::CommitRunner` / `DataFixCommitJob`): keep the controller call above (moved into the runner's enqueue action) and call it again inside the job with the operator's acknowledgement passed as a job argument; block → report state `refused_drift`.
- Phase 09 calls the gate in the commit controller action and again at `DataFixCommitJob` start with the stored `acknowledged` flag; phase 10's `DataFixPrepareJob` calls `scope: :prepare`.
- Phase 10 (`DataFixPrepareJob`): `Drift::Gate.check(scope: :prepare)`; block → skip the build, verdict `blocked` with reason `drift_red`, one inbox item; warn → build and annotate the verdict.
- Phases 11 and 13 (`Maintenance::Executor` apply): `Drift::Gate.check(scope: :operation, acknowledged: <the operator's tick stored on the run>)` before planning the apply; dry runs do not call it. 13's rake callers use `scope: :rake`.
- Board link/backfill (`SeasonBoardController`, `rake season_board:backfill`): `scope: :board_write` / `:rake`, from this phase.

## Specs and manual verification

- goggles_main: the step-1 examples green after step 2, plus interrupted row, retention, maintenance untouched when already on, concurrency key present, micro path never deletes batch rows.
- goggles_api: `api_spec.rb` (status keys), `import_queues_api_spec.rb` (new fields on batch rows, `done=false` and `batch_sql=true` filters, PUT clears `error_messages`), `tools_api_spec.rb` (admin only, whitelist rejection, light mode keys only, cache hit).
- admin2: `remote_status_spec.rb` (each mapping; without capability a vanished row is `executed_unreported`); `outbox_controller_spec.rb` (retry in place, withdraw order); `verdict_spec.rb` table-driven (equal → green; pending + remote ≤ local → green-ahead; remote laps max id above local → red; recorded remote write → amber; failed script → red; no capability → unknown); `gate_spec.rb` per scope; commits request spec: red blocks with the `/db_sync` link, unreachable + tick proceeds; `fingerprint_spec.rb` local aggregates; component spec renders from the stored row with the API stubbed unreachable.
- Manual, development API (goggles_api + goggles_main running locally): push a fixture script with a duplicate-key INSERT → "failed" with the MariaDB error; a script behind it stays queued; maintenance off; a micro-transaction row is processed meanwhile; fix + withdraw + push → "applied". Measure full fingerprint time on a local production dump before fixing the 30-minute schedule.

## Exit criteria

- On a development API a failing fixture script shows "failed" with its error, later scripts are not run, maintenance mode is off afterwards and a micro-transaction row is still processed; a good script shows "applied".
- The environment badge matches the API's own answer; admin2 still works (07 behaviour, "unverified" label) against an API without the new capabilities.
- Drift pill and `/db_sync` render with the API offline from stored rows; a red verdict blocks the Phase 6 commit.
- No goggles_db migration was needed (if one is, stop and re-plan with the engine update procedure).
- Routine gate: sign in → board → crawl → review → commit (gate green) → report → push → confirm "applied".

## Risks and mitigations

- Blocking on a failed script changes production behaviour → admin2 deployed right after the server tag; the failed row is visible and deletable in the existing grid; both CHANGELOGs say so.
- Job defects confirmed only by reading → step 1 specs decide before behaviour changes.
- `COUNT(*)` on large tables in a small container → light mode for gates, 60 s server cache, 30-minute schedule, admin only.
- Count and max id miss remote UPDATEs → `Ops::RemoteWrite` logs admin2's own writes; `max_updated_at` vs last applied time; documented limit, restore wizard (14) is the reset.
- Polling inflates API usage stats → polls only while scripts are `sent`; counted under their own route keys.
- Retained rows change the import-queue KPI → the 05 KPI counts unfinished rows only (`done=false`).

## Decisions to confirm

- A failed remote script blocks every later script. Default: block.
- Retention of applied batch rows on the server: 14 days. Default: 14.
- Red verdict on push: warn + tick (not block). Default: warn.
- Quick fix "raise local auto-increment above remote max id": not offered; restore (14) is the remedy. Default: not offered.
- Mirroring admin2's remote-only edits locally: record only. Default: record only.

## Mirror plan — goggles_api

- Files: as in Scope; one commit per endpoint change, specs alongside (`spec/api/goggles/*_api_spec.rb`, shared auth examples in `spec/support/shared_api_response_behaviors.rb`).
- Docs: Swagger annotations (`desc`, `success`, `failure`, entity `documentation:`); the API Blueprint folder no longer exists.
- Version: bump `PATCH`/`BUILD` in `lib/version.rb`, top entry in `CHANGELOG.md` (format `**0.10.NN** [author] ...`), aligned with goggles_main for the shared tag. `bundle exec rubocop` clean.

## Mirror plan — goggles_main

- Files: `app/jobs/import_processor_job.rb`, `spec/jobs/import_processor_job_spec.rb`; optionally `docs/production_containers.md` (outcome encoding, how to unblock a failed row).
- Version: `lib/version.rb` + `CHANGELOG.md` entry, same tag as goggles_api; `bundle exec rubocop` and `haml-lint` clean.

## Out of scope

Restore wizard (14); changing `filtering_hash_for` globally; any goggles_db change; staging environment and port 446.

## Rollback note

admin2 steps feature-detect, so the server can be rolled back independently (admin2 falls back to 07 states). Rolling back goggles_main restores the old job: failed rows (`done: false` + error) would then run again on the next cycle, so delete or resolve failed rows before downgrading. The ops migrations are additive.
