# Phase 05 — Inbox dashboard

## Goal

Replace the link-grid home page (`HomeController#index`) with an inbox-first dashboard. It shows what needs the operator, one primary action per item; what is running; season progress; system status; recent activity; and the four KPI counters. It is built on registries, so later phases add items and status rows without editing dashboard templates. The same phase makes the Season board cheap enough to summarise on every landing (a stored snapshot), starts a log of remote-only writes, adds drift v0, and replaces "Clean slate" with a per-source Data-Fix sessions list.

## Operator-visible outcome

- `/` opens at once, whether the API is reachable or not and whether the crawler is up or down. Each zone loads in its own lazy Turbo frame.
- "Needs you" is a prioritised list: review, push, extract, crawl, link, retry or discard a failed job, sign in again. Each item has one button.
- "In progress" lists queued and running crawls, extractions and jobs, and updates live.
- "Season progress" shows the board's state counts. Each segment opens the board filtered on that state.
- Side column: system status rows (API, crawler, job queues, live updates, FIN watcher, ops DB, DB sync v0) and an activity feed.
- KPI strip: API uses, import queues, issues, users. Each counter shows its age ("as of 10:15"). When a value cannot be fetched it shows "unreachable" or "sign in to refresh", never a silent 0.
- New page `/data_fix/sessions`: every source with phase files or import staging rows, with "Resume" and a per-source "Purge staging rows". The global "Clean slate" button is gone.
- New page `/remote_writes` (System group): every non-GET API call admin2 made, and its result.

## Depends on

- **01**: `Ops::Event`, `Ops::Setting`, `Ops::Snapshot` (key + JSON + `taken_at`), `Ops.safely`, the event instrumentation (Phase 6 commit, push upload, purge, board crawl/extract/link, watcher change), and the per-source purge quick win.
- **04**: shell layout, `Shell::Navigation`, `Shell::PageHeaderComponent`, toasts, the `SystemStatus::Probe` registry and top-bar pills, `Shell::ApiTarget`.
- Softer link (not a hard dependency): **02** has already removed `home#latest_updates` and its port-446 call (`home_controller.rb:31-44`, `app/views/home/latest_updates.haml`). If that is still there when 05 starts, delete it in step 1.

## Invariants (from the master plan)

- The dashboard and the status surfaces make no synchronous remote call and render in an API-offline session. Remote values come only from `Ops::Snapshot` rows written by jobs (never `Rails.cache`).
- No job commits, pushes, applies or restores. Every inbox action is a link or a POST to an existing controller action, started by a click. Failed commit, push, apply and restore jobs (added from 07 and 09 on) are offered "Discard" and a link to their report, never "Retry".
- "Staging" here means the import staging tables (`data_import_*`).
- No admin2-only tables in MySQL: new tables go in the ops DB (`db/ops_migrate`).
- File conventions stay as they are (`NNNN-<base>-lt4.sql`, `results.new/sent/done/<season>`).
- Repo conventions: `# frozen_string_literal: true`; en and it keys; `bundle exec rubocop -a` clean; CHANGELOG entry and a PATCH bump in `lib/version.rb` for each user-visible step; never a bare `bin/rails db:prepare` or `db:migrate` (use `bin/rails ops:prepare`).
- The routine gate keeps passing after every step.

## Layout sketch

```
+-- top bar (04): API target | pills: API crawler jobs cable FIN ops sync | theme | user ----------+
| sidebar |  Dashboard                                                   [Refresh counters]     |
|         |  +-- KPI strip (lazy frame) ---------------------------------------------------------+ |
|         |  | API uses 1 234 | Import queues 3 | Issues 12 | Users 87   as of 10:15 (4 min ago)   | |
|         |  +-------------------------------------------------------------------------------------+ |
|         |  +-- Needs you (lazy frame) --------------------+  +-- System status (lazy) ----------+ |
|         |  | ! Crawl failed: Trofeo X (FIN 1234)  [Retry] |  | API        ok   12 ms, 1 min ago  | |
|         |  | ^ 3 scripts to push, oldest 0477     [Push]  |  | Crawler    idle  [Start crawler]  | |
|         |  | > Resume review step 3: Città di Y  [Resume] |  | Jobs       2 workers, beat 3 s    | |
|         |  | > Results ready: Meeting Z          [Review] |  | Live upd.  ok                     | |
|         |  | o FIN calendar changed (2 rows)  [Open board]|  | FIN watch  10:30, no error        | |
|         |  |   ... 6 more                                 |  | Ops DB     ok                     | |
|         |  +----------------------------------------------+  | DB sync v0 amber: 2 remote edits  | |
|         |  +-- In progress (live) ------------------------+  +----------------------------------+ |
|         |  | running  crawl  Trofeo X   since 10:02       |  +-- Activity (Ops::Event) --------+ |
|         |  | queued   extract Meeting W  (1 queued)       |  | 10:12 commit Meeting V (0476)    | |
|         |  | next: watcher 10:30, re-check 05:15          |  | 10:05 push 0475 -> sent          | |
|         |  +----------------------------------------------+  | ...                [all events]  | |
|         |  +-- Season progress 2026/27 -------------------+  +----------------------------------+ |
|         |  | [link 40][crawl 12][review 5][sql 3][done 59]|                                      |
+---------+------------------------------------------------------------------------------------------+
```

## Scope

**Dashboard core** (new `app/controllers/dashboard_controller.rb`; `root to: 'dashboard#index'`; `get 'home/index', to: 'dashboard#index', as: 'home_index'` kept so `Footer::MainComponent` and the purge redirect still work):
- `index` renders the layout only (no data loading). Frame actions: `needs_you`, `in_progress`, `season_progress`, `system`, `activity`, `kpis`, plus `POST refresh_kpis`. `api_offline_allowed?` is true for all of them.
- (This removes home's own `Footer::MainComponent` render only; the component itself is deleted in phase 15. The `home_index` route alias stays as written.) Delete `HomeController`, `app/views/home/*` (`index`, `_top_header`, `_data_import`, `_tools`, `_manage_entities`) and `app/assets/stylesheets/home.scss`. Rewrite `spec/requests/home_controller_spec.rb` as `spec/requests/dashboard_controller_spec.rb`.

**Inbox** (`app/services/inbox/`):
- `Inbox::Item`, a `Data.define` with:
  - `key`: a stable String, for example `board:1234:crawl`;
  - `source`: Symbol;
  - `kind`: Symbol;
  - `band`: one of the bands below;
  - `title`, `detail`;
  - `subject`: Hash, for example `{ fin_event_id:, file_path:, season_id: }`;
  - `action`: an `Inbox::Action` (`label`, `path`, `http_method` `:get` or `:post`, `params`, `confirm`), exactly one, checked in `initialize`;
  - `since`: Time;
  - `count`: Integer, default 1, for grouped items.
- Bands (`Inbox::Item::BANDS`, lower first):
  - `0 blocked`: cannot work (API offline, background JWT expired, ops DB missing, queue supervisor down);
  - `1 failed`: failed or stuck jobs;
  - `2 push`: scripts waiting to be pushed (order matters);
  - `3 review`: in review, then results ready, structure ready, header review;
  - `4 acquire`: extract manifest, check results, crawl, link;
  - `5 notice`: FIN change, drift amber, idle sessions.
  Within a band the oldest `since` comes first. The page shows 25 items, then "N more" per source.
- `Inbox::Source` interface. Phases 06, 07 and 10 implement it:
  - `self.key` returns a Symbol;
  - `items(context)` returns an Array of `Inbox::Item`. It must be read-only: no remote call, no file or DB write, about 200 ms or less on today's data;
  - `self.enabled?(context)`, default true.
  `context` is an `Inbox::Context` (`season`, `board_snapshot`, `now`, `api_offline`, `ops_available`, `user`).
- `Inbox::Registry`: `register(klass)`, `replace(key, klass)` (07 replaces the `:pending_sql` source with a class reading `Outbox::Summary.call`; `replace` takes a key and a class; 10 narrows `BoardRows` so rows in `ready_to_commit`, `needs_review` and `prepare_failed` are emitted only by 10's sources), `sources`. Sources are registered in `config/initializers/inbox.rb` inside `Rails.application.config.to_prepare`.
- `Inbox::Builder#call(context)` merges the sources. It de-duplicates by `key`, then by canonical `subject[:file_path]`: a board item beats a session item. It sorts by `[band, since]`. Each source runs inside a rescue, so a failing source becomes one band-1 item ("Inbox source X failed: …") instead of a 500.
- `Inbox::ItemComponent` renders every kind. `Inbox::ListComponent` renders the list.

**v1 sources** (`app/services/inbox/sources/`), each with the existing code it reads:

| Source | Reads | Item, then action |
|---|---|---|
| `BoardRows` | `SeasonBoard::Snapshot` rows: `Row#next_action` (`StateResolver::ACTIONS`, `state_resolver.rb:42`), skipping busy rows and `:push` | review / resume / structure / header: link built by `SeasonBoard::ActionPaths` (moved out of `RowComponent#link_action_path`, `row_component.rb:96-106`); crawl and check_results: POST `season_board_crawl_path(fin_event_id:)`; extract_manifest: POST `season_board_extract_path`; link: `season_board_path(anchor: "row-<fin>")` (needs a calendar choice) |
| `UnmatchedSources` | snapshot `unmatched_sources` (`DiskIndex#unmatched`, `disk_index.rb:65-69`) | "Open in Data-Fix", `review_sessions_path(file_path:)`; manifest-only entries link to `pull_result_files_path` until 15 |
| `DataFixSessions` | new `DataFix::SessionIndex` (below) | session idle for 3 days or more: "Resume review at step N"; staging rows whose source file is gone: "Purge staging rows" (POST, with confirm) |
| `PendingSql` | glob `crawler/data/results.new/{<numeric>,misc}/[0-9]*.sql`, sorted by numeric prefix (covers `DiskIndex#board_sql_paths` and commit SQL) | one grouped item, "N scripts to push, oldest NNNN": `push_index_path` on the oldest script's folder (07 replaces this source) |
| `FailedJobs` | `SeasonBoard::ActivityLog#all_entries` (`activity_log.rb:105-109`): latest attempt `failed`, or `Entry#stale?`; `SolidQueue::FailedExecution` with `job.class_name`, `created_at` | board crawl or extract: POST retry to the same board action; other failed executions: "Discard" (POST `dashboard#discard_failed_job`, `FailedExecution#discard`); "Retry" (`#retry`) only for jobs outside the protected list (`DataFixCommitJob`, `Outbox::PushJob`, `Maintenance::RunJob`, `RestoreJob`, once they exist) |
| `FinChange` | `FedernuotoWatch::StateStore#pending_change` (`state_store.rb:60-62`) | "Open board"; acknowledging stays on the sticky alert |
| `Blockers` | `api_offline_session?` (`api_session.rb:37-39`), `Ops::BackgroundCredentials#status`, `Ops.available?`, queue probe | "Open settings", "Sign in again" or "How to start jobs" (doc link) |
| `Drift` | `Ops::Snapshot` `drift_v0:<api_url>` (08 replaces it with `Ops::DbFingerprint` rows) | amber only: "Review remote-only edits", `remote_writes_path` |

**Data-Fix sessions** (`app/services/data_fix/session_index.rb`, `app/controllers/data_fix/sessions_list_controller.rb`, route `get 'data_fix/sessions'`):
- Phase files are found with the glob `crawler/data/results.new/<numeric season>/*-phase[1-5].json`, grouped by stem (same regexp as `DiskIndex::PHASE_REGEXP`, `disk_index.rb:30`).
- Staging rows come from one grouped count over `GogglesDb::DataImportMeetingIndividualResult` by `phase_file_path`. That table is what `home_controller.rb:19-22` counts today.
- Each row shows: highest phase, mtime, staging row count, the edit marker from `_meta` (when 09 is present), a "Resume" link, and "Purge staging rows" (per source).
- The purge goes through `DataFix::StagingPurger.purge!(source_path)` (plus `purge_all!`, all sources, used by phase 14's restore post-steps), which deletes the five `data_import_*` tables `where(phase_file_path:)`, the same scope as `commit_archiver.rb:53-57`. The per-source purge action added in 01 is refactored onto this class. `DataFixController#purge` (`data_fix_controller.rb:15-37`) and its route `delete 'data_fix/purge'` (`routes.rb:102`) are removed, and `spec/requests/data_fix_controller_phase5_spec.rb:441` plus 01's `spec/requests/data_fix_controller_purge_spec.rb` are moved to the per-source action.

**In progress and season progress:**
- "In progress": `SeasonBoard::ActivityLog#active` (`activity_log.rb:99-102`), plus `SolidQueue::ClaimedExecution` and `ReadyExecution` counts per queue, plus next runs from `SeasonBoard::ActivityStripComponent#next_runs`.
- Season progress: `SeasonBoard::Snapshot#state_counts`. Each segment links to `season_board_path(state:)`; the filter exists at `season_board_controller.rb:31`.

**System column:** extend the 04 `SystemStatus::Probe` / `Registry` (it does not recreate it). 04 already ships the `api`, `crawler`, `queue` and `fin_watch` probes; this phase refines their levels as below and adds `Cable`, `OpsDb` and `DriftV0`. Each probe returns `label`, `level` (`ok`/`warn`/`error`/`unknown`), `detail`, `checked_at` and an optional `action`.

| Probe | Reads | Levels |
|---|---|---|
| `Api` (04) | `Shell::ApiTarget` / `Ops::Snapshot` `api.status:<base_url>` | ok: reachable, snapshot under 10 min old; warn: older; error: unreachable; unknown: never pinged or API-offline session |
| `Crawler` | `crawler/crawler-status.json` (written by `crawler/server/utility.js:156`), parsed with `CrawlerClient::Status.from`, and the `CrawlerLauncher::PID_PATH` process | ok: idle; ok, "busy i/n": running; warn: `stale?(stale_after: 30.min)`; error: no process, with action "Start crawler" (`start_crawler_path`) |
| `Queue` | `SolidQueue::Process` (`kind`, `last_heartbeat_at`, `metadata` queues) | ok: supervisor and one worker per queue in `config/queue.yml`, beat under 1 min; warn: a queue has no worker; error: no supervisor. Detail says "SOLID_QUEUE_IN_PUMA=false: run bin/jobs" when that variable is set (`config/puma.rb:45`) |
| `Cable` | `configs_for(env_name:, name: 'cable')` and `SolidCable::Message.table_exists?` | ok; warn: not configured ("live updates by polling") |
| `FinWatcher` | `StateStore#read` `last_checked`, `last_error` | ok: checked under 75 min ago; warn: older; error: `last_error` present. Action "Check now" (`federnuoto_watch_check_path`) |
| `OpsDb` | `Ops.available?` | ok; error: "run bin/rails ops:prepare" |
| `DriftV0` | `Ops::Snapshot` `drift_v0:<api_url>` | ok / warn / unknown (below); error is reserved for 08 |

**Activity feed:** the last 20 `Ops::Event` rows, with "all events" linking to a paginated `/activity` page (a contextual child of the dashboard in `Shell::Navigation`; step 3 and step 5 add the `remote_writes` and `data_fix_sessions` entries, and the 04 navigation spec's route-coverage check stays green).

**Background credentials** (`app/services/ops/background_credentials.rb`):
- `Users::SessionsController#create` (`sessions_controller.rb:19-28`) stores `Ops::Setting.store!('background.user_id', ...)` after a successful sign-in. This covers both a fresh JWT (line 65) and a still-valid one (line 58).
- `BackgroundCredentials#jwt` loads that user, or else the admin with the latest `current_sign_in_at` (Devise `:trackable` in goggles_db `user.rb:20`). It returns `user.jwt` when `GogglesDb::JWTManager.decode(jwt, Rails.application.credentials.api_static_key)` is present. This is the same check as `APISession#valid_jwt?` (`api_session.rb:26-28`).
- The JWT lives in the existing `users.jwt` column (MySQL, `db/structure.sql:2856`). goggles_api issues it with `JWTManager::TOKEN_LIFE` = 10 hours (goggles_db `jwt_manager.rb:17`; `goggles_api/app/commands/cmd_authenticate_user.rb:32-37`).
- `status` returns `:valid` with `expires_at` (from the token's `exp` claim), `:expired`, or `:missing`.
- Jobs never log or store the token. A 401 from the API is recorded as `:unauthorized`, for example when the API URL was changed to a server with another key.

**KPI refresh** (`app/jobs/kpi_refresh_job.rb`, queue `default`):
- Recurring every 15 minutes (`config/recurring.yml`), also enqueued after sign-in and by the "Refresh counters" button.
- It makes four GETs (`users`, `import_queues`, `issues`, `api_daily_uses`), each with `params: { per_page: 1 }` (api-pagination; the per-endpoint support is not verified). It reads `headers[:total]` exactly as `home_controller.rb:56-59` does: the API-uses counter stays a row count of `api_daily_uses`. The Goggle Cup count (`home_controller.rb:23`) is dropped.
- Explicit timeouts: add `open_timeout:` and `timeout:` options to `APIProxy.call` (defaults unchanged when absent) and pass 5 s / 10 s from the job only. The default worker has one thread, so the worst case is about 1 minute of delay for `FedernuotoWatchJob`.
- It writes `Ops::Snapshot` key `kpi:<APIProxy.configured_base_url>` with `{ values: {users:, …}, status: ok|partial|unreachable|unauthorized|no_credentials, errors: {…} }`. On failure it keeps the previous `values` and updates only `status`.
- Without valid credentials it makes no call and records `no_credentials`. The strip then shows the last values with their age and "sign in to refresh".
- Because the key includes the API URL, switching servers in Settings shows "no data yet for <url>" and never the other server's numbers.
- The strip is `Kpi::StripComponent` in a lazy frame. Each tile links to its grid (`stats_path`, `api_import_queues_path`, `api_issues_path`, `api_users_path`).

**Season board snapshot** (`app/services/season_board/snapshot.rb`):
- Why: today every board GET, every POST and every frame reload runs a full `Builder#call`: DiskIndex scans 5 folders with JSON probes (`disk_index.rb:92-109`), DbIndex runs 2 queries, and ActivityLog reads its file once per row. POSTs build twice: `before_action :set_board` (`season_board_controller.rb:15, 82-85`), then the redirected `index` builds again (line 29). `CrawlPlanner` (`crawl_planner.rb:44`) and `SeasonRecheckJob` (`season_recheck_job.rb:31`) build too.
- Stored content: a serialisable summary in `Ops::Snapshot` key `season_board:<season_id>`. It holds `state_counts`, `unlinked_count`, `done_count`, the rows (`fin_event_id`, `name`, `date_text`, `last_date`, `url`, `state`, `state_detail`, `next_action` kind and params, `busy`, `flags`), `unmatched_sources` (base, paths, pending kind), `board_sql_paths`, `warnings`, `snapshot_checked_at` and a `fingerprint`.
- Fingerprint:
  - mtimes of `crawler/data/federnuoto-watch.json` and `season-board.json`;
  - directory mtimes of the 5 season folders `DiskIndex` scans (`disk_index.rb:83-87`). These change when files are added, removed or renamed, which includes atomic rewrites, but not on an in-place edit;
  - `count` and `maximum(:updated_at)` of the season's `calendars` and `meetings`;
  - the id of the last `Ops::Event` of the kinds `datafix.committed`, `datafix.purged` and `board.calendar_linked` (the kind names written by 01).
- `Snapshot.fetch(season)` returns the stored summary when the fingerprint matches and it is under 10 minutes old (catches in-place phase edits). Otherwise it runs `Builder#call` and stores the result. `Snapshot.store!(season, result)` is called by every full build: board index, `CrawlPlanner`, `SeasonRecheckJob`.
- `Snapshot.invalidate!(season_id)` is called next to every `SeasonBoard::Notifier.ping` (`notifier.rb:20-26`) and by the 01 commit and purge instrumentation. Ops unavailable: `fetch` builds live (no store).
- Board fixes:
  1. `ActivityLog` reads its file once per instance: `entries_hash` (`activity_log.rb:118-121`) is memoised, reset by `write_entry` and by a public `reload!`. This turns about 120 file reads for 119 rows into 1.
  2. `SeasonBoardController#find_row` (lines 89-99) looks the row up in `Snapshot.fetch` (fresh by fingerprint, URL from the stored row, never from params). `set_board` no longer builds a board, so a POST runs no build.
  3. The board's live refresh fetches `season_board_path(frame: 1)`, which renders only the frame partial.

**Remote-write log** (`app/models/ops/remote_write.rb`, hook in `app/strategies/api_proxy.rb`):
- `APIProxy.call` (`api_proxy.rb:113-122`) records every call whose method is not GET. It skips `url == 'session'` (sign-in) and `url.start_with?('import_queue/batch_sql')` (`push_controller.rb:192`; 07 tracks those).
- It runs after `execute`, inside `Ops.safely`, so it never raises and never changes the returned `Result`.
- Stored: method, endpoint path, base URL, status code, `unreachable`, the `error_detail` truncated to 300 chars, the payload keys only (no values), the user id, the source `controller#action` or job class (from a new `Current` attribute set in `ApplicationController` and `ApplicationJob`), and the time.
- Request specs stub `APIProxy.call` (for example `api_teams_controller_spec.rb:21`), so the hook is tested with WebMock on the real method.
- `RemoteWritesController#index` at `/remote_writes`: grid with filters on endpoint and status.

**Drift v0** (`app/services/drift/latest_updates_check.rb`, `app/jobs/drift_check_job.rb`, queue `default`, recurring every 30 minutes):
- It calls `GET tools/latest_updates` with `params: { max: 10 }` and the background JWT. The endpoint (`goggles_api/app/api/goggles/tools_api.rb:260-285`) returns the latest-updated rows of 12 tables: id, updated_at and 1-2 columns.
- For each table it checks that every remote id exists locally (`where(id:).pluck(:id)`). Timestamps are not compared, because SQL scripts write `NOW()` remotely.
- Verdict, stored in `Ops::Snapshot` `drift_v0:<api_url>`:
  - ok: every remote id exists locally and there is no `Ops::RemoteWrite` since `Ops::Setting.fetch('drift.acknowledged_at')`;
  - warn: remote ids missing locally (listed per table), or remote-only writes since that time;
  - unknown: no credentials, unreachable, or an API without the endpoint.
- "Acknowledge" on `/remote_writes` sets `drift.acknowledged_at`. 08 adds `Drift::Fingerprint` / `Verdict` to the same job and the red level.

## Data model

Ops migrations in `db/ops_migrate/`, applied with `bin/rails ops:prepare`:
- `create_remote_writes` (table `remote_writes`, model `Ops::RemoteWrite`; no `ops_` prefix, as for 01's `events`/`settings`/`snapshots`): `http_method` string not null; `endpoint` string not null; `base_url` string not null; `status_code` integer; `unreachable` boolean default false; `error_detail` string(300); `payload_keys` text (JSON array); `user_id` integer; `source` string; `created_at` datetime not null. Indexes: `created_at`, `[endpoint, created_at]`, `[base_url, created_at]`.
- No change to `snapshots`, `events` or `settings` (from 01): fingerprints and statuses live in the snapshot JSON. New snapshot keys: `kpi:<url>`, `season_board:<season_id>`, `drift_v0:<url>`. New setting keys: `background.user_id`, `drift.acknowledged_at`.
- MySQL: none.

## Ordered steps

1. **Board performance (internal).** `ActivityLog` memoisation, `SeasonBoard::Snapshot` with fingerprint and invalidation, `find_row` from the snapshot, frame-only refresh, `SeasonBoard::ActionPaths` extracted from `RowComponent`. Existing board specs stay green. Not user-visible, but faster: CHANGELOG "performance" line and PATCH bump.
2. **Background credentials and KPI job (internal).** `Ops::BackgroundCredentials`, the sign-in hook, the `APIProxy.call` timeout options, `KpiRefreshJob` plus its recurring entry, and no new queue: both jobs run on `default` (the `spec/config/queue_names_spec.rb` guard is created in 06). No UI yet. No bump.
3. **Remote-write log.** Migration, `Ops::RemoteWrite`, the `APIProxy.call` hook, `Current`, the `/remote_writes` page with its `Shell::Navigation` entry. User-visible: CHANGELOG + PATCH.
4. **Drift v0.** `Drift::LatestUpdatesCheck`, `DriftCheckJob` plus its recurring entry, the `DriftV0` probe. User-visible (status row): CHANGELOG + PATCH.
5. **Data-Fix sessions list.** `DataFix::SessionIndex`, `DataFix::StagingPurger`, `/data_fix/sessions` with its navigation entry. "Clean slate" stays on the old home page until step 6. User-visible: CHANGELOG + PATCH.
6. **Dashboard.** Inbox core, the v1 sources, the components, `DashboardController` with its frames, probes, activity feed, KPI strip and season progress, routes. Delete `HomeController`, `app/views/home/*`, `home.scss`, `DataFixController#purge` and its route. A live-frame Stimulus controller (generalised from `season_board_controller.js`) reloads frames on the `AppNotificationsChannel` ping, or every 20 s while something is busy. User-visible: CHANGELOG + PATCH.
7. **Docs.** `docs/season_board.md` (snapshot, ActionPaths), a new short `docs/dashboard.md` with the `Inbox::Source` and probe interfaces for 06, 07 and 10, the CLAUDE.md "Other subsystems" line. CHANGELOG line, no bump.

## Specs and manual verification

- `spec/requests/dashboard_controller_spec.rb`:
  - redirects when signed out;
  - with `APIProxy` stubbed with `receive(:call).and_raise`, `/` and every frame return 200 (proves no remote call);
  - renders in an API-offline session (set `session[:api_offline]`), with the crawler status file missing, and with ops unavailable (setup notice);
  - the KPI frame shows "unreachable" / "sign in to refresh" from the snapshot fixtures, never "0" for a missing value.
- `spec/services/inbox/builder_spec.rb`: band order, de-duplication by key and by file path, a raising source becomes a band-1 item, the 25-item cap. One spec per source with fixture files under `spec/fixtures` (reuse `spec/services/season_board/disk_fixtures.rb`). `Inbox::Item` raises without an action.
- `spec/services/season_board/snapshot_spec.rb`: the fingerprint changes on a file added to `results.new/<season>`, on an activity-log write and on an `Ops::Event` commit; it does not rebuild when nothing changed (count `Builder#call` calls). `activity_log_spec.rb`: one file read for N `for` calls.
- `spec/requests/season_board_controller_spec.rb`: a POST performs no `Builder#call` (`expect(SeasonBoard::Builder).not_to receive(:new)` with a fresh snapshot).
- `spec/strategies/api_proxy_spec.rb` with WebMock:
  - PUT, POST and DELETE write one `Ops::RemoteWrite`; GET, `session` and `import_queue/batch_sql` write none;
  - payload values are never stored;
  - a raising ops DB leaves the `Result` unchanged.
- `spec/jobs/kpi_refresh_job_spec.rb`: no call without credentials; partial failure keeps old values; the snapshot key includes the URL. `drift_check_job_spec.rb`: ok, warn and unknown verdicts.
- `spec/services/data_fix/staging_purger_spec.rb`: `purge!` deletes only the rows of one `phase_file_path`; `purge_all!` clears all five tables.
- Component specs: `Inbox::ItemComponent`, the status row, the KPI tile.
- Manual: start with the API down and the crawler stopped; open `/` (immediate render, red API row, "Start crawler" works). Queue a board crawl and watch "In progress" change without a reload. Edit a setting through an api_* grid and see the row in `/remote_writes` and drift v0 turn amber. Wait 10 h or clear `users.jwt` locally and see "sign in to refresh".

## Exit criteria

- `home#index` and the dashboard frames make no remote call in the request (spec with `APIProxy.call` raising), and the page renders API-offline.
- Every inbox item has exactly one primary action, and it lands on the right page with the right context (request spec per source).
- The four KPI counters are visible with their age and distinguish unreachable, no credentials and 0.
- A board POST does no full rebuild; `ActivityLog` reads its file once per instance.
- Every non-GET `APIProxy.call` other than `session` and `import_queue/batch_sql` leaves an `Ops::RemoteWrite`; drift v0 shows a level on the dashboard.
- No reference to `HomeController`, `app/views/home` or `data_fix_purge_path` remains in app, config or spec.
- `bundle exec rubocop` clean; en/it parity spec green.
- Routine gate: sign in → board → crawl → review → commit → report → push → confirm, starting from the dashboard.

## Risks and mitigations

- **Stale snapshot hides new work.** Mitigation: the fingerprint, a 10-minute TTL, invalidation on ping and events, and "as of" times on every zone. The board page itself always builds live on GET.
- **In-place edits of phase files do not change directory mtimes.** Mitigation: the TTL; 09 adds `mark_edited!`, which should call `Snapshot.invalidate!`.
- **KPI job delays the FIN watcher on the single-thread `default` worker.** Mitigation: explicit 5/10 s timeouts, 4 calls only.
- **Hooking `APIProxy.call` changes its call path for every request.** Mitigation: the hook runs after `execute`, inside `Ops.safely`, and the `Result` is untouched. Request-spec stubs replace `call` itself, so their exact `.with(...)` arguments still match. New options (`open_timeout:`, `timeout:`) are passed only by jobs.
- **Payloads could carry personal data.** Mitigation: keys only, never values, never headers.
- **Drift v0 sees only the latest 10 rows per table.** Mitigation: it is labelled "v0, partial"; 08 adds fingerprints.

## Decisions to confirm

- KPI refresh interval: default every 15 minutes, plus after sign-in and on demand.
- "API uses" semantics: default unchanged (row count of `api_daily_uses`, as `home_controller.rb:18`); alternative: the sum of today's uses.
- Goggle Cup count from the old Tools card: default dropped (sidebar link only).
- Remote-write payloads: default keys only; alternative: filtered values capped at 2 KB.
- Idle-session threshold for an inbox item: default 3 days.
- Snooze or dismiss for inbox items: default none in v1 (items disappear when their cause does).

## Out of scope

- The Outbox and push states (07), health items (06), "ready to commit" items (10), fingerprint drift and `/db_sync` (08), multi-season boards, a jobs admin page (mission_control-jobs), and the command palette (15).

## Rollback note

- Each step is a separate commit. Reverting step 6 restores `HomeController` and its views from git; the snapshot, KPI and drift jobs keep running harmlessly.
- The ops migration is additive. `bin/rails ops:rebuild` (01) or dropping `remote_writes` removes it, and no MySQL data is touched.
- Remove the `KpiRefreshJob` and `DriftCheckJob` entries from `config/recurring.yml` to stop the background calls.
