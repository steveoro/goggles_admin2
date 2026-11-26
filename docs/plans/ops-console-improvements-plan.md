# goggles_admin2: operations console improvements (round 2)

**Status:** approved 2026-11-26; in progress on `feature/ops-console-improvements`. Requirements: [ops-console-improvements.md](ops-console-improvements.md).

| Step | Status |
|---|---|
| 0 branch | done |
| 1 progress strip | done (0.10.98) |
| 2 board rows | done (0.10.99) |
| 3 status pills | done (0.10.100) |
| 4 switches and filter | done (0.10.101) |
| 5 link adoption | done (0.10.102) |
| 6 calendar automation | planned |
| 7 clean-up | planned |
| 8 docs | planned |

## Context

The 15-phase operations console is merged on `main` (0.10.97 on origin). After testing it, the operator listed six improvements in `docs/plans/ops-console-improvements.md` and asked for further UX ideas. Three explorations and one design pass (all verified against the code and the live data files) found that two of the six items are symptoms of real bugs:

- **Item 1 (blocker, stuck progress dialog).** The review GETs for teams, swimmers and results broadcast a "ready" message that *opens* the modal (`data_fix/teams_controller.rb:55`, `swimmers_controller.rb:113`, `results_controller.rb:240`). Turbo's hover prefetch of the stepper tabs fires those GETs with no click. Nothing closes an open modal on navigation: `progress_modal_controller.js` disposes without hiding, and no `turbo:before-cache` clean-up exists.
- **Item 2 (disabled "Riprendi passo N").** `SeasonBoard::Scheduler.prepare!` (`scheduler.rb:92`) never passes `fin_event_id` to `DataFixPrepareJob`, so the job cannot close its activity entry. The row stays "prepare queued" (busy) for 12 hours after the job finished: the button is disabled, the row drops out of the "Needs you" inbox, and the board polls every 20 s.
- **Second bug, confirmed.** `PipelineIndex#fresh?` (`pipeline_index.rb:177`) compares the oldest verdict time with the newest file of the source, so a just-prepared source is never "fresh". A source that is ready to commit shows "needs review at step 5" (FIN 150094 today), and the planner re-queues a useless prepare for it.
- **Item 6 (redundant files).** They come from the Sources "calendar results" crawl, which has no tidy-up step (the board's per-meeting crawl has one: `SeasonBoard::CrawlOutput`).
- **Items 4-5.** Nothing starts a calendar crawl automatically, and "processing a calendar" only crawls every meeting in it (files only: no API or DB write).

Outcome wanted: the blocker and the two bugs fixed, the FIN change handled end to end without clicks up to "ready to commit / needs review", and the agreed UX extras.

## Decisions taken with the operator

1. The FIN alert dismisses itself once every new or changed meeting with a link is **in the pipeline** (crawled and on the board), not only when committed.
2. After an automatic calendar crawl, only **new or changed** meetings are crawled.
3. A change with nothing to crawl (row added without link, row removed, text only) is **logged**: Activity event plus a dismissible inbox item, no sticky alert. Removed rows get a "removed from FIN" flag.
4. Extras included: non-blocking progress strip, board keeps its place, link-less rows adopt the 'Eventi' calendar link, compact status pills.

Unchanged invariants: jobs may crawl, extract and build phases 1-5; local commit, remote push, maintenance apply and restore always need an operator click. Operator edits win. Every automation checks `DataFix::Automation` (fail closed) and `ADMIN2_AUTOMATION=0`. `spec/automation_boundary_spec.rb` keeps its enqueue-site list.

## Steps

Each step is shippable: its own CHANGELOG entry and PATCH bump, en + it keys, `rubocop -a`, specs, system specs in both themes where the UI changes.

### Step 0: branch
- Branch `feature/ops-console-improvements`.
- Commit the operator's staged doc changes there (the two renames to `docs/plans/done/00-ops-console-masterplan-*.md` and the improvements doc; never `crawler/crawler-status.json`), then merge `origin/main` (0.10.97).
- Fix the references to the old `docs/plans/README.md` / `contracts.md` paths (CLAUDE.md, docs, spec comments).
- Save this plan as `docs/plans/ops-console-improvements-plan.md`.

### Step 1 (0.10.98): progress strip replaces the modal — item 1
- New `Shell::ProgressStripComponent`, rendered once in `layouts/application.html.haml` under the top bar: hidden by default, `role="status"`, close button, no backdrop.
- Delete `app/views/goggles/_modal_progress.html.haml`, its render in the five `data_fix/review_*.html.haml`, and `progress_modal_controller.js`.
- Protocol in `app/strategies/import/progress.rb`:
  - `Cable.new(scope:)` sends `{op, seq, scope, msg, progress, total}`;
  - `#done` sends `{op, state: 'done'}` only if a tick was sent.
- `DataFix::BaseController#progress_sink` passes the scope; an `after_action` calls `done`. `Pipeline::Recipes.progress_option` always passes the pipeline's sink to the solvers.
- Remove the three GET "ready" broadcasts.
- New `progress_strip_controller.js`: resets on a new `op`, ignores an older `seq`, hides on `done` and after 8 s of silence, resets on `turbo:before-cache` and `disconnect`.
- `channels/import_status_channel.js` subscribes once at module load (as `app_notifications_channel.js` does).
- `<meta name="turbo-prefetch" content="false">` in the layout: several GETs build phases or write metadata.
- Specs:
  - remove the Cable→Null stubs (`data_fix_review_journey_spec.rb:72`, `data_fix_spec.rb:56,104`) and `wait_for_progress_modal`;
  - new `spec/system/data_fix_progress_strip_spec.rb`: strip shows while tabs stay clickable; Back shows none; `done` hides it;
  - request specs: no broadcast on a plain review GET.

### Step 2 (0.10.99): board rows tell the truth — item 2 and both bugs
- `scheduler.rb:92`: add `fin_event_id:` to `job_args`. `DataFixPrepareJob` closes its activity entry on every exit path: start-guard refusals, `source_missing`, ops unavailable, and the DB-restore skip in `ApplicationJob`.
- `PipelineIndex#fresh?`: compare each verdict with the files its fingerprint covers (working copy + phase files 1..N), never the LT2.
- `PipelinePlanner#prepare_request`: skip a plain `rebuild_stale` when the last run ended `done` after the newest file (`:unchanged_since_run`).
- New `SeasonBoard::ActivityReconciler`, run at the top of `PipelinePlannerJob#perform`:
  - closes a busy prepare entry whose `Ops::PipelineRun` is finished;
  - closes a queued entry older than 2 minutes with no live Solid Queue job, as "lost".
- Review link:
  - `PipelineIndex::Facts` gains `leased`; `Row#locked?` exposes it; the snapshot stores it (bump `FORMAT_VERSION`);
  - in `season_board/row_component.html.haml:45-47` a GET action renders as a link unless `row.locked?`; POST actions stay disabled while busy;
  - same relaxation in `inbox/sources/pipeline_rows.rb:76` and `board_rows.rb:45`.
- `Inbox::Sources::FailedJobs::RETRY_KINDS` gains prepare.
- `SourceCrawlJob` records a done crawl entry per FIN id of its new files (`ActivityLog#record_many!`), so "last crawl" is right after a Sources crawl.
- Specs:
  - `pipeline_index_spec`: mtime tables;
  - `pipeline_planner_spec`: no re-queue;
  - `scheduler_spec:82-83`: pinned args;
  - `data_fix_prepare_job_spec`: one example per exit path;
  - `activity_reconciler_spec`, `row_component_spec`, the inbox source specs, `spec/system/season_board_spec.rb`.

### Step 3 (0.10.100): compact status pills — extra
- New `Shell::StatusPillsComponent` in `app/views/shell/status/show.html.haml`:
  - all OK: one pill with a tooltip listing the probes, linking to the dashboard system column;
  - otherwise: one pill per warn/error/unknown plus an "N OK" pill.

### Step 4 (0.10.101): switches and board filter — item 3 + extra
- New `Switch::ToggleFormComponent` (Bootstrap `.form-switch`) and `toggle_submit_controller.js` (`requestSubmit` on change, revert on failure). The users grid switch stays as it is.
- `automation/_switches.html.haml` uses it; `AutomationController#switch` answers `turbo_stream` (both switch panels, the board badge, the flash). The board's `<details>` stays open.
- New UI switch for `operations.enabled`: `Maintenance.store_enabled!`, `POST operations/switch`, shown in the dashboard system column and the `/operations` header.
- Row hold becomes an "Auto-prepare" switch (`SeasonBoardController#hold` answers `turbo_stream`). The phase-5 overwrite toggle uses the component and keeps its redirect.
- Board filters: cookie `season_board_filters` (validated JSON); `assign_filters` stores on explicit params and restores otherwise, so POST redirects and the sidebar link keep the chip.

### Step 5 (0.10.102): link-less rows adopt the 'Eventi' link — extra
- New `SeasonBoard::CalendarIndex`: newest `<date>-<season>-2-FIN-calendar.csv` in `calendar.new` / `calendar.done`, parsed with `CrawlerCalendar::Sheet`; key = first date, last date, normalized places.
- Adopt only when all hold:
  - exactly one CSV row and one watcher row share the key;
  - the watcher row has no link and the CSV row is not cancelled;
  - the FIN id is on no other row.
- Self-check: if more than 10 % of the comparable keys disagree on the FIN id, adopt nothing and show a board warning.
- `Builder` takes `calendar_index:` and flags the row `:link_adopted`; `Snapshot::Fingerprint` adds the two calendar folders.
- `MeetingCrawlJob#snapshot_url_for` accepts an adopted id (re-derived in the job).
- Adoption is derived, never stored in the watcher state. On today's data: 7 rows adoptable, 0 ambiguous.

### Step 6 (0.10.103): calendar automation chain — items 4 and 5
- New switch `auto_calendar` in `DataFix::Automation::SWITCHES` (default on, fail closed).
- `Scheduler.calendar_crawl!(season:, origin:)` enqueues a `SourceCrawlJob` (kind `calendar`, sub-menu 'Eventi') through `Sources::CrawlRequest`, sharing the manual crawl's activity key. An auto run refuses when the switch is off, sends no toast and fails on an empty CSV.
- New `SeasonBoard::CalendarPlanner`: queues only when a change is pending, no calendar crawl finished since `detected_at`, and the last attempt is older than 6 hours.
- Meetings are crawled one by one with the existing `MeetingCrawlJob` (it already tidies up, is throttled and retriable, and names files like the board's). `CrawlPlanner#call` also takes adopted rows, max 15 per pass.
- `PipelinePlannerJob#perform` order: reconcile → switch check → `CalendarPlanner` → `CrawlPlanner` → `PipelinePlanner` → auto-acknowledge.
- New `FedernuotoWatch::Parity`, read from the board snapshot. An actionable row (added / updated / with_results, with a watcher or adopted link) is at parity when it is not busy and its state shows it was crawled:
  - not at parity: `link_not_crawled`, `results_ready`, `structure_ready`, `crawled_no_manifest`, `manifest_pending`;
  - a "results published" row in `structure_committed` counts only after a crawl since the detection.
- New `FedernuotoWatch::Acknowledge` (also used by the manual dismiss):
  - `StateStore#acknowledge!(expected_digest:)`: no-op if a newer snapshot landed;
  - clear broadcast to every tab;
  - event `fin.watch_acknowledged`.
- Nothing to crawl: `Checker#notify` skips the sticky alert; event `fin.calendar_notice`; new `Inbox::Sources::FINNotice` with "Dismiss". `FINWatchProbe` warns only for an actionable change.
- "Removed from FIN" flag: `StateStore` keeps `removed_rows` (renames excluded); `Builder` shows the row only when a calendar or disk entry exists.
- Remove the unused `federnuoto_watch#pull_calendar` route and action.
- `SeasonRecheckJob` adds one daily 'Eventi' crawl (same switch): links can appear there with no change on the watched page.

### Step 7 (0.10.104): clean-up — item 6
- New `Sources::CrawlTidy`: after a `SourceCrawlJob` of kind `calendar_results` / `fin_meeting`, run `SeasonBoard::CrawlOutput` per FIN id of the new files (rules unchanged).
- New `Sources::CalendarTidy`: moves superseded originals, orphan `-sel-` files and `-skip` files from `calendar.new` to `calendar.done`. Never the newest original, a file younger than 10 minutes, or one named by a busy entry.
- New page `GET/POST /sources/cleanup` (`Sources::Cleanup::Plan` / `Apply`, `Shell::Navigation` child) for what is already on disk: dry-run list first; apply re-plans and refuses on a changed digest.
  - Result-free LT2 of a linked meeting with no LT4 or phase files → moved to `results.backup/<season>/cleanup-<ts>/` (never deleted).
  - Pending manifest PDF of a linked meeting → `PdfManifests::Extraction.archive`.
  - Duplicate bases: listed only.
  - Refused: crawler not idle, busy or leased source, anything `Sources::FilePolicy` refuses, `.sql`, `results.done` / `results.sent`, phase files, LT4 copies, manifests of unlinked meetings.

### Step 8: docs
- `docs/operator_guide.md`, `docs/season_board.md`, `AGENTS.md`, `CLAUDE.md`; move the improvements doc and this plan to `docs/plans/done/`.

## Execution

- Same method as the 15 phases: this session coordinates, agents implement (at most 3 in parallel), an independent read-only reviewer per step, findings fixed by the author agent, full suite at quiet points, one commit per step.
- Steps 1, 2 and 3 touch disjoint files and run in parallel; then 4, 5, 6, 7 in order (4 shares views with 1 and 2; 6 shares `source_crawl_job.rb` with 7).
- Agents use a private `OPS_DATABASE_URL`; nobody starts the dev server, calls the remote API, pushes, or writes the development DB.
- Nothing is merged into `main` or pushed without the operator's go-ahead.

## Verification

- Per step: targeted specs, then `SKIP_SYSTEM=1` full suite, system specs in both themes (`SYSTEM_THEME=dark`), rubocop.
- Operator's manual checks:
  1. Browse Data-Fix steps 1 ↔ 3 back and forth, hover the tabs, rescan a step: the strip never blocks, Back shows none.
  2. On the board the five rows lose "Preparazione in coda"; FIN 150094 reads "Ready to commit"; "Riprendi passo 2" opens step 2; no new prepare run after 30 minutes.
  3. Top bar: one "all OK" pill; stop the crawler → its pill appears.
  4. Toggle an automation switch with the board filtered: the filter and the open `<details>` stay.
  5. Seven link-less rows gain a link with an "adopted" flag; Crawl works on one.
  6. "Check now" after a FIN change: 'Eventi' crawl → meeting crawls → prepares → the alert clears in a second tab.
  7. `/sources/cleanup`: the dry run lists today's redundant files; apply; the "file ridondante" flags are gone.

## Defaults taken (changeable)

- `auto_calendar` on by default; no auto-acknowledge while the master switch is off.
- Hover prefetch off app-wide.
- Result PDFs under `pdfs/<season>` are left out of the clean-up.
- The 3 'Eventi'-only meetings with no row on the watched page stay in Sources (opt-in "Prepare").
- If the "removed from FIN" row turns out too invasive in `Builder`, fall back to the notice only.
