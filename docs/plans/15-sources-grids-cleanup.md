# Phase 15 — Sources area, grid chrome, command palette, compat removal, docs

## Goal

Finish the last page groups and remove the temporary layer:
- Pull, PDF and the generic file lists become one season-aware **Sources** area in the shell. Manual crawls, PDF scans and manifest batches run as tracked jobs, there is one manifest-extraction path, and a file editor is confined to `crawler/data`.
- The `api_*` grids share one page chrome that shows API errors in place, with drill-down links and i18n headers.
- A command palette (Ctrl+K) is fed by `Shell::Navigation` and local lookups.
- The Bootstrap 4 compatibility layer shrinks to the goggles_db engine partials.
- The docs describe the new flow.

## Operator-visible outcome

- `/sources` replaces the four Pull tabs, the PDF page and the file lists. It has tabs Results, Calendars, Manifests, PDFs, Crawler and Files, for a chosen season (default `SeasonDefaults.default_season_id`, remembered in `Ops::Setting`).
- The Crawler tab has a form per source kind, with real URL and event fields instead of the `<base> (+<LINK>)` placeholder. Starting a crawl queues a job that shows in "In progress" on every page. It never runs in parallel with a board crawl. When it ends, a toast links to the new file.
- A PDF scan runs in the background and ends either as "parsed, open in Data-Fix" or as "no format matched at page N", with the format table and log.
- Manifests are extracted through one queued path (per file or "next 20"); the old in-page status polling is gone.
- A non-FIN result source (Microplus, FICR, Go&Swim, PDF-derived) offers "Prepare". This queues the phase 10 prepare job, and the source then appears in the inbox like a FIN one.
- Entity grids look the same everywhere. An API error shows a retry box on the grid page instead of bouncing to the dashboard. Rows link to related grids or pages.
- Ctrl+K (or Cmd+K) opens a palette that jumps to any sidebar page, a meeting, team or swimmer, or a Data-Fix session.

## Depends on

Hard dependencies: **04**, **10** and **12**.

- **04**: shell, `Shell::Navigation`, `Shell::PageHeaderComponent`, toasts, the probes, and the native sweep of the `api_*` grids and `Grid::*`.
- **10**: `DataFixPrepareJob` (pipeline queue), `Scheduler.prepare!`, the inbox sources that show prepared non-FIN sources, and the verdicts shown on source rows.
- **12**: Data-Fix views native.
- Softer links, reached through those three:
  - 05: `DataFix::SessionIndex`, the live-frame controller, `ActivityLog` memoisation;
  - 07: `/push` is replaced by the Outbox and `PushController` is reduced to a redirect (07, files list), so it no longer needs `FileListController` (`class PushController < FileListController`, `push_controller.rb:8`). `PullController` also inherits from it (`pull_controller.rb:9`). Verify at start with `grep -rn "< FileListController" app`; `FileListController` is deleted only when no subclass is left (step 6);
  - 09: the `pipeline` worker and `DataFix::Pipeline#mark_edited!`;
  - 03: `spec/bs4_leftovers_spec.rb` (`SWEPT` / `BASELINE`).

## Invariants (from the master plan)

- Manual crawls stay strictly serial with board crawls: one crawler process, one status file.
- No job commits, pushes, applies or restores, and there is no bulk commit. "Prepare" stops at review (phase 10 rule: no code path from the prepare job to the commit). Committing stays a click on the commit summary. `SourceCrawlJob`, `ManifestExtractJob` and `PdfScanJob` are never enqueued by a commit or push path.
- Values a job computes for the UI (scan results, selected season) live in the ops DB (`Ops::Snapshot`, `Ops::Setting`), never in `Rails.cache`.
- Operator edits win. Saving a phase file through the file editor marks it edited (`DataFix::Pipeline#mark_edited!`), so automatic builds never overwrite it.
- File conventions are unchanged (`results.new/<season>/<base>.json`, `pdfs/<season>/<base>-res.pdf`, `manifests[.done]/<season>/manifest-<base>.pdf`, `NNNN-<base>-lt4.sql`), so `DiskIndex`, `Backfill` and `CrawlerCalendar::Row` (byte-for-byte JS parity, `row.rb:13-16`) keep working.
- No file operation accepts a path outside `crawler/data`.
- Dashboard and status surfaces make no synchronous remote call; the Node crawler is local but is still read from its status file, not over HTTP, in page requests.
- "Staging" means the import staging tables. Repo conventions: `frozen_string_literal`, en and it keys, `rubocop -a` clean, CHANGELOG + PATCH bump per user-visible step, no bare `db:prepare`/`db:migrate`.

## Scope

### A. What each Pull, PDF and file-list route becomes

Pull routes are `config/routes.rb:44-60` (16 routes); PDF routes are lines 62-64.

| Route (helper) | Today | Becomes |
|---|---|---|
| `GET pull/index` (`pull_index_path`) | crawler form + log (`pull/index.html.haml`) | `GET sources/crawler`; the live log comes from the job's activity entry |
| `GET pull/calendar_files` | CSV list (`FileListController#calendar_files`, `file_list_controller.rb:12-18`) | `GET sources/calendars`: originals, `-sel-` subsets and `-skip` leftovers in separate groups |
| `GET pull/result_files` | JSON/PDF list (`file_list_controller.rb:33-54`) | `GET sources/results` and `GET sources/pdfs` |
| `PUT pull/result_files` (`update_result_files_path`) | folder picker | removed (season selector, GET param) |
| `POST pull/run_crawler_api` | direct Node call (`pull_controller.rb:63-114`) | `POST sources/crawls`, which enqueues `SourceCrawlJob` |
| `POST pull/start_crawler` | `CrawlerLauncher#ensure_running!` | `POST sources/crawler/start` (same service) |
| `GET pull/edit_name`, `PUT pull/file_rename` | rename by full path (`file_list_controller.rb:64-93`) | `GET/PATCH sources/files/rename` through `Sources::FileGuard` |
| `GET pull/edit_file`, `PUT pull/file_edit` | raw textarea (`file_list_controller.rb:96-130`) | `GET/PATCH sources/files/edit`: CodeMirror (`codemirror-json` pin, `config/importmap.rb:31`) with JSON validation |
| `DELETE pull/file_delete` | delete by path (`file_list_controller.rb:135-147`) | `DELETE sources/files` through `FileGuard`, with confirm |
| `POST pull/process_calendar_file` | crawl a whole CSV (`pull_controller.rb:123-141`) | `POST sources/crawls` with `kind: calendar_results` |
| `GET pull/calendar_meetings` | selection page (`pull_controller.rb:154-171`) | `GET sources/calendars/meetings` (same `calendar_selection_controller.js`) |
| `POST pull/process_selected_meetings` | crawl a subset (`pull_controller.rb:182-203`) | `POST sources/crawls` with `kind: calendar_results` and `selected_rows[]` |
| `POST pull/extract_manifests` | `BatchRunner#start_in_thread!` (`pull_controller.rb:217-249`) | `POST sources/manifests/extract`, which enqueues `ManifestExtractJob` per PDF |
| `GET pull/extraction_status` | JSON poll (`pull_controller.rb:255-261`) | removed (state comes from jobs and the activity log) |
| `GET pdf/extract_txt` (`pdf_extract_txt_path`) | synchronous `pdftotext` (`pdf_controller.rb:22-28`) | `GET sources/pdfs/show?path=` (preview once the TXT exists) |
| `PUT pdf/scan` | synchronous scan (`pdf_controller.rb:34-85`) | `POST sources/pdfs/scan`, which enqueues `PdfScanJob` |
| `PUT pdf/log_contents` | log as turbo stream (`pdf_controller.rb:91-100`) | part of `GET sources/pdfs/show` (scan result card) |

- For one release, every old GET route redirects to its new path; the POST/PUT/DELETE routes are deleted.
- External callers to repoint:
  - `pull_index_path` in `data_fix/base_controller.rb:65`, `data_fix/events_controller.rb:120,345`, `data_fix/sessions_controller.rb:219,292`, `data_fix/swimmers_controller.rb:136,347`, `data_fix/teams_controller.rb:111,267`, `federnuoto_watch_controller.rb:32` (`pull_calendar`);
  - `pull_result_files_path` in `data_fix/commits_controller.rb:204`, `data_fix/commit_phase6_report.html.haml:6`, the five `data_fix/review_*.html.haml` back links, `season_board/index.html.haml:131`;
  - the 05 `UnmatchedSources` inbox source.
- Line numbers may move after 09 and 12; re-grep `pull_[a-z_]*_path` before editing.

### B. Views and what they become

There are 17 files today (`find app/views/pull app/views/file_list app/views/pdf -type f`).

| View | Becomes |
|---|---|
| `pull/index.html.haml`, `_crawler_tabs.html.haml` | `sources/crawler.html.haml`; the tabs become the `Sources::TabsComponent` (shell-native) |
| `pull/_crawler_status_box.html.haml` | deleted: crawler, watcher and activity status come from the 04/05 probes and the "In progress" frame |
| `pull/calendar_files.html.haml`, `pull/result_files.html.haml` | `sources/calendars.html.haml`, `sources/results.html.haml`, `sources/pdfs.html.haml`, `sources/manifests.html.haml`, sharing `Sources::FileTableComponent` |
| `pull/calendar_meetings.html.haml` | `sources/calendar_meetings.html.haml` (native BS5); the manifest box becomes a link to the Manifests tab |
| `file_list/_file_table.html.haml`, `_file_modal.html.haml`, `edit_name`/`edit_file`/`file_table_update.turbo_stream.erb` | `Sources::FileTableComponent` (one action menu per extension; one Data-Fix entry) and `sources/files/{rename,edit}.html.haml` |
| `pdf/extract_txt.html.haml`, `_result_card`, `_log_card`, `_log_output`, `scan.turbo_stream.erb`, `log_contents.turbo_stream.erb` | `sources/pdf_show.html.haml` with `Sources::PdfScanResultComponent` (format table from the stored scan, log) |

Also deleted:
- `app/controllers/pull_controller.rb` (494 lines), `file_list_controller.rb` (189) and `pdf_controller.rb` (210), replaced by `Sources::*Controller`s;
- `app/javascript/channels/crawler_srv_channel.js` and `node_consumer.js` (the Node fake-ActionCable client, subscribed only on `/pull`, `crawler_srv_channel.js:6`);
- `manifest_extraction_controller.js`;
- `app/assets/stylesheets/pull.scss` and `pdf.scss`.

The Node 1 s broadcast (`crawler/server/index.js:147-167`) is left running but unused. Removing it is a decision below.

### C. Crawls as jobs

- `CrawlerClient` (`app/services/crawler_client.rb`) gains methods for the existing Node endpoints (`crawler/server/api.js`). The Node code does not change.
  - `pull_calendar(season_id:, start_url:, sub_menu_type:, year_text:)`: `GET /pull_calendar` (api.js:22-35)
  - `pull_results_from_file(season_id:, file_path:, layout:)`: `GET /pull_results` with `file_path` (api.js:68-74)
  - `pull_microplus(season_id:, url:, target_event: nil)`: `GET /pull_results_microplus` (api.js:76-95)
  - `pull_ficr(season_id:, url:)`: `GET /pull_results_ficr` (api.js:97-112)
  - `pull_goandswim(season_id:, url:)`: `GET /pull_results_goandswim` (api.js:114-130)
  - The existing `status` and `pull_meeting` (layout 2, api.js:54-66) stay.
  - `BASE_URL` moves from `PullController::CRAWLER_API_URL` (`pull_controller.rb:11`) to `CrawlerClient::BASE_URL` (also read by `CrawlerLauncher::STATUS_URL`, `crawler_launcher.rb:15`).
- `Crawler::RunWatcher` is extracted from `MeetingCrawlJob`: `ensure_crawler!`, `wait_until_idle!`, `wait_for_crawl_end!`, `crawl_end?` (`meeting_crawl_job.rb:96-148`). Both jobs use it.
- `SourceCrawlJob` (`app/jobs/source_crawl_job.rb`):
  - queue `background`, `limits_concurrency key: 'season_board', group: 'SeasonBoardBackground'`, the same as `meeting_crawl_job.rb:37`;
  - retries off;
  - kinds `calendar`, `calendar_results`, `fin_meeting`, `microplus`, `ficr`, `goandswim`;
  - timeout 30 min per meeting, capped at 12 h;
  - priority 10, so board crawls (priority 0) go first;
  - URL validation per kind against the base URLs in `pull_controller.rb:14-26` (moved to `Sources::CrawlKinds`);
  - when it ends, it lists the new files (directory diff) and broadcasts a toast through `AppNotificationsChannel`.
- Tracking goes in `SeasonBoard::ActivityLog` under the key `src:<sha1(kind+url|file)>`.
  - New optional entry fields: `label` (shown by `ActivityStripComponent.entry_name`, `activity_strip_component.rb:39`) and `heartbeat_at` (written at each poll).
  - Entries with a recent heartbeat are never stale, even past `RUNNING_STALE_AFTER` (`activity_log.rb:30`).
  - Old JSON files stay readable.
- The before-action `refuse_while_board_crawl_runs` (`pull_controller.rb:29, 268-282`) is no longer needed: serialisation comes from the shared worker and key. Before enqueueing, the form shows "queued behind N crawls".

### D. One manifest-extraction path

- `PdfManifests::Extraction.call(pdf_path:, engine:)` holds the preflight, `Extractor`, archive and result logic now in `ManifestExtractJob#run_extractor` (`manifest_extract_job.rb:62-71`) and `BatchRunner.archive` (`batch_runner.rb:142`).
- `ManifestExtractJob#perform(season_id:, fin_event_id: nil, pdf_path: nil, engine: nil)`. `pdf_path` must resolve under `crawler/data/manifests/<season>/`.
- "Extract next 20" enqueues 20 jobs at priority 10.
- `rake manifests:extract` (`lib/tasks/manifests.rake:41`) calls `Extraction` inline, one file at a time, and writes the same activity entries, so the UI sees it.
- `PdfManifests::BatchRunner`, `manifests-extract-status.json` and the `BatchRunner.running?` guard (`manifest_extract_job.rb:53`) are deleted.
- 10's capped retries for automatic extraction keep working (same job).

### E. PDF scan as a job

- `PdfResults::ScanRunner` holds `PdfController#scan` (lines 34-85) and `scan_l2_data_hash_for_null_team_names` / `..._matching_team_name` (lines 173-209), and keeps the `ffamily`, page-range and debug options.
- `pdftotext` uses the array form of `system` (the 01 fix).
- `PdfScanJob` (inherits `ApplicationJob`) on `pipeline`, `queue_with_priority 10` so a queued commit (priority 0) runs first, retries off. It stores the result (`checked_formats`, `page_count`, `last_index`, `result_format_type`, `json_path`, log path) in `Ops::Snapshot` `pdf_scan:<sha1(path)>`.
- `FormatParser` derives the season from the parent folder and defaults to 222 (`app/strategies/pdf_results/format_parser.rb:132, 576-578`). The runner refuses PDFs outside `pdfs/<numeric season>/`.

### F. Sources pages (`app/controllers/sources/*`, `app/services/sources/*`)

- `Sources::Index` per season:
  - result JSON in `results.new/<season>`: reuses `SeasonBoard::DiskIndex` (`disk_index.rb`) for the FIN id, LT2/LT4 role and phases, plus `DataFix::SessionIndex` (05) and the 09 verdicts;
  - PDFs in `pdfs/<season>` with TXT/JSON/scan state;
  - calendars in `calendar.new/<season>` and `calendar.done/<season>`;
  - pending manifests in `manifests/<season>`;
  - one action per row.
- Non-FIN result rows get "Prepare": POST calls `SeasonBoard::Scheduler.prepare!` (10: ops lease, no `ActivityLog` entry without a FIN id), which enqueues `DataFixPrepareJob.perform_later(source_path:, season_id:, origin: 'operator', up_to: 5)` for that file and returns to the list. The planner of 10 never queues these sources; the click is the opt-in, and the job stops at review.
- `Sources::FileGuard.resolve!(path)` uses `File.realpath` under `Rails.root.join('crawler/data').realpath`. It is the same pattern as `valid_calendar_csv_path?` (`pull_controller.rb:325-333`), applied to rename targets too.
- Edits:
  - JSON is parsed before saving (save is refused with the parser error), then written to a temp file and renamed;
  - CSV and TXT are saved as is;
  - a phase file save (`<base>-phase<N>.json`) calls `DataFix::Pipeline#mark_edited!(N, action: 'file_editor')` (stamped as an operator edit, so the digest mismatch cannot be mistaken for a build) and `SeasonBoard::Snapshot.invalidate!`.
- `Shell::Navigation`: "Sources" entry under Import, replacing Pull.

### G. Grid chrome

- Today:
  - 13 `api_*/index.html.haml` are the same 26-line template (badges, calendars, import_queues, issues, meeting_reservations, seasons, standard_timings, swimmers, swimming_pools, team_affiliations, teams, users, user_workshops);
  - `api_meetings` (34 lines) and `api_team_managers` (33) add a toolbar block;
  - `api_categories` (56) and `api_trainings` (57) are bespoke;
  - 17 index actions redirect to `root_path` on an API error (`grep -l "redirect_to(root_path)" app/controllers/api_*_controller.rb`).
- `Grid::PageComponent(title:, model:, grid:, toolbar: {}, domain: {})`, with a `toolbar_extra` slot. It renders the `Shell::PageHeaderComponent`, the row count, `Grid::EditModalComponent`, `Grid::ToolbarComponent`, the datagrid form, `Grid::FilterLabelsComponent`, `PageLinksForArrayComponent` twice and `datagrid_table`. The 15 views become 3-6 lines each. Categories and trainings keep their bespoke bodies inside the same chrome.
- `APIGridIndex` controller concern: `render_api_index(grid_class, model_class, result)`.
  - The `APIProxy.call(...)` stays in each controller with exactly today's arguments. Request specs stub it with exact `.with(method: :get, url: 'teams', jwt: admin_user.jwt, params: { name: anything, page: anything, per_page: anything })` (`spec/requests/api_teams_controller_spec.rb:21-24`, same in the other 14 `api_*` grid request specs; `api_calendars` and `api_standard_timings` have none). No option may be added or removed (for example the 05 `timeout:`).
  - On a non-200 it renders the page with `Grid::APIErrorComponent` (code, `error_detail`, retry link) and status 200. `spec/requests/api_trainings_controller_spec.rb:67-70` (asserts the redirect to root) is the only spec to update.
- Drill-down links via `Grid::DrillLinkComponent`:
  - meetings to `season_board_path` and the local meeting's calendars grid;
  - teams to badges, affiliations and team managers filtered by `team_id`;
  - swimmers to badges filtered by `swimmer_id`;
  - import queue rows to their Outbox script (07/08).
- Headers: 82 `header:` options in the 22 `app/grids/*.rb`, 5 already I18n or lambdas. All move to `grids.<grid>.<column>` keys in `config/locales/grids.{en,it}.yml`.
- Component specs under `spec/components/grid/` keep their DOM ids.

### H. Command palette

- `palette_controller.js` (Stimulus), mounted in the shell layout. The navigation entries come as embedded JSON from `Shell::Navigation`.
- `GET palette/search?q=` returns at most 20 local results:
  - meetings, teams and swimmers through `LookupController` (add `meeting` and `swimmer` to `MODELS` and `SAFE_COLUMNS`, `lookup_controller.rb:24-35`);
  - Data-Fix sessions from `DataFix::SessionIndex`.
- Keys: Ctrl/Cmd+K, arrow keys, Enter, Esc. Ignored when focus is inside an input, textarea, contenteditable, TomSelect or CodeMirror.

### I. Compatibility layer

- Delete `compat/_bs4.scss` and `bs4_compat.js` (03), except a scoped subset `compat/_goggles_db_partials.scss` applied under `.goggles-db-partial`. That wrapper goes around the two engine renders: `goggles_cup/_ranking.html.haml:7` (`goggles_db/goggle_cups/ranking`) and `goggles_cup/base_timings.html.haml:10` (`goggles_db/goggle_cups/base_timings`, which renders `_base_timings_table`).
- If those partials need the `data-toggle` to `data-bs-toggle` copy, keep a scoped JS shim that observes only that wrapper.
- `spec/bs4_leftovers_spec.rb`: `SWEPT` gains the Sources and Pull-replacement folders, and `BASELINE` shrinks to those engine paths only.

### J. Docs

- CLAUDE.md "Other subsystems" (Pull/PDF lines become Sources; one extraction path).
- AGENTS.md: the PDF manifest extraction section.
- `docs/season_board.md`: line 13 "Push", line 51 the Pull refusal, line 57 the Pull status box.
- `docs/crawler/crawler_interaction.md:26`: PDFs go to `pdfs/<season>`, not `results.new` (see `crawler/server/results-crawler.js:579`, `CrawlUtil.pdfsFolder`).
- `docs/pdf_processing/manifest_extraction.md:59-65`: BatchRunner and the status file.
- `docs/introduction.md`.
- New `docs/operator_guide.md`: dashboard, board, sources, Data-Fix, Outbox, health, operations, DB sync.
- Move finished plans to `docs/plans/done/`.

## Data model

- No new ops tables. New `Ops::Snapshot` keys `pdf_scan:<sha1>`; new `Ops::Setting` key `sources.season_id`.
- `season-board.json` entries gain the optional `label` and `heartbeat_at` fields (backward compatible).
- MySQL: none.

## Ordered steps

1. **CrawlerClient methods, `Crawler::RunWatcher`, `SourceCrawlJob`** (internal; `MeetingCrawlJob` specs unchanged). No bump.
2. **Sources shell pages read-only.** Results, PDFs, Calendars, Manifests tabs, season selector, old GET routes redirecting, navigation entry. User-visible: CHANGELOG + PATCH.
3. **Crawler tab.** Forms, `POST sources/crawls`, toasts on completion; delete `run_crawler_api`, `process_calendar_file`, `process_selected_meetings`, the status box and the Node channel client. User-visible: CHANGELOG + PATCH.
4. **One manifest path.** `PdfManifests::Extraction`, the job generalised, the rake task switched, `BatchRunner` and the status route deleted. User-visible: CHANGELOG + PATCH.
5. **PDF scan job.** `ScanRunner`, `PdfScanJob`, result page; delete `PdfController` and its views. User-visible: CHANGELOG + PATCH.
6. **File manager.** `FileGuard`, rename, edit and delete with JSON validation and edit marker; delete the `file_list` views, and `FileListController` only once `grep -rn "< FileListController" app` is empty (07 reduced `PushController` to a redirect without that parent; `PullController` goes in steps 2-5). User-visible: CHANGELOG + PATCH.
7. **"Prepare" for non-FIN sources.** Inbox shows them through the 10 sources. User-visible: CHANGELOG + PATCH.
8. **Grid chrome.** `Grid::PageComponent`, `APIGridIndex`, in-place errors, drill links; one commit per 4-5 grids. User-visible: CHANGELOG + PATCH.
9. **Grid headers to i18n** (en and it), parity spec green. CHANGELOG + PATCH.
10. **Command palette.** CHANGELOG + PATCH.
11. **Compat reduction** to the engine-partial scope; leftovers spec at zero. Also delete `app/components/footer/main_component.{rb,html.haml}` (and its spec, if one exists; none found today) once `grep -rn "Footer::MainComponent" app` returns nothing: each view drops its render in the phase that sweeps or rewrites it. CHANGELOG + PATCH.
12. **Docs refresh**, plans moved to `done/`. CHANGELOG line, no bump.

## Specs and manual verification

- Request specs:
  - `spec/requests/sources/*_spec.rb` per tab;
  - `POST sources/crawls` enqueues `SourceCrawlJob` with the right kind and never calls the crawler in the request (`CrawlerClient` stubbed to raise);
  - invalid URLs per kind are refused;
  - each old GET route redirects.
- `spec/jobs/source_crawl_job_spec.rb`:
  - waits while the crawler is busy;
  - shares the concurrency key with `MeetingCrawlJob` (assert `concurrency_key`);
  - heartbeat keeps the entry busy past 40 min.
- `spec/services/sources/file_guard_spec.rb`: `../`, an absolute path outside, a symlink pointing out, and a rename target outside are all refused (exit criterion). Edit spec: invalid JSON is not written; a phase file save sets the edit marker.
- `spec/strategies/pdf_manifests/extraction_spec.rb`: parity with the old `run_extractor` outcomes; `manifests.rake` spec: same console output on a fixture.
- `spec/jobs/pdf_scan_job_spec.rb` on a fixture TXT under `spec/fixtures`: same `checked_formats` as the old controller spec `spec/requests/pdf_controller_spec.rb` (port its cases, then delete it). Port `pull_controller_spec.rb` the same way.
- Grid request specs: all 15 `api_*_controller_spec.rb` files green with their stubs unchanged. A new example per grid with a 503 `APIProxy::Result` renders the error box with status 200. `spec/components/grid/page_component_spec.rb`.
- `spec/bs4_leftovers_spec.rb`: zero outside `BASELINE` (engine paths only). The i18n parity spec covers the `grids.*` keys.
- System journeys (01 harness): crawl a Microplus fixture (fake crawler), Prepare, inbox item; palette opens a meeting by name.
- Manual: start a board crawl and a manual crawl together; the manual one waits. Scan a 50-page PDF while browsing other pages. Edit a JSON with a syntax error and see the refusal.

## Exit criteria

- No route, view or controller named `pull`, `pdf` or `file_list` remains, except the temporary GET redirects (`FileListController` goes last, after 07's `PushController` no longer inherits from it).
- No file operation accepts a path outside `crawler/data` (request and service specs).
- A manual crawl is queued, never run in parallel with a board crawl.
- Manifest extraction has one implementation (`PdfManifests::Extraction`), used by the job and by rake.
- The 15 grid request specs pass with unchanged `APIProxy` stubs; no `api_*#index` redirects to root on an API error.
- `spec/bs4_leftovers_spec.rb` reports zero uses outside `BASELINE`, which holds only the engine-partial paths.
- The palette reaches every `Shell::Navigation` entry and opens a meeting and a Data-Fix session by name.
- `app/components/footer/main_component.*` is deleted, and `grep -rn "Footer::MainComponent" app` returns nothing.
- Docs listed in J describe what is on screen.
- Routine gate: sign in → board → crawl → review → commit → report → push → confirm, once for a FIN meeting and once for a non-FIN meeting started from Sources.

## Risks and mitigations

- **A long calendar-results crawl outlives the 1 h semaphore** (`limits_concurrency duration: 1.hour`). Mitigation: the single-thread `background` worker already serialises jobs; `RunWatcher#wait_until_idle!` checks the crawler status before starting; the heartbeat keeps the activity busy.
- **A long PDF scan delays a commit** on the single-thread `pipeline` worker. Mitigation: priority 10 vs the commit's 0 (applies to queued jobs only), and the scan's progress in its snapshot so the operator sees why.
- **Bulk extraction starves board crawls** on the serial `background` queue. Mitigation: priority 10 vs 0, batches of 20, and 10's caps.
- **Grid refactor breaks exact-argument stubs.** Mitigation: the concern never builds the `APIProxy.call` arguments; one grid per commit with its spec run.
- **Removing compat breaks unconverted markup.** Mitigation: the leftovers spec must be at zero first; system suite in both themes.
- **The Node status broadcast loses its only client.** It is harmless; the probe reads the file.
- **Operators used to the folder picker lose access to non-season folders** (`misc`, `goggle_cups`, `normalize`). Mitigation: the Files tab lists every top-level `crawler/data` folder.

## Decisions to confirm

- Legacy crawl layouts 1 and 3 (CSV-driven, `pull_controller.rb:99-101`): default kept only for the "crawl calendar CSV" kind (layout from `result_layout_for`); not offered as free-form kinds.
- Remove the Node 1 s WebSocket broadcast (`crawler/server/index.js:147-167`): default no (left for the crawler's own tests); revisit later.
- Old GET redirects: default kept for one release, then removed.
- Bulk manifest batch size: default 20.
- PDF scan queue: default `pipeline` (CPU-bound, not LLM; keeps `background` free for crawls).
- Unreferenced data folders (`pdfs.done`, `pdfs.backup`, `results.backup`, `results.old`, `redo`): default shown read-only in Files, no action.

## Out of scope

- Changes to the Node crawler code.
- Multi-season Season board.
- goggles_main (stays on Bootstrap 4).
- Mirroring remote grid edits into the local DB (the 05 log and 08 drift cover visibility).
- A jobs admin UI.

## Rollback note

- Each step is its own commit. Reverting steps 2-7 restores the Pull, PDF and file-list controllers and views from git; the new jobs are additive and can stay.
- Step 4 is the only one that deletes a runtime path (`BatchRunner`). Revert it together with the rake change.
- Grid steps revert per grid.
- Compat removal reverts by restoring the two compat files and their imports.
- No database change to undo.
