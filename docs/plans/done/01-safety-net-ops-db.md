# Phase 01 — Safety net, ops DB, event log, quick wins

## Goal

Lay the ground every later phase stands on, without touching any page that a later phase rewrites:

1. a browser-level safety net (system specs) on today's UI, plus characterization request specs for the per-phase Data-Fix orchestration;
2. a fifth local database, the SQLite **ops** DB (`db/ops/<env>.sqlite3`), with its first three tables (`events`, `settings`, `snapshots`) and real consumers;
3. a handful of controller-level quick wins and defect fixes that remove daily friction now.

## Operator-visible outcome

- Pull and Push file lists open on the current season folder (not the alphabetically first one, today `212`) and stay on it after an upload.
- The Season board "Push" action opens the Push list on the season folder of the pending script.
- "Push all" sends exactly the files listed on screen (the listing is recursive, the glob is not today).
- The staged `data_import_*` rows of one source can be discarded without wiping every other source ("Clean slate" stays).
- A missing or unprepared ops DB shows one clear "run `bin/rails ops:prepare`" notice instead of an error page.
- The relay-enrichment refresh icon renders; the "Team affiliations" home button shows its English label.

## Depends on

Nothing. First phase. Phase 02 needs the smoke suite and the event log from here.

## Invariants that apply here (from the master plan)

- No admin2-only tables in MySQL: every new table goes in the ops DB.
- Jobs that commit, push, apply or restore are enqueued only from an operator click. This phase adds no job. The instrumentation only records events, and an event write never blocks or fails a commit, push or job.
- "Staging" means the `data_import_*` import staging tables. The deprecated staging environment gets nothing new: no `staging:` entry for ops.
- File conventions stay (`NNNN-<base>-lt4.sql`, `results.new/sent/done/<season>`).
- Never run a bare `bin/rails db:prepare` / `db:migrate`, because it acts on the shared MySQL primary. Ops is prepared only by `ops:prepare` (called by `solid:prepare`).
- Repo conventions: `# frozen_string_literal: true` in every Ruby file; en + it keys; CHANGELOG + PATCH bump in `lib/version.rb` per user-visible step; `bundle exec rubocop -a` clean.

## Scope

### A. Safety net

| File | Action |
|---|---|
| `spec/support/system_test_helpers.rb` | new: `driven_by :selenium, using: :headless_chrome` (binary from `ENV['CHROME_BIN']` when set), `Devise::Test::IntegrationHelpers` + `AdminSignInHelpers` for `type: :system`, default `allow(APIProxy).to receive(:call).and_return(DummyResponse.new(body: '[]'))`, `expect_no_js_errors` (reads the `goog:loggingPrefs` browser log), skip the whole group when `ENV['SKIP_SYSTEM']` is set |
| `spec/system/*_spec.rb` | new: about 11 smoke journeys (list below) |
| `spec/requests/data_fix/phase_orchestration_characterization_spec.rb` | new: for each review GET (`review_sessions` … `review_results`, v2 flag set), records which phase files are written and their data digests on the `spec/fixtures/import/sample-200RA-l4*.json` fixtures, plus the Phase 5 staging row counts. Phase 09 must keep it green unchanged |

Infrastructure already present: `capybara` and `selenium-webdriver` (Gemfile test group, lines 114/125), `spec/support/admin_signin_helpers.rb` (`prepare_admin_user` issues a valid JWT), `spec/support/dummy_response.rb`, `show_exceptions = :none` and `Bullet.raise = true` in `config/environments/test.rb:31,67`. Do not reuse `features/support/*`: it is Cucumber-only and goes away in 02.

Network note: until 03 vendors the assets, the layout loads Bootstrap 4.6.2, FontAwesome 4.7, tom-select, jsoneditor CSS and jQuery from CDNs (`app/views/layouts/application.html.haml:12-26`). WebMock does not affect the browser, so system specs need network access. `SKIP_SYSTEM=1` excludes them; guard does not run them by default. Run `bin/rails dartsass:build` before the first run.

Smoke journeys (each ends with `expect_no_js_errors`):
1. Sign in through the form; home shows the four KPI cards with stubbed totals.
2. Navbar dropdown opens; Settings navigates; log out works.
3. Hovering a home help icon shows `.tooltip`.
4. API-offline sign-in: `#api-offline-help` on Settings; the home banner is still there after 4 s while the transient flash is gone.
5. `api_teams`: rows render, the filter panel expands, row edit opens `#grid-edit-modal` pre-filled, close hides it.
6. Grid selection toggle checks every `.grid-selector`.
7. Season board (Builder stubbed as in `spec/requests/season_board_controller_spec.rb`): rows render, a state chip filters, `#orphans-collapse` expands.
8. Data-Fix step 1 on a fixture copy: the meeting card collapses and expands, a field saves, the five step tabs render.
9. Data-Fix step 4: `#frm-add-event` has an initialised TomSelect (`.ts-wrapper`).
10. Pull result files: Edit opens `#file-actions-modal`; closing leaves no `.modal-backdrop`.
11. GogglesCup and Stats render (overlay hidden, chart canvas present).

### B. Ops DB

| File | Action |
|---|---|
| `config/database.example.yml` | add an `ops:` entry to `development`, `test`, `production` (not `staging`): `<<: *default_sqlt3`, `database: db/ops/<env>.sqlite3`, `migrations_paths: db/ops_migrate`, `schema_dump: false`, `database_tasks: false` |
| `config/database.docker.yml` | same `ops:` entry for `development`, `test`, `production` (its production queue/cable are MySQL; ops stays SQLite; `config/database.docker.yml:48-59`) |
| `docker-compose.yml` | admin2 service (`steveoro/goggles-admin2`, line 39; its volumes are at lines 49-54): add volume `~/Projects/goggles_deploy/ops.prod:/app/db/ops`, otherwise the file dies with the container (see Decisions) |
| `.gitignore` | add `/db/ops/`. The existing `/db/*.sqlite3` rule (line 12) covers only the top level |
| `config/database.yml` (gitignored, operator's copy) | manual step, documented in the CHANGELOG entry and in CLAUDE.md: paste the `ops:` block |
| `db/ops_migrate/<ts>_create_events.rb`, `<ts>_create_settings.rb`, `<ts>_create_snapshots.rb` | new, `ActiveRecord::Migration[8.1]`, written by hand (`rails g migration --database=ops` cannot see a hidden config) |
| `app/models/ops.rb` | new `module Ops`: `available?`, `state`, `safely { }`, `record_event!(**attrs)` |
| `app/models/ops/database.rb` | new `Ops::Database`: `db_config`, `configured?`, `state`, `prepare!`, `backup!(label:)`, `needs_migration?` |
| `app/models/ops/application_record.rb` | new abstract class; calls `connects_to database: { writing: :ops }` **only when `Ops::Database.configured?`**, so eager loading never crashes boot when the entry is missing |
| `app/models/ops/event.rb`, `app/models/ops/setting.rb`, `app/models/ops/snapshot.rb` | new models |
| `lib/tasks/ops.rake` | new: `ops:prepare`, `ops:status`, `ops:backup`, `ops:reset confirm=<env>`, `ops:rebuild` |
| `lib/tasks/solid.rake` | `solid:prepare` invokes `ops:prepare` last, so `entrypoints/docker.sh:35` and the one documented command keep working |
| `spec/rails_helper.rb` | call `Ops::Database.prepare!` before `ActiveRecord::Migration.maintain_test_schema!` (line 64), which never sees a `database_tasks: false` config |
| `app/views/goggles/_ops_setup_notice.html.haml` + one render line in `app/views/layouts/application.html.haml` (next to the API-offline banner, lines 39-41) | notice shown to signed-in users when `Ops.state != :ready` |
| `bin/setup` | line 28 runs `bin/rails db:prepare`; replace with `bin/rails solid:prepare` and a printed hint for loading the primary DB from a dump |
| `CLAUDE.md` | one paragraph: ops DB, `ops:prepare`, the manual `database.yml` step, `SKIP_SYSTEM` |

New API (signatures):

```ruby
module Ops
  def self.available?            # => true only when state == :ready (never creates the file)
  def self.state                 # => :not_configured | :missing | :needs_migration | :ready
  def self.safely(default = nil)  # yields; on any StandardError logs a warning, retries once on
                                  # ActiveRecord::StatementTimeout (SQLite busy), returns default
  def self.record_event!(kind:, level: 'info', actor: 'system', season_id: nil,
                         subject_type: nil, subject_key: nil, data: {}, link_path: nil)
end

class Ops::Database
  def self.db_config   # configs_for(env_name: Rails.env, name: 'ops', include_hidden: true)
  def self.configured?
  def self.state
  def self.prepare!    # create dir + file, backup! when migrations are pending on a non-empty DB,
                       # migrate inside DatabaseTasks.with_temporary_connection(db_config); seeds db_epoch
  def self.backup!(label: 'manual')  # VACUUM INTO 'db/dump/ops-<env>-<label>-<UTC ts>.sqlite3'; keeps 10
end

class Ops::Setting < Ops::ApplicationRecord
  def self.fetch(key, default = nil)
  def self.store!(key, value)
  def self.db_epoch    # Integer, seeded to 1 by prepare!; bumped by phase 14's restore
end

class Ops::Snapshot < Ops::ApplicationRecord
  def self.write!(key, payload, source: nil)     # upsert on key, sets taken_at
  def self.read(key)                             # => record or nil (payload, taken_at, source)
end
```

`prepare!` migrates only from rake or suite boot: migrating swaps the connection pool, so it never runs inside the server. `ops:reset` refuses while `tmp/pids/server.pid` points to a live process, and takes a backup first. `ops:rebuild` in this phase only prints "nothing to rebuild yet"; it holds a registry (`Ops::Rebuilders.register(name, callable)`) that 07 (Outbox reconciler) and 09 (pipeline) fill.

Table-to-model names are fixed for all later phases: `events` -> `Ops::Event`, `settings` -> `Ops::Setting`, `snapshots` -> `Ops::Snapshot` (no `ops_` table prefix). Snapshot keys introduced later: `api.status:<base_url>` (04, extended in 08), `system_status.<probe_key>` (04), `kpi:<api_url>` and `season_board:<season_id>` (05).

### C. Event instrumentation (all through `Ops.record_event!`, i.e. `Ops.safely`)

| Call site (verified) | Event kind |
|---|---|
| `app/controllers/data_fix/commits_controller.rb#commit_phase6` (def line 9; report stored at line 181) | `datafix.committed` / `datafix.commit_failed` (data: sql filename, season, first error) |
| `app/controllers/push_controller.rb#push_file_and_move` (line 188) | `push.uploaded` / `push.failed` (data: file, remote import-queue id or msg) |
| `app/controllers/data_fix_controller.rb#purge` (line 15) | `datafix.purged` (data: counts, scope `all` or the source path) |
| `app/jobs/meeting_crawl_job.rb#finish!` (line 150) | `board.crawl_finished` / `board.crawl_failed` |
| `app/jobs/manifest_extract_job.rb#finish!` (line 73) | `board.extract_finished` / `board.extract_failed` |
| `app/strategies/season_board/calendar_linker.rb#call` (line 56) | `board.calendar_linked` |
| `app/services/federnuoto_watch/checker.rb#call` (line 35), outcome `:changed` | `fin.watch_changed` |

Event text is rendered later (05) from `ops.events.<kind>` i18n keys. Add the keys now in `config/locales/ops.en.yml` and `config/locales/ops.it.yml`, together with the setup-notice strings (`ops.setup_notice.title`, `.body`).

### D. Quick wins (controller-level)

| Item | Where (verified) | Change |
|---|---|---|
| Default folder | `app/controllers/file_list_controller.rb:53` (`@curr_dir = @dirnames.first || …`) | on GET honour `params[:curr_dir]` when it is in `@dirnames`; otherwise `data/<parent_folder>/<SeasonDefaults.default_season_id>` when present; otherwise the first. Serves both `PullController` and `PushController` (both subclass it) |
| Upload keeps the folder | `push_controller.rb:115` `redirect_to(push_index_path)` | redirect with `parent_folder:` and `curr_dir:` derived from the pushed path |
| Push-all = listing | `push_controller.rb:100-101` globs `crawler/<curr_dir>/*.sql`; the listing globs `**/*.sql` (`file_list_controller.rb:54`); the button builds `File.join(curr_dir, '*.sql')` (`app/views/file_list/_file_table.html.haml:7`) | the controller expands a trailing `*.sql` recursively with the same `.sort` as the listing. Also reject any `file_path` that does not resolve under `crawler/data` |
| Board Push lands on the folder | `app/components/season_board/row_component.rb:104-105` (`when :push then push_index_path`) | `push_index_path(curr_dir: <dir of action[:sql_path], relative to crawler/>)`. Whether `sql_path` is absolute or relative is not verified: strip everything up to `crawler/` |
| Per-source purge | `data_fix_controller.rb#purge` (route `delete 'data_fix/purge'`, `config/routes.rb:102`) | optional `source_path` param: delete only rows `where(phase_file_path: source_path)` across the five `data_import_*` tables (same list as `DataFix::SourceResolver#invalidate_category_dependent_artifacts`, `source_resolver.rb:427-435`); without the param, behaviour is unchanged. Entry point: one discard button per distinct `phase_file_path` in `app/views/home/_data_import.html.haml` (next to "Clean slate", line ~42). Home is rewritten in 05, which moves this deletion into `DataFix::StagingPurger` (introduced there, same scope) and the `/data_fix/sessions` list |

### E. Defects

| Defect (verified) | Fix |
|---|---|
| `app/controllers/data_fix/swimmers_controller.rb:48` digs `('meeting','header_date')`, but `PhaseFileManager#data` (`app/services/phase_file_manager.rb:54`) already returns the `data` hash, so `meeting_date` is always nil | `PhaseFileManager.new(phase1_path).data['header_date'].presence || source_resolver.source_meeting_date(source_path)` (same pattern as `sessions_controller.rb:64`) |
| `app/controllers/pdf_controller.rb:23` builds a shell string from `@file_path` | `system('pdftotext', '-layout', @file_path.to_s, @txt_pathname.to_s)` (array form) |
| `app/views/data_fix/_relay_enrichment_panel.html.haml:60` uses `fa-sync-alt` (FA5 name; FA 4.7 is loaded) | `fa-refresh` |
| `config/locales/dashboard.en.yml:72` key `team_affiliation`, but the view uses `dashboard.team_affiliations.title` (`app/views/home/_manage_entities.html.haml:16`; it is already `team_affiliations` in `dashboard.it.yml:72`) | rename the en key |
| Missing translations pass silently (`config/environments/test.rb:58`, commented out) | `config.i18n.raise_on_missing_translations = true`; new `spec/i18n_parity_spec.rb` asserting that the en and it key sets of every `config/locales/*.{en,it}.yml` pair are identical |

## Data model (ops migrations)

All in `db/ops_migrate/`, native SQLite JSON columns, MySQL ids as plain integers.

| Table | Columns | Indexes |
|---|---|---|
| `events` | `occurred_at` datetime NOT NULL, `kind` string NOT NULL, `level` string NOT NULL default `info` (info/success/warning/error), `actor` string NOT NULL default `system` (operator/job/system), `season_id` integer, `subject_type` string, `subject_key` string, `data` json NOT NULL default `{}`, `link_path` string, `created_at` | `occurred_at`; (`kind`, `occurred_at`); (`subject_type`, `subject_key`) |
| `settings` | `key` string NOT NULL, `value` json, timestamps | unique `key` |
| `snapshots` | `key` string NOT NULL, `payload` json NOT NULL, `source` string, `taken_at` datetime NOT NULL, timestamps | unique `key` |

Events are append-only and pruned after 180 days by `ops:prepare` (cheap `DELETE … WHERE occurred_at < ?`). Settings and snapshots are small key/value tables. Snapshots get their first writers in 04/05.

## Ordered steps

1. **System spec harness + smoke journeys + characterization spec.** Not user-visible; no CHANGELOG entry needed.
2. **Ops DB wiring** (config entries, `.gitignore`, `docker-compose.yml` volume, `Ops`, `Ops::Database`, `ApplicationRecord`, three migrations, `ops.rake`, `solid:prepare` hook, `rails_helper`, setup notice, `bin/setup`, CLAUDE.md). User-visible (manual `database.yml` step, notice): CHANGELOG + PATCH bump.
3. **Event instrumentation** (section C) + `ops.*` locale files. Not visible until 05; CHANGELOG line under the same release as step 2 is enough.
4. **File-list quick wins** (default folder, upload keeps folder, push-all = listing + path guard, board Push folder). User-visible: CHANGELOG + PATCH bump.
5. **Per-source purge.** User-visible: CHANGELOG + PATCH bump.
6. **Defects + i18n hygiene** (section E). Do the `raise_on_missing_translations` switch last and fix every key it surfaces. User-visible (icon, label): CHANGELOG + PATCH bump.

Each step is independently shippable; 3 needs 2.

## Specs and manual verification

| Spec | Proves |
|---|---|
| `spec/system/*_spec.rb` (11 journeys) | today's UI behaviour, as a baseline for 03/04 |
| `spec/requests/data_fix/phase_orchestration_characterization_spec.rb` | phase files written by each review GET + Phase 5 row counts |
| `spec/models/ops/database_spec.rb` | `state` for not-configured / missing / needs-migration / ready; `state` never creates the file; `backup!` writes and rotates to 10 |
| `spec/models/ops_spec.rb` | `safely` swallows and logs, retries once on `StatementTimeout`; `record_event!` is a no-op returning nil when unavailable |
| `spec/models/ops/{event,setting,snapshot}_spec.rb` + `spec/factories/ops/*.rb` (`factory :ops_event, class: 'Ops::Event'`) | validations, `Setting.fetch/store!`, `db_epoch` seed, `Snapshot.write!` upsert |
| `spec/tasks/ops_rake_spec.rb` (new folder `spec/tasks/`) | `ops:prepare` idempotent; `ops:reset` refuses with a live pid file or a wrong `confirm` |
| `spec/requests/data_fix/commits_controller_events_spec.rb`, additions to `spec/requests/push_controller_spec.rb` | one event row per commit / push; an ops failure (stubbed) does not change the response |
| additions to `spec/jobs/meeting_crawl_job_spec.rb`, `manifest_extract_job_spec.rb`, `spec/strategies/season_board/calendar_linker_spec.rb`, `spec/services/federnuoto_watch/checker_spec.rb` | event written on finish / link / change |
| additions to `spec/requests/pull_controller_spec.rb`, `push_controller_spec.rb` | default folder from `SeasonDefaults`; upload redirect keeps folder; push-all pushes the recursive listing; path outside `crawler/data` refused |
| `spec/components/season_board/row_component_spec.rb` | Push link carries `curr_dir` |
| `spec/requests/data_fix_controller_purge_spec.rb` | scoped purge deletes only that source's rows in all five tables; unscoped purge unchanged |
| `spec/requests/data_fix_controller_phase3_spec.rb` (addition) | relay-enrichment detector receives the Phase 1 header date |
| `spec/requests/pdf_controller_spec.rb` (addition) | a file name with spaces/quotes is passed as one argument |
| `spec/i18n_parity_spec.rb` | en/it key parity |

Manual checks:
- Delete `db/ops/development.sqlite3`: the app boots and shows the notice; `bin/rails solid:prepare` recreates it; `bin/rails ops:status` reports `ready`.
- Remove the `ops:` block from the local `database.yml`: the app still boots (development and `RAILS_ENV=production` with eager loading) and shows "not configured".
- `git check-ignore db/ops/development.sqlite3` matches.
- Run a commit and a push on a scratch source; `Ops::Event.order(:occurred_at).last(2)` shows both.

## Exit criteria

- Smoke suite and the full existing suite green (system specs with network; `SKIP_SYSTEM=1` run also green).
- `bin/rails ops:prepare` creates the DB from nothing and is idempotent; no `db/*_schema.rb` or `db/structure.sql` changes after any rake run.
- A Phase 6 commit and a push each leave exactly one `Ops::Event` row; with ops missing both still succeed.
- File lists open on the default season folder; push-all count equals the listing count.
- `rubocop -a` clean; en/it parity spec green; CHANGELOG + `lib/version.rb` bumped for steps 2, 4, 5, 6.
- **Routine gate:** sign in → board → crawl → review → commit → report → push → confirm still works, no slower than before.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| A bare `db:migrate` / `db:prepare` touches ops or dumps a schema | `database_tasks: false` hides the config from every Rails DB task; `schema_dump: false`; no `db/ops_schema.rb` exists to be emptied |
| Eager loading crashes boot when `ops:` is missing | conditional `connects_to`; spec boots with the entry removed |
| SQLite busy under Puma threads + Solid Queue workers + rake | Rails 8.1 SQLite defaults (WAL, IMMEDIATE, busy handler) + `timeout: 5000`; short transactions; `safely` retries once |
| `raise_on_missing_translations` turns many specs red at once | done as the last step, keys fixed in the same step |
| System specs flaky without network / Chrome | `SKIP_SYSTEM`; guard excludes them; documented |
| Docker container loses the ops file | volume mount in `docker-compose.yml` |

## Decisions to confirm (default taken)

1. Docker production ops file: **default: mounted volume `~/Projects/goggles_deploy/ops.prod`**. Alternative: no ops entry in docker (pages degrade).
2. Per-source purge entry point before 05: **default: one button per source on home `_data_import`**. Alternative: controller param only, UI in 05.
3. Event retention: **default: 180 days**.
4. Backups kept: **default: 10**, under `db/dump/` (already gitignored, `.gitignore:54`).

## Out of scope

- Persistent commit report (`Ops::CommitReport`): phase 09. The session-based report stays.
- Any KPI/board snapshot writer (04/05), the ops-backed activity feed (05).
- Pointing the PDF-scan DATA-FIX link to v2: phase 02, after team scores are ported.
- Vendoring CDN assets (03). `staging:` entries in the database files (deprecated environment).

## Outcome (done, 0.10.79, 2026-11-21)

Delivered as one commit on `feature/modernize-admin-console-ux`. All four decisions above were confirmed with their defaults. Full suite green (2897 examples, browser specs included), rubocop clean. Notes for later phases:

- `Ops::Database` also exposes `database_path`, `needs_migration?`, `reset_state!`, `backups` and `with_isolated_connection`; its file helpers live in `Ops::Database::Files`. `prepare!` returns `{ state:, migrated:, backup:, pruned: }`. Any Ops query with no `ops:` entry raises `Ops::NotConfiguredError`. The `:ready` state is cached for 60 s per process.
- `Ops::Rebuilders` is reloadable: phases 07 and 09 must register inside `Rails.application.config.to_prepare`.
- Event subject types in use: `source` (Data-Fix), `sql_file` (push), `fin_event` (board), `fin_watch`. Push event recording lives in `app/controllers/concerns/push_event_recorder.rb`.
- The operator's `config/database.yml` has ops entries for development and test only.
- `raise_on_missing_translations` is on in test, except the goggles_db optional `alt_label_*` / `long_label_*` lookups (handler in `config/environments/test.rb`).
- System spec helper patches Capybara 3.40's Chrome reset (Chrome 158 rejects `Storage.clearDataForOrigin` with origin `*`).
- Behaviour recorded by the characterization spec: a review GET with an existing phase file rewrites that file's `_meta` only (`sync_phase_retry_flag!`). Phase 09 must keep this or change it on purpose.
- For 03/04: opening the grid edit modal on a row with a `city_id` makes the browser call the real API; Turbo hover-prefetch of `/stats` from the home KPI card 500s when the API reply is not valid JSON.

## Rollback note

Every step reverts with its own commit. Removing the ops wiring leaves an orphan `db/ops/` folder (gitignored, harmless) and the `ops:` block in the operator's `database.yml`, which Rails then ignores. The quick wins are independent controller changes. Event writes are side effects only, so removing them changes no behaviour.
