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

## Outcome (done, admin2 0.10.87 + goggles_api / goggles_main 0.10.81, 2026-11-23)

Implemented by two agents in parallel (server side in goggles_main + goggles_api, admin2 side against the "Endpoint payloads" contract), alongside phase 09 in the admin2 working tree. Step 4 (release) is the operator's: goggles_api and goggles_main are committed on their own `feature/modernize-admin-console-ux` branches, not tagged or deployed. Until they are deployed admin2 feature-detects and keeps the 07 behaviour; the DB sync verdict stays unknown, so every push and Phase 6 commit asks for the DB sync tick.

### admin2 (steps 5-8)

Delivered on `feature/modernize-admin-console-ux` (admin2 steps 5-8 plus the `Drift::Gate` interface; goggles_main / goggles_api steps 1-3 were done in parallel by another agent, to the "Endpoint payloads" shapes, and are reported separately). All five decisions confirmed with their defaults (a failed script blocks every later one; 14-day retention; red on push warns + tick; no auto-increment quick fix; remote-only edits recorded only). Everything feature-detects: against today's production API (no `environment`, no `capabilities` in `status`) admin2 keeps the 07 behaviour ("unverified" port guess, `sent` → `executed_unreported`), the DB sync verdict is `unknown` and every gate warns. Every spec stubs `APIProxy`; no remote call was made. Targeted runs green (see the report for the files and counts); rubocop clean on every touched file, no haml-lint offense in the new or touched templates. Notes for later phases:

- **Names as shipped**: `APICapabilities` (`.for(base_url)`, `#environment`, `#capabilities`, `#supports?(:iq_batch_outcome | :iq_batch_filters | :db_fingerprint)`, `#reported?`, `#version`, `#checked_at`; reads only the `api.status:<url>` snapshot); `SystemStatus::APISnapshot` payload gains `environment` and `capabilities` (nil when not reported; a sign-in answer keeps the previous ones, a `status` answer without them drops them); the push confirmation writes its fresh ping into that snapshot (source `push_confirm`). `Shell::APITarget#api_environment`, `#verified?`, `#environment` (API's own answer, else the port guess), `#capabilities`, `#label_environment`, `#label_mismatch?`; the badge carries `data-api-environment` / `data-api-verified`. `Outbox::PushPlan#environment` / `#verified?` delegate to the target (the typed label is asked only for an unverified or non-production target).
- **Outcomes**: `Outbox::RemoteStatus.map(json)` → `:queued`, `:running`, `:applied`, `:failed`, `:gone` (`error_for(json)`); `Ops::SqlScript` states gain `applied`, `failed`, `missing_remote`, `withdrawn` (columns `remote_outcome_at`, `remote_error` 16 KB, `withdrawn_at`; transitions `mark_applied!`, `mark_failed!`, `mark_retried!`, `mark_withdrawn!`, `mark_abandoned!`, `mark_missing_remote!`; `#failed_before`). `ON_SERVER_STATES` = failed sent applied missing_remote executed_unreported; `HISTORY_STATES` + withdrawn; `failed` is in `BLOCKING_STATES` (a pending script behind it waits, as behind a pending one) and `NEW_DIR_STATES` (its file is moved back to `results.new/<folder>/`). `Outbox::RemoteStatusJob` (same queue/schedule): with `iq_batch_outcome` it checks every `sent` script at once (no 5-minute delay), applied → `applied`, failed → `failed` + file back to results.new + event `outbox.failed`, queued/running → unchanged, gone → `missing_remote`; without it, exactly the 07 behaviour; with `iq_batch_filters` it resolves the `in_doubt` scripts by `data_file_checksum` (`Digest::MD5.base64digest(File.binread(path))`) among `import_queues?batch_sql=true&per_page=100`. Snapshot `outbox.remote_status` gains `outcomes`, `applied`, `failed`, `missing`, `resolved`. Operator actions in `Outbox::RemoteActions` (`retry!`, `withdraw!`, `abandon!`, operator's JWT, only with `iq_batch_outcome`), routes `retry_outbox_script` (action `retry_remote`: `retry` is a Ruby keyword), `withdraw_outbox_script`, `abandon_outbox_script`. `Outbox::ScriptActions.move_to_new!` (inverse of `move_to_sent!`). Events `outbox.{applied,failed,missing_remote,retried,withdrawn,abandoned}`. `Outbox::Summary` gains `failed`; `Outbox::InboxSource` emits `outbox_failed` (failed band, "push failed", opens the first failed script). `KpiRefreshJob` asks `import_queues` with `done: false` (`EXTRA_PARAMS`); `ImportQueuesGrid` columns `data_file_name` (`ImportQueuesGrid.data_file_names_for(json)`, set by the controller) and `error_excerpt` (80 chars, full text as tooltip).
- **Drift**: `Drift::Tables` (`OWNERS` 21 tables :import/:user, `COMMIT_TABLES` = the 17 tables `Import::Committers::Main` creates rows into, spec-checked against the committers' `GogglesDb::X.new`), `Drift::Fingerprint.local(tables:, light:)` / `.remote(base_url:, jwt:, tables:, light:)` (→ `Remote(status, payload, error)`, statuses ok no_capability no_credentials unreachable unauthorized rejected error), `Drift::Verdict.call(local:, remote:, outbox:, remote_writes:, acknowledged_at:)` (+ `Drift::Verdict::OutboxFacts.current(base_url)`), `Drift::Check.call(trigger:, mode:, tables:, base_url:)` (the only writer of `Ops::DbFingerprint`; event `drift.verdict_changed` on each verdict change; keeps the last 200), `Drift::Gate`, `Drift::ReasonText.call(reason)` (texts `db_sync.reasons.<code>`), `Drift::Notifier` (`db-sync-ping`), `Drift::InboxSource` (key `:drift`), `Drift::IndicatorComponent(fingerprint: :latest | row, api_url:, details:, link:)`, `SystemStatus::DbSyncProbe` (key `:db_sync`, pill id `status-pill-db_sync`, label `db_sync.pill.label`, snapshot mode: `#refresh!` only enqueues `DriftCheckJob` when the last job check is older than 45 min). `DbSyncController` (`show`, `check`, `acknowledge`; routes `db_sync`, `db_sync_check`, `db_sync_acknowledge`; `offline_ok`), navigation item `:db_sync` (Data quality, `fa-code-compare`). `DriftCheckJob.perform(trigger: 'schedule', mode: 'full', base_url: nil)` (queue `default`, recurring `drift_check` every 30 min, also "Check now", acknowledge, `post_push` from `Outbox::Pusher`). Reason codes: green `in_sync`, `local_ahead`; amber `count_differs`, `remote_writes`, `remote_updated`, `local_ahead_unpushed`, `remote_ahead`, `missing_remote`, `table_unknown`, `stale`; red `id_collision`, `failed_script`, `failed_partial`, `remote_batch_failed`, `schema_mismatch`; unknown = the remote status code, plus `ops_unavailable` / `error` from the gate.
- **`Drift::Gate` result API** (for 09/10/11/13): `Drift::Gate.check(scope:, acknowledged: false, force: false, tables: nil)` → `Drift::Gate::Result` (`Data`): `scope`, `level` (`:ok`/`:warn`/`:block`), `verdict` (the `Ops::DbFingerprint` used, nil without the ops DB), `reasons` (Array of `{ code:, table:, local:, remote: }`, Symbol keys), `acknowledged`, `forced`; predicates `ok?`, `warn?`, `block?`, `allowed?` (ok, or warn && acknowledged, or forced: `force` is honoured only for `:rake`), `needs_acknowledgement?`; texts `messages` (one translated line per reason), `summary` ("DB sync red: ..."), `verdict_name`. Fresh-check rule: the last stored check of the configured API if younger than `Drift::Gate::FRESH_FOR` (10 min), else a new light check (trigger `gate`). Level table: green ok; amber/unknown warn; red block for `:commit`, `:operation`, `:prepare`, `:rake` (allowed with `force: true`), warn for `:push`, `:board_write`. Never raises (an error is a warn with reason `error`), except `ArgumentError` for an unknown scope. Rake callers pass `acknowledged: true` (the warnings are printed) and `force: ENV['force'] == '1'`.
- **Deviations**: (a) one extra ops migration, `db/ops_migrate/20261123400003_add_drift_acknowledged_to_push_runs.rb` (column `push_runs.drift_acknowledged`, the confirmation tick re-checked by `Pusher#preflight!`): it was first appended to `...400002`, but another agent's run had already applied that version on the shared test ops DB, so it went into its own file; (b) `Drift::InboxSource` is registered directly in the `:drift` slot of `config/initializers/inbox.rb` (no `replace` call): the 05 drift v0 source had no fallback role left, so it was deleted; (c) Withdraw takes the failed (or queued) script AND every later queued script of the same API in one click ("Withdraw N scripts (this one and the later ones)"), highest seq first: the plan's "Withdraw the rest" without the failed one would leave a fix out of order; (d) "Discard" of a failed script is "Delete from the server and discard" → state `withdrawn` (History; the plan lists the state without a transition); (e) `missing_remote` is shown in "On the server" with no action (the plan gives none); (f) the full check reads the local side in light mode when the remote side cannot be compared (no capability or no background JWT): against today's API the 30-minute job costs a few ms instead of the full scans, the stored row says `light`; (g) a pending script behind a failed one is blocked like behind a pending one (`failed` in `BLOCKING_STATES`), so a later push cannot land before a withdrawn fix; (h) the remote-write count of the verdict ignores the Outbox's own `import_queue/*` calls (retry/withdraw are logged in `/remote_writes` but change the queue, not the data) and counts from the later of the last green check and the last acknowledgement ("Acknowledge" now also exists on `/db_sync` and queues a check); the `remote_updated` rule uses the same acknowledgement time, with a 2-minute margin for clock skew; (i) `SeasonBoardController` has no backfill action (backfill is the rake task only): the `:board_write` gate is on `link`, rendered as a confirmation page (`season_board/confirm_link`, status 422) that re-posts with `drift_ack=1`; the drift v0 `drift_v0:<url>` snapshot, `Drift::LatestUpdatesCheck`, `Drift::V0Status`, `SystemStatus::DriftV0Probe`, `Inbox::Sources::Drift`, `remote_writes/_drift_summary` and the `shell.status.drift_v0.*` keys are gone (old `drift_v0:*` snapshot rows stay in existing ops DBs, unread).
- **Fingerprint timings** (development DB, a production copy, read only through `bin/rails runner`): full local fingerprint 7.0 s on a first run, 16.5 s with `SQL_NO_CACHE` per table (MAX(updated_at) scans dominate: meeting_individual_results 4.8 s on 1.34 M rows, meeting_programs 2.9 s, badges 2.7 s, laps 1.6 s; a repeat in the same process came back in 0.01 s, most likely served by a cache, so not counted); light (MAX(id) only) 0.02-0.07 s. The 30-minute schedule on the single-thread `default` worker is kept: worst case a ~20 s delay of the FIN watcher; if the production server's full answer is slow too (it caches 60 s), move `DriftCheckJob` to the `maintenance` worker.
- **For 09**: the commit gate is `Drift::Gate.check(scope: :commit, acknowledged:)` through `DataFix::Guards` (it already uses `messages`); a `:block` result's flash should link `db_sync_path`; the job-side re-check reuses the same stored row while it is under 10 minutes old. Unknown (today's API) is a warn: every commit needs the tick until goggles_api 0.10.81 is live. In specs, stub `Drift::Gate.check` or create a fresh green `:ops_db_fingerprint` (factory in `spec/factories/ops/db_fingerprints.rb`, traits `:amber`, `:red`, `:unknown`) for `APIProxy.configured_base_url`.
- **For 10**: `scope: :prepare` blocks on red; `verdict.reason_list` / `Drift::ReasonText` give the annotation texts.
- **For 11 / 13**: `scope: :operation` before planning an apply (never on a dry run); rake callers `scope: :rake, acknowledged: true, force: ENV['force'] == '1'` (pattern in `lib/tasks/season_board.rake`).
- **For 14**: a red verdict is the restore trigger; after a restore, `Ops::DbFingerprint` rows describe the old DB (run "Check now", or `Drift::Check.call(trigger: 'manual')`), `drift.acknowledged_at` and the `sql_scripts` outcomes stay; the `api.status` snapshot is unaffected.
- **Not verified by hand** (the dev server would run the recurring jobs against FIN and the configured API, and no push may happen from this session): the whole remote loop against a development goggles_api/goggles_main 0.10.81 (a failing fixture script showing "failed" with its MariaDB error, the later script staying queued and marked blocked, retry, withdraw + re-push, "applied"; the in-doubt checksum match; the import queue grid columns), the environment badge against a real 0.10.81 `status`, a real `tools/db_fingerprint` comparison and its timing on the production side, the live refresh of `/db_sync` after "Check now" (`db-sync-ping`), the Season board link confirmation page in a browser, and the Outbox system journey (`spec/system/outbox_spec.rb`), which now fails in its Phase 6 commit step: phase 09's new commit flow refuses the commit without its DB sync tick (the gate is `unknown` = warn in the test env); its push step already ticks `drift_ack`. The other touched system specs (`remote_writes_spec`, `sign_in_and_dashboard_spec`, `app_shell_spec`) are green.

### goggles_main + goggles_api (steps 1-3)

Steps 1-3 are done in both repos (branch `feature/modernize-admin-console-ux`; nothing committed, tagged or deployed). No goggles_db change was needed: the engine is untouched and the new fields are merged in the API.

#### What shipped versus the plan

#### goggles_main: `app/jobs/import_processor_job.rb` (steps 1-2)
- `perform` runs `process_batch_sql`, then `process_microtransactions`. A `rescue StandardError` around the batch pass logs the error and moves on, so the micro pass always runs.
- `process_batch_sql` follows the plan's order:
  1. `purge_expired_batch_rows`: batch rows with `done: true` and `updated_at < 14.days.ago` (`RETENTION_PERIOD`) are deleted with `find_each`, `data_file.purge` and `delete`. No maintenance toggle.
  2. If `failed_batch_rows.exists?` (`done: false`, `error_messages` not in `[nil, '']`), it logs "blocked by failed ImportQueue #N" and returns.
  3. If `interrupted_batch_rows.exists?` (`done: false`, blank error, `process_runs > 0`), every such row gets `error_messages: 'interrupted: outcome unknown'` (`INTERRUPTED_MESSAGE`) and it returns.
  4. If no `queued_batch_rows` (`done: false`, blank error, `process_runs` 0/NULL) exist, it returns without opening a maintenance window.
  5. Otherwise `with_maintenance_window { run_queued_batch_rows }`:
     - "was on" is read uncached (`AppParameter.versioning_row.maintenance?`);
     - maintenance is turned on only when it was off, and restored in `ensure` only if this run turned it on.
- `run_queued_batch_rows` loops, fetching each time `queued_batch_rows.where('import_queues.id > ?', last_id).order(:id).first`. Rows queued during the run therefore also run, in id order.
- `run_batch_row`:
  - before running: `process_runs += 1`;
  - success: `reload.update!(done: true, error_messages: nil)`; the attachment is kept until retention;
  - failure: `store_failure` and stop. It never raises.
- Deviations and additions (all small, all within the outcome encoding):
  - **Error text** is `stderr.scrub.strip.truncate_bytes(60_000, omission: '...')` rather than `truncate(60_000)`. `import_queues.error_messages` is a latin1 TEXT in strict mode, so the limit is in bytes.
    - If that write is rejected (`ActiveRecord::StatementInvalid`, for example a character latin1 cannot store), the error is stored again as ASCII.
    - Empty stderr with a non-zero exit gives "DB client exited with status N and no error output".
  - **No data file attached:** the row is failed with "data file missing: nothing to run" (it blocks the queue). The old job marked it done.
  - **Other errors:** a download or integrity error, or an exception while executing, is caught per row and becomes the failure text ("Class: message").
- Temp file: `iq_row.data_file.open(tmpdir: Dir.tmpdir)`. It streams the blob to a tempfile under `Dir.tmpdir`, verifies the checksum and removes the file at the end of the block. Nothing is written to `db/dump` any more.
- The client command keeps the old wrapping, `(echo 'START TRANSACTION;'; cat <file>; echo 'COMMIT;') | mariadb --host=… --user=… --database=…`, now with `Shellwords.escape` on every value. `--host`/`--user` are passed only when present.
- The password goes in the `Open3.capture3` env as `MYSQL_PWD`, never on the command line.
- `limits_concurrency key: 'import_processor', to: 1, duration: 30.minutes, on_conflict: :discard` (solid_queue 1.7.2). A discarded recurring enqueue is not recorded as a recurring execution, so it is silent.
- `process_microtransactions` keeps the old logic. Its cleanup is now `without_batch_sql.deletable.delete_all`.
- Removed: the public `exec_sql` and the private `handle_macrotransaction_batch_row` / `handle_microtransaction_row` (nothing else referenced them).
- `# rubocop:disable Metrics/ClassLength` is on the class line, as in `ApplicationController`.
- Docs: `docs/production_containers.md` gains a "Batch SQL import queue (ImportProcessorJob)" section covering the outcome table, how to unblock a failed row and the downgrade note. The `backups` volume row no longer says the job writes there.

#### goggles_api (step 3)
- `app/api/goggles/api.rb`:
  - new `Goggles::API::CAPABILITIES = %w[iq_batch_outcome iq_batch_filters db_fingerprint]`;
  - `GET status` payload adds `environment: Rails.env.to_s` and `capabilities: CAPABILITIES`;
  - `DbFingerprintEntity` is registered in `add_swagger_documentation`.
- `entities/status_entity.rb` exposes `environment` and `capabilities` (`is_array`).
- `import_queues_api.rb`:
  - helper `import_queue_hash(row)` returns `row.to_hash`, plus `data_file_name`, `data_file_checksum` and `data_file_byte_size` for `batch_sql` rows (all nil when no file is attached). Micro rows are unchanged, which is why the existing `fixture_row.to_json` equality spec still passes. It returns `nil` → null body when the row is not found.
  - It is used by `GET import_queue/:id` and `GET import_queues`.
  - The list adds `optional :batch_sql, type: Boolean`. `done` and `batch_sql` are filtered through a local `boolean_filtering_hash_for`, which uses `params.key?` and a non-nil check so `false` is kept.
  - The shared `filtering_hash_for` is unchanged; `done` was simply removed from its field list there.
  - The list now has `.order(:id)` (pagination is stable).
  - `PUT import_queue/:id` adds `optional :error_messages, type: String`. A blank value is stored as **nil**, so a retried row reads back exactly as "queued" (`error_messages: nil`).
- `entities/import_queue_entity.rb`: Swagger docs for the three `data_file_*` fields and the outcome encoding. It stays documentation-only; the endpoints render `to_hash`.
- `tools_api.rb`, new `GET tools/db_fingerprint`:
  - access: `reject_unless_authorized_admin(check_jwt_session)`, with usage counted under its own route key `GET /api/v3/tools/db_fingerprint`;
  - whitelist: `Goggles::ToolsAPI::DB_FINGERPRINT_TABLES`, the plan's 21 tables;
  - cache: `Rails.cache.fetch(['db_fingerprint', tables.sort.join(','), light], expires_in: 60.seconds)`;
  - `schema_version` comes from `connection_pool.migration_context.current_version.to_s`.
- New `entities/db_fingerprint_entity.rb` provides the Swagger docs; the endpoint `present`s through it.
- `ImportQueuesAPI` and `ToolsAPI` get an inline `# rubocop:disable Metrics/ClassLength`, the existing convention for `GoggleCupsAPI`, `TrainingsAPI` and `GoggleCupManageAPI`.

#### Payloads as implemented

`GET /api/v3/status` (public):
```json
{ "msg": "OK", "version": "C7-0.10.81-20261123", "environment": "production",
  "capabilities": ["iq_batch_outcome", "iq_batch_filters", "db_fingerprint"] }
```
`environment` is `Rails.env`. The keys are exactly these four.

`GET /api/v3/import_queue/:id` (admin) returns `GogglesDb::ImportQueue#to_hash`, unchanged: string keys, including `user` and the timestamps. Batch rows also get:
```json
{ "data_file_name": "0477-….sql", "data_file_checksum": "<blob.checksum, base64 MD5>", "data_file_byte_size": 245113 }
```
- The three keys are nil when no file is attached and absent on micro rows.
- When the row is not found, the body is `null`.

Outcome encoding (no new column):

| State | Encoding |
| --- | --- |
| queued | `done:false`, `process_runs:0`, `error_messages:nil` |
| running | `done:false`, `process_runs>0`, `error_messages:nil` |
| applied | `done:true`, `error_messages:nil` |
| failed | `done:false`, `error_messages` present |
| gone | `null` body |

- An interrupted run reads as failed with `error_messages == "interrupted: outcome unknown"`.
- A row without a file reads as failed with "data file missing: nothing to run".
- The server treats `''` like `nil`.

`GET /api/v3/import_queues?batch_sql=true&done=false` (admin):
- `done` and `batch_sql` work as Boolean filters for both `true` and `false` (`1`/`0` are accepted by the Grape Boolean coercion);
- they combine with the existing exact-match filters (`user_id`, `uid`, `process_runs`);
- rows are sorted by id, have the same shape as the single GET, and come with the `Total`/`Per-Page`/`Page`/`Link` headers.

`PUT /api/v3/import_queue/:id` (admin) accepts `error_messages` (String). A blank value is stored as nil. Retry in place is `{ "error_messages": "", "process_runs": 0 }` and returns `true`, or a null body when the row is not found.

`GET /api/v3/tools/db_fingerprint[?tables=laps,relay_laps][&light=1]` (admin JWT):
```json
{ "environment": "production", "generated_at": "2026-11-22T10:00:00Z",
  "schema_version": "20261027120100", "db_version": "2.10.12",
  "import_queue": { "next_id": 9124, "batch_queued": 0, "batch_failed": 0 },
  "tables": { "laps": { "count": 4120331, "max_id": 4188002, "max_updated_at": "2026-11-22T09:58:12Z" } } }
```

Top-level fields:
- `generated_at` is UTC ISO8601 at seconds precision. When the response comes from the 60 s cache, it shows when the values were computed.
- `db_version` is `app_parameters.a_string` of the versioning row, falling back to `Version::DB`.

`import_queue` fields:
- `next_id` is `information_schema.tables.AUTO_INCREMENT` for `import_queues`, falling back to `MAX(id)+1`.
- `batch_queued` counts unfinished batch rows with a blank error (queued **or running**).
- `batch_failed` counts unfinished batch rows with an error.

`tables` fields:
- Full mode runs one `SELECT COUNT(*), MAX(id), MAX(updated_at)` per table. `max_updated_at` is UTC ISO8601 at seconds precision; `max_id` and `max_updated_at` are null on an empty table.
- Light mode (`light=1`) gives `tables.<name> = { "max_id": n }` only, from `SELECT MAX(id)`. The `import_queue` block is still included.

Parameters and errors:
- `tables=` is comma-separated. Whitespace and empty items are ignored; blank means all 21 tables.
- An unknown name returns 422 with `{ "error": I18n.t('api.message.invalid_parameter') }` and `X-Error-Detail: "unsupported tables: <names>; allowed: <whitelist>"`.
- Non-admin or invalid JWT: 401, as on the other admin endpoints.
- Whitelist: meetings, meeting_sessions, meeting_events, meeting_programs, meeting_individual_results, meeting_relay_results, meeting_relay_swimmers, laps, relay_laps, meeting_team_scores, swimmers, teams, team_affiliations, badges, calendars, swimming_pools, cities, managed_affiliations, standard_timings, category_types, users.

Payload deviations from the plan's contract:
- No key or shape differs.
- Behavioural precisions, compatible with the contract:
  - PUT stores blank `error_messages` as nil;
  - the list is ordered by id;
  - `batch_queued` includes running rows.

#### Step 1 evidence (executed)
The target examples were added to `spec/jobs/import_processor_job_spec.rb` under `describe 'batch SQL rows'`. Every example stubs `Open3.capture3` and `IqSolverService`.

They ran against the **old** job with `rspec -e 'batch SQL rows'`: **21 examples, 17 failures**.

| Example (old job) | Result | Why |
| --- | --- | --- |
| does not raise (failing script) | FAIL | `RuntimeError: ERROR 1062 …` raised by `exec_sql` |
| maintenance flag off after a failing script | FAIL | raise; with the raise swallowed (evidence-only variant): flag **still true** |
| failed row kept with `error_messages`, `done: false` | FAIL | raise; swallowed: row `done: true, process_runs: 0, error_messages: nil` |
| later rows not run, now nor on next run | FAIL | raise; swallowed: executed `["-- FAILING script", "-- later script"]` (2nd run deleted the "done" failed row and ran the next) |
| micro row processed while a failed batch row exists | FAIL | solver never called (SQL branch taken) |
| blocked: no script run, maintenance untouched | FAIL | the failed row was re-executed (`capture3` called) |
| retry reset → both run in id order | pass | old job runs every batch row anyway |
| two rows run in id order | pass | InnoDB returns PK order without ORDER BY: the missing ORDER BY can't be shown failing |
| both applied, rows & files kept, `process_runs: 1` | FAIL | `process_runs` stayed 0 |
| single maintenance window, closed afterwards | pass | |
| applied row survives the next run | FAIL | deleted |
| no maintenance window when nothing is queued | FAIL | `maintenance=` called |
| retention: 15-day row purged, 13-day kept | FAIL | the 13-day row was deleted too |
| interrupted row → 'interrupted: outcome unknown' | FAIL | re-run and marked done |
| maintenance already on → untouched | pass | |
| micro cleanup never deletes batch rows | FAIL | raise (failed row re-run); swallowed: the applied batch row was deleted |
| no data file → failed, later rows not run | FAIL | marked `done: true, process_runs: 0`; the later row ran |
| huge stderr stored ≤ 60 000 bytes | FAIL | raise |
| password via `MYSQL_PWD`, not on the command line | FAIL | env `{}` (password in `--password=`) |
| temp file under `Dir.tmpdir`, removed | FAIL | path `…/goggles_main/db/dump/batch-N.sql` |
| `limits_concurrency` present | FAIL | `concurrency_key` nil |

- The findings that were facts by reading are now confirmed by execution:
  - maintenance left on after a raise, and on the next run `maintenance_was_on` stops it ever being turned off;
  - failed rows marked done, deleted, and the next script run;
  - micro rows starved while batch rows exist.
- Running the examples first also exposed two test artefacts, fixed before the evidence run:
  - the old `f.puts` adds a newline, so the fake client compares `strip`ped SQL;
  - the ActiveStorage attach touches the row (stale `lock_version`), so `batch_row` returns `row.reload`.
- One fact could not be shown failing on the current DB: "no ORDER BY". Without ORDER BY, InnoDB still returns PK order, so that example passes on the old job.

After step 2, the job spec has **28 examples, 0 failures**. That covers the 21 above, rewritten legacy examples, a fixture-factory run (`import_queue_with_static_data_file`, `batch_sql: true`) and the charset fallback.

#### Specs
- goggles_main `spec/jobs/import_processor_job_spec.rb`: 28/0.
  - The legacy committed `before(:all) { ImportQueue.delete_all }` hooks became one in-transaction `before { ImportQueue.delete_all }` (rolled back), so the shared DB is never touched.
  - The old "raises a Runtime error but flags the row as deletable" example was removed; it contradicts the new contract.
- goggles_api targeted (`api_spec`, `import_queues_api_spec`, `tools_api_spec`): **278 examples, 0 failures**.
  - Status keys.
  - Batch-row `data_file_*` and outcome fields, absent on micro rows.
  - `done=false`, `done=true`, `batch_sql=true`, `batch_sql=false`, and `batch_sql=true&done=false` with `Total`.
  - PUT retry clears `error_messages` to nil; PUT sets `error_messages`.
  - db_fingerprint:
    - admin keys and all whitelisted tables;
    - full-mode values equal the DB aggregates;
    - light mode returns only `max_id`;
    - queued/failed counts and `next_id`;
    - 422 with `X-Error-Detail` for unknown tables;
    - cache hit within 60 s and recompute after (`MemoryStore` stub plus `travel`, since test uses `:null_store`);
    - 401 for non-admin and for an invalid JWT.
- Full suites, run one after the other, no Cucumber:
  - **goggles_api**: `bundle exec rspec`, **3528 examples, 2 failures** (48 min).
    - Both failures are in `spec/api/goggles/goggle_cups_base_timings_spec.rb` ("filtering by a valid swimmer_id" and "swimmer_id and event_type_code": `0.positive?`). They also fail when the file runs alone (28 ex / 2 F). They are unrelated to this phase and depend on the date and data: the fixture season (2022) must fall inside the view's 3-year window, which moves with the "current" season. The shared test DB also holds committed "Fake Season" rows dated 2026-08-23.
    - An earlier full run had 3491 errors because a goggles_api file was edited while it ran (`config.cache_classes = false` in test reloads classes, giving `AssociationTypeMismatch`). The clean rerun is the result above. Don't edit goggles_api files during a suite run.
  - **goggles_main**: `bundle exec rspec`, **5616 examples, 4 failures, 1 pending** (17 min).
    - All 4 failures are in `spec/config/solid_stack_spec.rb` (`KeyError: key not found: "staging"` in `config/database.docker.yml` / `config/cache.yml`). They fail when the file runs alone (24 ex / 4 F). They come from the earlier staging config removal (commit 76bfe7b) and are unrelated; staging is deprecated, so they were left alone.
    - The pending example is the existing Facebook omniauth one.
- `bundle exec rubocop` is clean in both repos (goggles_main 528 files, goggles_api 179). No HAML was touched.

#### What the operator must verify at release (step 4)
- **Tag together:** goggles_api and goggles_main go out in one tag, 0.10.81; admin2 goes last.
- **Run the plan's manual check** on a local development API and main job before tagging:
  - a duplicate-key fixture script ends "failed" with the MariaDB error, and the next script stays queued;
  - maintenance is off afterwards, and a micro row is processed meanwhile;
  - a retry (`PUT error_messages: "", process_runs: 0`) or a delete unblocks the queue;
  - a good script ends "applied" and stays visible for 14 days.
- **Maintenance may be stuck on.** If production maintenance is currently on because an old job failure left it so, the new job leaves it untouched: turn it off by hand after deploying.
- **Clean failed rows.** Before deploying, check for leftover `batch_sql` rows with errors. After deploying, any failed row blocks the queue until it is retried or deleted.
- **Container check:** in the jobs container, `Dir.tmpdir` (`/tmp`) must be writable (it is not a read-only rootfs in `docker-compose.prod.yml`) and the `mariadb` client must read `MYSQL_PWD`.
- **API cache:** the production API cache is Rails' default `:file_store` under `tmp/cache` (no `cache_store` is set). In development it is `:null_store` unless `tmp/caching-dev.txt` exists, so locally the 60 s cache is usually off.
- **Fingerprint timing:** measure a full-mode `db_fingerprint` on a production-size dump (COUNT(*) on laps/MIR) before fixing the 30-minute schedule. Gates should use `light=1`.
- **Rollback:** delete or resolve failed rows before downgrading goggles_main (the old job would run them again). Also, a script running longer than 30 minutes can let a second run start once the concurrency semaphore expires. That run marks the running row "interrupted: outcome unknown", and the first run then overwrites the mark with its real outcome.
- **Redundant enqueue:** `lib/tasks/jobs_utils.rake` still enqueues `perform_later('iq')` and `perform_later('sql')`. The second is now discarded by the concurrency limit, which is harmless because every run does both passes.

## Rollback note

admin2 steps feature-detect, so the server can be rolled back independently (admin2 falls back to 07 states). Rolling back goggles_main restores the old job: failed rows (`done: false` + error) would then run again on the next cycle, so delete or resolve failed rows before downgrading. The ops migrations are additive.
