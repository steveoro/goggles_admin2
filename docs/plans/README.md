# goggles_admin2: operations console plan

UI/UX modernization and streamlined data maintenance, in 15 phases.

## Purpose

goggles_admin2 works, but the operator's week is spread over disconnected pages and a terminal. There is no overview of pending work. Every meeting needs about 20 deliberate clicks through five synchronous Data-Fix steps. Pull and Push lists reset after every upload, and admin2 never learns whether production applied a pushed script. About 30 rake tasks have no UI or history. There is no data-health view of closed seasons. The front end is dated (Bootstrap 4.6.2, jQuery, FontAwesome 4.7 from CDN, 47 views re-declaring the page wrapper, no sidebar or theme).

The goal is one "operations console": a persistent shell, an inbox-first landing page, background preparation of meetings up to review, a tracked SQL outbox, a closed-season health report with fixes, and maintenance operations in the UI.

In this repo, "staging" always means the import staging tables (`data_import_*`).

## How to use these plans

- One file per phase, listed in the Phases table below.
- Phases are delivered in numeric order.
- Each phase file is self-contained: goal, scope, steps, specs, exit criteria, risks, rollback.
- When a phase is finished, its file moves to `docs/plans/done/` and the Status column below is updated.
- Decisions listed as "to confirm" inside a phase file are settled when that phase starts.
- All phases are developed on the branch `feature/modernize-admin-console-ux`; `main` stays as it is until the whole plan is done, then the branch is merged. Any other framework project touched by a phase (e.g. goggles_db, goggles_api, goggles_main) gets a branch with the same name.
- Shared names and interfaces between phases (ops models, Outbox, Drift gate, queues, compat layer, inbox registry) are fixed in [contracts.md](contracts.md); the owning phase wins.

## Decisions taken with the operator

1. The dashboard is inbox first ("Needs you", "In progress", season progress; side column: system status and activity). The KPI counters (API uses, import queues, issues, users) stay.
2. Closed-season data-health report, expandable section by section, with mitigation actions (the operator's own requirement).
3. Automation boundary: jobs may crawl, extract manifests, build Data-Fix phases 1-5 and flag issues. Local commit and remote push always need a click.
4. "Ready to commit" rule: confidently-new swimmers/teams (no look-alike candidate) do not block and are listed on the commit summary. A new meeting, any team with a candidate, or more than 40 % new swimmers / 25 % new teams needs review.
5. Bootstrap 5.3, no jQuery, light/dark, new shell. goggles_main stays on Bootstrap 4.
6. Retire the legacy Data-Fix flow, after porting team-score import (MeetingTeamScore) to v2. Today only `MacroCommitter#commit_team_scores` does it.
7. A cross-project phase is allowed (goggles_api + goggles_main) for applied/failed push feedback and a trustworthy environment name.
8. DB drift: an indicator plus a guided restore wizard.
9. New operator state lives in a local SQLite "ops" DB inside goggles_admin2 (`db/ops/<env>.sqlite3`, gitignored), not in `storage/`, which is a symlink into goggles_api.
10. Order after the dashboard: health report, Outbox, push feedback, pipeline automation, health fix actions, wizard UX.
11. The staging environment is deprecated: no staging-then-production double push.

## Target design in brief

**Shell and navigation.** One layout: sidebar, top bar (API target badge, status pills, theme toggle, user menu), page header with breadcrumbs, toasts, Turbo progress bar. One Ruby navigation registry feeds the sidebar, the breadcrumbs and later the command palette.

**Front-end migration.** The framework switch comes first with the same layout, behind a temporary compatibility layer (`compat/_bs4.scss` plus `bs4_compat.js`, which copies `data-*` to `data-bs-*`), then the shell. Each page group goes native in the phase that rewrites it; stable groups are swept with the shell. Assets are vendored (Bootstrap JS via importmap, CSS and icons local) so the app and browser tests work offline. Icons: FontAwesome 6 Free plus v4 shims (no markup change). A small permanent compat subset stays scoped to the goggles_db goggle-cup partials.

**Ops DB.** An `ops:` entry with `database_tasks: false` and `schema_dump: false`, migrations in `db/ops_migrate`, `Ops::ApplicationRecord` (`connects_to`), and `rake ops:prepare|status|backup|reset|rebuild` (called by `solid:prepare`). Writes go through `Ops.safely`; disk stays the source of truth; pages degrade with a "run ops:prepare" notice. Models: `Ops::Event`, `Setting`, `Snapshot`, `SqlScript`, `PushRun`, `PipelineSource`, `PhaseVerdict`, `CommitReport`, `PipelineRun`, `HealthRun`, `HealthFinding`, `OperationRun`, `RemoteWrite`, `DbFingerprint`, `RestoreRun` (plus the `season_checklist_items` table of 13 and the ops `sessions` table of 14). Each table ships in the phase that first writes it: events, settings, snapshots (01), remote_writes (05), health (06), sql_scripts and push_runs (07), db_fingerprints (08), pipeline_sources, phase_verdicts, commit_reports and pipeline_runs (09), operation_runs (11), restore_runs (14). Phases 07 and 09 register their reconcilers in `Ops::Rebuilders` (run by `rake ops:rebuild`); events are written with `Ops.record_event!`. The existing JSON state files (season-board, federnuoto-watch, crawler-status) stay.

**Queues.**
- `default`: watcher, KPI refresh, status polls (quick jobs only).
- `background`: crawls and LLM extraction, unchanged.
- `maintenance`: health sweeps, operations, restore (worker added in 06).
- `outbox`: push runs (worker added in 07).
- `pipeline`: phase builds and the clicked commit (worker added in 09).

Concurrency keys: `local_db_writer` is shared by `DataFixCommitJob` (09) and `Maintenance::RunJob` in apply mode (11), because both write the local primary DB; `DataFixPrepareJob` (10) uses `data_fix_pipeline`; `Outbox::PushJob` uses `outbox_push`; board and source crawls and manifest extraction share `season_board`.

Unlisted queue names are never served (`config/queue.yml`), so the phase that first uses a queue adds its single-thread worker, and a spec compares every job's `queue_as` with `queue.yml`.

**Snapshots and background credentials.** Solid Cache exists only in development (test: null store, production: memory store). Values a job computes for the UI (KPI counters, status pills, board snapshot, drift) are therefore stored in the ops DB (`Ops::Snapshot`: key, JSON, taken_at), not in `Rails.cache`. Keys: `api.status:<base_url>` (04: reachability; 08 adds `environment` and `capabilities` to the same payload), `system_status.<probe_key>` (04), `kpi:<api_url>` and `season_board:<season_id>` (05), `drift_v0:<base_url>` (05, replaced by `Ops::DbFingerprint` rows in 08), `pdf_scan:<sha1>` (15). Background remote calls use the JWT stored on the last signed-in admin's user row; when it has expired, the UI shows "sign in to refresh" with the age of the last value.

## Invariants

These are restated in every phase plan.

- Jobs that commit, push, apply a maintenance script or restore (`DataFixCommitJob`, `Outbox::PushJob`, `Maintenance::RunJob` in apply mode, `RestoreJob`) are enqueued only by a controller action from an operator click, never by a scheduler, planner, callback or another job. Retries are disabled (spec-asserted). No bulk commit.
- "Staging" in these plans always means the import staging tables (`data_import_*`). The deprecated staging environment gets no new behaviour; its leftover config files are out of scope.
- Operator edits win: an automatic build never rewrites an edited phase file. The edit marker lives in the phase file `_meta` (mirrored in ops).
- Scripts are pushed in local-apply order (global sequence), never by file prefix alone.
- Dashboard and status surfaces make no synchronous remote call and render API-offline.
- No admin2-only tables in MySQL. File conventions (`NNNN-<base>-lt4.sql`, `results.new/sent/done/<season>`) stay readable by `DiskIndex` and `Backfill`.
- Every phase leaves the weekly routine working (the routine gate below).
- Repo conventions: `frozen_string_literal`, en and it keys, CHANGELOG plus PATCH bump per user-visible step, `rubocop -a` clean.

## Phases

| # | Phase | Operator sees | Depends on | Size | Status |
|---|---|---|---|---|---|
| 01 | [Safety net, ops DB, event log, quick wins](done/01-safety-net-ops-db.md) | File lists open on the current season and stay there | none | M | done (0.10.79) |
| 02 | [Legacy Data-Fix retirement (team scores ported first)](done/02-legacy-retirement.md) | One Data-Fix entry point (PDF scan opens v2); staging-environment leftovers gone | 01 | L | done (0.10.80) |
| 03 | [Bootstrap 5.3 switch + compatibility layer](03-bootstrap-5-switch.md) | Same pages, no jQuery, tooltips work in live content, light/dark | 01, 02 | M | planned |
| 04 | [App shell + native sweep of stable pages](04-app-shell.md) | Sidebar, top bar with API target, breadcrumbs, toasts | 03 | L | planned |
| 05 | [Inbox dashboard](05-inbox-dashboard.md) | "Needs you" list, in-progress jobs, season progress, system status, KPI strip | 01, 04 | L | planned |
| 06 | [Closed-season health report](06-season-health-report.md) | Seasons x checks matrix, drill-down, acknowledge/ignore, how-to-fix | 01, 04, 05 | L | planned |
| 07 | [SQL Outbox](07-sql-outbox.md) | One ordered list of scripts; push one/all; no folder picking | 01, 04, 05 | L | planned |
| 08 | [Remote loop closure + drift indicator (goggles_api, goggles_main)](08-remote-loop-closure-drift.md) | Applied/failed per script with error text; real environment name | 07 | M | planned |
| 09 | [Pipeline runner, verdicts, commit runner](09-pipeline-runner-verdicts.md) | Per-step verdicts and staleness; commit summary; persistent report | 01, 02, 07 | L | planned |
| 10 | [Pipeline automation up to review](10-pipeline-automation.md) | Clean meetings appear as "Ready to commit" with zero clicks | 05, 09 | M | planned |
| 11 | [Operations framework + health mitigations](11-operations-health-mitigations.md) | Fix buttons on findings: dry-run, apply, script in Outbox | 06, 07, 08, 09 | L | planned |
| 12 | [Data-Fix wizard UX](12-data-fix-wizard-ux.md) | Stepper, next-issue navigation, in-place saves, verify all | 04, 09 | L | planned |
| 13 | [Maintenance console (remaining operations, season-start checklist)](13-maintenance-console.md) | All rake maintenance available in the UI with history | 11 | L | planned |
| 14 | [Guided local DB restore](14-guided-db-restore.md) | Guarded wizard when drift is red | 07, 08 | M | planned |
| 15 | [Sources area, grid chrome, command palette, compat removal, docs](15-sources-grids-cleanup.md) | Pull becomes Sources; one grid look; Ctrl+K; no BS4 leftovers | 04, 10, 12 | L | planned |

## Dependency notes

01-05 are linear and the numbering is the agreed delivery order. Dependency notes only: after 05, 06 and 07 can run in parallel; 07 gates 08 and 09; 08 gates 11 and 14; 09 gates 10, 11 and 12.

Each line below reads "dependency -> phase"; the set of arrows into a phase equals its Depends-on column.

```
01 -> 02
01, 02 -> 03
03 -> 04
01, 04 -> 05
01, 04, 05 -> 06
01, 04, 05 -> 07
07 -> 08
01, 02, 07 -> 09
05, 09 -> 10
06, 07, 08, 09 -> 11
04, 09 -> 12
11 -> 13
07, 08 -> 14
04, 10, 12 -> 15

Main flow:
01 -> 02 -> 03 -> 04 -> 05 -+-> 06 ----------------------+
                            |                            v
                            +-> 07 -+-> 08 -+------------> 11 -> 13
                                    |       +-> 14        ^
                                    +-> 09 ----------------+
                                         +-> 10 -+
                                         +-> 12 -+-> 15
```

## Navigation map

Target sidebar groups:

- **Dashboard**
- **Import**: Season board, Sources, Data-Fix sessions, Outbox
- **Data quality**: Health, Operations, DB sync
- **Entities**: meetings and calendars (meetings, calendars, reservations); people and teams (swimmers, teams, badges, team affiliations, team managers); season setup (seasons, categories, standard timings, swimming pools)
- **Reports**: best results, Goggle Cup
- **Support**: users, issues, import queues, API stats, trainings, user workshops
- **System**: settings, jobs, activity log

The top bar (every page) carries the API target badge (name and URL from `/status` once 08 ships; port guess shown as "unverified" until then), status pills (API, crawler, job queue, live updates, FIN watcher, DB sync), theme toggle, user menu and the global progress bar and toasts.

| Today's page | Becomes | Phase |
|---|---|---|
| Home counters | KPI strip on the dashboard, linking to Support grids | 05 |
| Home "Data import" card | Import group in the sidebar | 04 |
| Home "Tools" card | Reports group | 04 |
| Home "Manage entities" card (13 links, 6 disabled) | Entities group; the disabled placeholders are dropped | 04 |
| Home "Latest updates" (staging vs production) | Removed; drift v0 on the dashboard, then the DB sync page | 02, 05, 08 |
| Home "Clean slate" | Per-source purge, then per-source discard in Data-Fix sessions | 01, 05 |
| Navbar "Commands" dropdown | Support and System groups | 04 |
| `/season_board` | Unchanged URL; rows gain "ready to commit" and "needs review at step N" | 10 |
| `/pull/index`, calendar files, PDFs, result files | Sources (season-aware) | 15 |
| `/pdf/*` | Sources, PDF scan as a job | 15 |
| Result-file list with gear and bolt icons | Data-Fix sessions list, one entry | 02, 05 |
| `/data_fix/review_*` | Same URLs with a stepper | 09, 12 |
| Commit report (one-shot) | Persistent report page and commit summary | 09 |
| `/data_fix_legacy/*` | Removed | 02 |
| `/push/index` | Outbox | 07 |
| `/api_import_queues` | Stays under Support; Outbox rows link to their remote queue row | 08 |
| Terminal rake tasks | Operations | 11, 13 |
| `/settings` | System > Settings | 04 |
| (new) Data health | `/health` matrix and per-season pages | 06 |
| (new) DB restore | Guided wizard under DB sync | 14 |

## Amendments found while detailing the phases

Corrections to the wording of the approved master plan, found when each phase was checked against the code:

1. In phase 03 only one markup-pinned spec file changes (`sql_create_modal_component_spec.rb`); the others change in 04 (grids, season board row) and 12 (Data-Fix phase 2/3 request specs).
2. `Ops::SqlScript` uses `rel_path` as its unique key and `sha256` (indexed, not unique) to follow moves; the master plan called sha256 the natural key.
3. goggles_api documentation is Swagger (`add_swagger_documentation`), not API Blueprint.
4. Commit durability needs a hook inside `Import::Committers::Main#commit_all` (07's `before_commit:` callable), not only in the controller or `CommitArchiver`.
5. The season-board snapshot needs a TTL plus DB counts and event ids for invalidation; directory mtimes alone are not enough (in-place phase edits change none).
6. Only PDF-derived sources carry team rankings; the FIN crawler output has none (Microplus not verified), so team scores (02) exist for PDF sources only.
7. `merge:season_fix` skips every candidate when no team filter is given (`0` is truthy in Ruby), so phase 13 defines the intended behaviour as a decision.
8. Gender-guessed swimmers are not in review today (forced to 89.9 % against a `< 89.0` filter); phase 09's `ReviewRules` flags them explicitly.
9. Docker: `db/ops` needs a volume mount, or the ops file dies with the container (phase 01).

## The routine gate

Every phase must still pass this end-to-end check, with the weekly routine working at the end of each phase:

sign in -> Season board -> crawl a meeting -> review -> commit -> read the report -> push the script -> confirm it on the import queue / Outbox.

## Conventions for every phase

- Every Ruby file starts with `# frozen_string_literal: true`.
- New copy gets both `en` and `it` i18n keys.
- Each user-visible step adds a `CHANGELOG.md` entry and a PATCH bump in `lib/version.rb`.
- `bundle exec rubocop -a` is clean.
- Never run a bare `bin/rails db:prepare` or `db:migrate`: it acts on the shared MySQL primary. Use `bin/rails solid:prepare`, which will also call `ops:prepare`.
- Specs live under `spec/{requests,services,strategies,components,jobs,models,system}`.

## Phase file template

Every phase file uses these section headings, in this order:

1. Goal
2. Operator-visible outcome
3. Depends on
4. Scope
5. Data model
6. Ordered steps
7. Specs and manual verification
8. Exit criteria
9. Risks and mitigations
10. Decisions to confirm
11. Out of scope
12. Rollback note

## Defaults taken (changeable when each phase starts)

- A failed remote script blocks later ones.
- Unattended manifest extraction is on by default, with capped retries.
- "Flag cancelled" is offered only with a dry-run; "ignore with note" otherwise.
- One commit click per meeting (no bulk commit).
- Stray scripts (old-subseeded, redo) are archived, not pushed.
- Engine goggle-cup partials keep a scoped compat subset.
