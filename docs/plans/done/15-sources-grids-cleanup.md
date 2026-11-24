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

## Outcome (done, 0.10.94-0.10.96, 2026-11-24)

Delivered on `feature/modernize-admin-console-ux` in three parts: steps 1-7 (Sources area, 0.10.94) and steps 8-10 (grid chrome, grid headers, command palette, 0.10.95) were implemented in parallel in the same working tree and committed together; steps 11-12 (compat reduction, docs refresh, 0.10.96) followed alone. Every "Decisions to confirm" item was taken with its default.

### Part A outcome (0.10.94, 2026-11-24)

Delivered on `feature/modernize-admin-console-ux` (steps 1-7, scope sections A-F), in the same working tree as part B (grid chrome, grid headers, command palette), shipped as one PATCH. The six decisions were confirmed with their defaults (legacy CSV layouts 1 and 3 only for the calendar CSV kind; the Node WebSocket broadcast kept, unused; old GET routes redirect for one release; bulk manifest batch 20; PDF scan on `pipeline`, priority 10; unreferenced data folders read-only in Files). No ops migration, no MySQL change.

- **Spec runs** (targeted, private ops DB `OPS_DATABASE_URL=sqlite3:tmp/ops_p15a.sqlite3`; the full suite is the coordinator's):
  - step 1 (crawler client, run watcher, both crawl jobs, activity log, launcher): 103 examples, 0 failures;
  - broad non-system run (`spec/requests spec/services spec/components spec/jobs spec/tasks spec/models spec/channels spec/config spec/routing spec/helpers spec/views`, `spec/strategies/{pdf_manifests,pdf_results,season_board,crawler_calendar}`, boundary, BS4 ratchet, i18n parity, inline handlers): **3,518 examples, 3 failures, 30 pending**: `spec/models/ops/application_record_spec.rb` and `spec/models/ops/database_spec.rb` (they assert the default ops DB path; run without the variable: 19 examples, 0 failures) and `spec/requests/data_fix/commits_controller_helpers_spec.rb:289` (see *Not verified*);
  - Data-Fix requests (phase 1-3 specs, `spec/requests/data_fix`, season board, API-offline session): 299 examples, 0 failures; board / inbox / probes / shell / components / jobs / config / i18n / BS4 / routing / helpers group: 1,095 examples (1 failure in a new example, fixed: 4/4 on rerun);
  - after the last view changes, `spec/requests/sources` + `spec/components`: 435 examples, 0 failures, 3 pending (pre-existing);
  - review follow-up (duplicate extractions, batch confinement, outside links, deterministic PDF journey): boundary + `spec/services/sources` + `spec/requests/sources` + board controller + `spec/services/season_board` + `spec/jobs` + i18n + BS4: 630 examples, 0 failures; then `spec/requests/sources` + `spec/services/sources` + `spec/components`: 468 examples, 0 failures, 3 pending; `spec/system/sources_spec.rb` 3 times light and once dark: 3 examples, 0 failures each time; new `services/sources/{manifest_queue,folder_listing}_spec` 4 / 4;
  - new spec files: `jobs/source_crawl_job_spec` 13, `jobs/pdf_scan_job_spec` 7, `services/sources/{file_guard,file_editor,crawl_request}_spec` 9 / 6 / 9, `strategies/pdf_manifests/extraction_spec` 9, `tasks/manifests_rake_spec` 5, `requests/sources/{legacy_redirects,results,calendars,crawls,crawler,manifests,pdfs,files}_spec` 70 in all, `system/sources_spec` 3; examples added to `activity_log_spec` (6), `crawler_client_spec` (6), `manifest_extract_job_spec` (3), `snapshot_spec` (1), `pipeline_index_spec` (1), `unmatched_sources_spec` (2), `pipeline_automation_sources_spec` (3), `automation_boundary_spec` (1);
  - system suite (`spec/system`, all journeys incl. part B's palette): **light 32 examples, 0 failures; dark (`SYSTEM_THEME=dark`) 32 examples, 0 failures**; after the last view tweaks `spec/system/sources_spec.rb` again green in both themes. The plan's journey (crawl a Microplus source with a fake crawler, Prepare, inbox item) is `spec/system/sources_spec.rb`.
  - rubocop clean on every Ruby file touched (incl. the shared `config/routes.rb`, `navigation.rb`, `navigation_spec.rb`, `bs4_leftovers_spec.rb`); haml-lint clean on every new template and on the layout; `bin/rails dartsass:build` run; brakeman (`-A`): no new warning beyond the SHA1 "weak hash" notes of the `src:` / `pdf_scan:` keys (identifiers, as the plan names them).
- **Names as shipped.**
  - Crawls: `CrawlerClient::BASE_URL` (moved from the deleted `PullController::CRAWLER_API_URL`; `CrawlerLauncher::STATUS_URL` reads it), `CrawlerClient#pull_calendar`, `#pull_results_from_file`, `#pull_microplus(target_event:)`, `#pull_ficr`, `#pull_goandswim` (they also send `layout` 4/5/6 like the old calls); `Crawler::RunWatcher` (`ensure_crawler!`, `wait_until_idle!(timeout:, on_wait:)`, `wait_for_crawl_end!(since, baseline, timeout:, on_poll:)`, `crawl_end?`, `Failure`; `MeetingCrawlJob::Failure` is now an alias of it, its constants and specs unchanged); `SourceCrawlJob` (`background`, `queue_with_priority 10`, `limits_concurrency key: 'season_board', group: 'SeasonBoardBackground', to: 1, duration: 1.hour` = `concurrency_key` `SeasonBoardBackground/season_board`, the same as `MeetingCrawlJob` / `ManifestExtractJob`; class attributes `sleeper`, `clock`, `crawler_client_factory`, `launcher_factory`, `data_dir`; `TOAST_DOM_ID_PREFIX` `sources-crawl-`); `Sources::CrawlKinds` (kinds, base URLs, `valid_url?`, `result_layout_for`, `TIMEOUT_PER_MEETING` 30 min, `MAX_TIMEOUT` 12 h), `Sources::CrawlRequest` (`from`, `errors`, `key`, `label`, `timeout`, `start!`), `Sources::CrawlOutputs` (directory diff), `Sources::CrawlToastComponent`; events `sources.crawl_finished|crawl_failed`.
  - Activity log: optional entry fields `label`, `heartbeat_at`; `ActivityLog.source_key(kind, target)` / `.source_key?`, `SOURCE_KEY_PREFIX` `src:`, `HEARTBEAT_STALE_AFTER` 5 min, `#heartbeat!`, `queue!/start!(label:)`, `Entry#source?`; keys `src:<sha1("crawl:<kind>|<url or file or season|menu|year>")>` and `src:<sha1("extract|<real PDF path>")>`.
  - Manifests: `PdfManifests::Extraction` (`.call(pdf_path:, engine:, model:, force:, data_root:, client:, preflight: true)`, `.preflight_error`, `.preflight_message`, `.archive`, `PREFLIGHT_MESSAGES`, `Result#status|message|extractor_result|preflight|archived?`); `ManifestExtractJob#perform(season_id:, fin_event_id: nil, pdf_path: nil, engine: nil, run_id: nil)`; `Sources::ManifestQueue` (`enqueue`, `enqueue_next`, `BATCH_PRIORITY` 10); `SeasonBoard::Scheduler.extract!(..., pdf_path:, priority:)` (`pdf_path` now also used for the `src:` busy check, `priority` optional); `Sources::ManifestsController::BATCH_SIZE` 20; events `sources.extract_finished|extract_failed` (subject `manifest_pdf`).
  - PDF scan: `PdfResults::ScanRunner` (`.format_families`, `.scannable?`, `.limit_pages`, `Refused`, `Result#full_parse?`), `PdfResults::ScanState` (Ops::Snapshot `pdf_scan:<sha1 of the real PDF path>`, `queue!/start!/finish!/fail!`, `pending?`, `STALE_AFTER` 3 h), `PdfScanJob` (`pipeline`, priority 10, `NOTIFY_DOM_ID` `sources-pdf-scan-ping`, `data_dir`), `Sources::PdfScanResultComponent`; events `sources.pdf_scan_finished|pdf_scan_failed`.
  - Pages: `Sources::{BaseController, ResultsController, CalendarsController, ManifestsController, PdfsController, CrawlerController, CrawlsController, FilesController}`; routes `sources` (redirect), `sources_results`, `sources_prepare`, `sources_calendars`, `sources_calendar_meetings`, `sources_manifests`, `sources_manifests_extract`, `sources_pdfs`, `sources_pdf` (`/sources/pdfs/show`), `sources_pdf_scan_result` (frame), `sources_pdf_scan`, `sources_crawler`, `sources_crawler_activity` (frame), `sources_crawler_start`, `sources_crawls`, `sources_files`, `sources_file_delete`, `sources_file_rename` / `sources_file_update_name`, `sources_file_edit` / `sources_file_update` (param `path`, absolute or relative to `crawler/data`; `return_to` limited to `/sources/...`); services `Sources` (`data_root` = `SeasonBoard::DiskIndex.default_data_dir`, `SEASON_SETTING_KEY` `sources.season_id`), `Sources::{SeasonSelection, Index (+ Index::{Results, Calendars, Pdfs, Manifests}), FolderListing, FileGuard, FilePolicy, FileEditor, Paths}`; components `Sources::{TabsComponent, SeasonSelectorComponent, FileTableComponent, ActionButtonComponent}`; `SourcesHelper`; Stimulus `sources_season_controller.js`, `sources_editor_controller.js`; `pages/_sources.scss`; locales `config/locales/sources.{en,it}.yml` (`sources.*`, `ops.events.sources.*`, `inbox.pipeline_rows.non_fin`); navigation item `:sources` (`fa-folder-open`, Import; `:data_fix` is now its contextual child).
  - Inbox for non-FIN sources: `SeasonBoard::PipelineIndex::Facts#state_and_detail`, `Builder::Result#unmatched_pipeline`, payload key `pipeline` of the unmatched sources, `Snapshot::UnmatchedSource#pipeline_state|pipeline_detail|preparing?`, `Snapshot::FORMAT_VERSION` 3; `Inbox::Sources::PipelineRows#unmatched_action` (ReadyToCommit → commit summary, NeedsReview → step with the review filter, PrepareFailed → POST `sources_prepare`), keys `unmatched:<base>:<commit|resume_review|prepare>`.
- **Deviations.**
  - **Prepare from Sources needs nothing new from 10**: `Sources::ResultsController#prepare` calls `SeasonBoard::Scheduler.prepare!(season_id:, source_path:, origin: :operator, up_to: 5)` as planned and refuses a FIN source (prepared from the board) or a file outside `results.new/<season>`. The inbox items come from the board summary, so only the board season (`SeasonBoard::Builder.latest_season`) feeds them: a non-FIN source of another season can be prepared from Sources but gets no inbox item. A source with a pipeline state is left by `UnmatchedSources` to the pipeline sources (and skipped while preparing).
  - **Manifests**: a PDF whose base belongs to a FIN calendar row always goes through `Scheduler.extract!` (logged under the FIN event id, like the board button and the planner; "Extract next 20" passes its priority 10 through the new `priority:` keyword); the others get a `pdf_path` job keyed `src:`. A PDF busy under either key is never queued twice, in either order: `Sources::ManifestQueue` checks the `src:` key first, and `Scheduler.extract!` also checks the `src:` key of the `pdf_path` it is given (the board's Extract now passes the row's pending PDF). The batch only takes PDFs that resolve inside `manifests/<season>` (`Sources::FileGuard`) and checks the engine first (as the old page did); a single Extract does not (the job reports it). The Manifests tab shows the latest extraction under either key.
  - **No inbox item for a failed Sources crawl or extraction**: `Inbox::Sources::FailedJobs` ignores the `src:` entries (no board row to retry); the end is a toast (crawls), an ops event and the activity card of the Crawler tab.
  - **Old routes**: every old GET page URL answers 301 to its new page (`file_path` → `path`; `pull/result_files?parent_folder=pdfs` → PDFs tab); `GET pull/extraction_status` (JSON, not a page) was removed as in the plan's table; the POST/PUT/DELETE routes are gone.
  - **PDF page**: it never runs `pdftotext` in the request (the job does it first); a scan is refused while another one of the same PDF is pending; a pending scan older than 3 hours counts as interrupted.
  - **Files tab**: a symbolic link resolving outside `crawler/data` (or nowhere) is listed as "link outside crawler/data (not followed)": no size, date, entry count, link or action.
  - **PDF page**: the result frame has a `src` (and so reloads itself) only while the scan is queued or running; a finished result is rendered once and never re-rendered under the operator.
  - **File manager policy** (not in the plan's text, needed to keep the Outbox and the state files safe): SQL scripts are read-only here (the Outbox follows them by name and checksum), as are the files right under `crawler/data` and the dated copies (`results.done.YYYY`); edits up to 10 MB; a rename target must not exist and may move the file to another folder of the data root (folders created); a phase-file save is refused while a prepare job (or another build) holds the source lease (the phase 10 rule of the review pages). The save writes the file atomically, then `mark_edited!` rewrites it once more with the marker.
  - **Templates**: a bare `Sources::` inside a view resolves to `ActionView::Template::Sources` (and `File` inside a ViewComponent template to `ViewComponent::Template::File`), hence `SourcesHelper` and the component methods.
  - **Also removed** (unused once the pages went): `app/helpers/{pull,pdf}_helper.rb` and their empty specs, `remote_partial_controller.js` (PDF page only), the layout `#loading-indicator` (PDF page spinner; `spec/requests/shell/layout_spec.rb` now asserts it is gone), the `[data-page=pull|pdf] .card` overflow rule of `shell/_legacy_wrappers.scss`, the old-page `data_import.*` keys (`crawler_headers`, `config`, `calendar`, `file`, `manifest_extraction`, `selection.extraction` & co, `errors.crawler_*`), `inbox.unmatched_sources.actions.result_files` (now `manifests`), the obsolete `PdfController` entry of `config/brakeman.ignore`, the `ws://localhost:7000` ignore of the system helpers. `FileCounter` (07: "can go in 15") is left: not in steps 1-7.
  - **Specs changed outside the new files**: the Data-Fix phase 1-3 and commits specs and the FIN watcher, dashboard, inbox, probes and sidebar specs swap the `pull_*` helpers / paths for `sources_*`; `navigation_spec` (Sources item, breadcrumbs, non-page frames); `bs4_leftovers_spec` (`SWEPT` + `app/views/sources app/components/sources`, `BASELINE` entries of the deleted folders removed); `queue_names_spec` (+ `SourceCrawlJob`, `PdfScanJob`); `automation_boundary_spec` (Sources files scanned, new example: the three jobs are enqueued only by the Sources controllers, the board scheduler and `Sources::ManifestQueue`); `manifest_extract_job_spec` (stubs the engine client instead of `BatchRunner`). Ported and deleted: `spec/requests/{pull,pdf}_controller_spec.rb`, `spec/system/{pull_files,pdf_to_data_fix}_spec.rb`, `spec/strategies/pdf_manifests/batch_runner_spec.rb`.
- **Not verified** (no dev server, no real crawler, LLM or API in specs): real crawls against FIN, Microplus, FICR and Go&Swim through the Node server; the serialisation of a manual and a board crawl under Solid Queue (priority 10 vs 0, the shared semaphore, a calendar crawl longer than the 1 h semaphore); the end-of-crawl toast through Solid Cable in a real browser (the test env has no cable broadcast: the journey reads the crawler tab instead); a real 50-page PDF scan while browsing; a real manifest batch with the LLM engine and `rake manifests:extract` on the real data; the manual "edit a JSON with a syntax error" check (covered by the system journey). `spec/requests/data_fix/commits_controller_helpers_spec.rb:289` (category normalization) passed in an earlier run of this session and fails since: it expects `U25` for a swimmer born 2002 while `Import::CategoryComputer` takes the age at the end year of the factory season (2027 today => `M25`); untouched code and spec, not caused by part A.

### Part B outcome (0.10.95, 2026-11-24)

Steps 8-10 (sections G and H) delivered in one pass, one PATCH, in the same working tree as part A (Sources, steps 1-7), implemented in parallel. Targeted runs only, with a private ops test DB (`OPS_DATABASE_URL=sqlite3:tmp/ops_p15b.sqlite3`); the coordinator runs the full suite.

- **Spec runs.**
  - Baseline before any change (grid request specs, `spec/components/grid`, lookup, navigation, i18n parity): **378 examples, 0 failures, 2 pending**.
  - Part B set after step 10 (`spec/grids`, `spec/components/{grid,shell}`, every `spec/requests/api_*_spec.rb`, `spec/requests/{shell,health,maintenance}`, lookup, remote writes, settings, stats, dashboard, Data-Fix sessions list, layout assets, theme, `spec/services/shell`, i18n parity, BS4 ratchet, page links): **698 examples, 0 failures, 2 pending**.
  - Wide sweep (all of `spec/requests`, `spec/components`, `spec/views`, `spec/routing`, plus `spec/grids`, `spec/services/shell`, parity, BS4 ratchet), on the tree as it was with part A in progress: **1474 examples, 0 failures, 24 pending** (the existing pending ones).
  - System suite: **light 29 examples, 0 failures; dark (`SYSTEM_THEME=dark`) 29 examples, 0 failures**, `spec/system/command_palette_spec.rb` included (3 journeys). An earlier light run had 31 examples with 2 failures, both in part A's `pdf_to_data_fix_spec.rb` / `pull_files_spec.rb`, which part A deleted during the run. That earlier run also caught 2 failures caused by part B (the 7th status pill clipped by the new top bar trigger, app shell journey 12 and the remote writes journey), fixed before the runs above.
  - Rubocop clean on every Ruby file touched (81 files). haml-lint clean on every new template and the generic views; the three bespoke views (categories, team managers, trainings) keep the repo's existing multi-line alignment warnings, fewer than before. `palette_controller.js`: `node --check`. CSS rebuilt (`bin/rails dartsass:build`). No ops migration.
- **Names as shipped.**
  - Grid chrome:
    - `APIGridIndex` concern (`app/controllers/concerns/api_grid_index.rb`) with `render_api_index(grid_class, model_class, result, csv_name:, grid_params: nil, csv_columns: [])` (optional block `|domain, parsed_response|`), `render_api_error(result, **assigns)` for pages without a grid, helper `api_grid_domain` (`count`, `page`, `per_page`, `rows`, `filter_params`, `index_params`, `error`) and `CSV_LOCALE = :en`.
    - `Grid::PageComponent(title:, model: nil, grid: nil, toolbar: {}, domain: {}, section_id: 'data-grid')` with slots `toolbar_extra` and `actions`; the block content is a bespoke body.
    - `Grid::APIErrorComponent(error:, retry_path: nil)`: `DOM_ID` `grid-api-error`, `.error_for(result)`, `Error` (`code`, `detail`, `unreachable?`), `DETAIL_MAX` 400, ids `#grid-api-error-{title,detail,retry,settings}`, `data-api-error-code`.
    - `Grid::DrillLinkComponent(path:, icon:, label:, text: nil, kind: nil)`: `a.app-drill-link`, `data-drill`, Bootstrap tooltip.
    - `MeetingsGrid.board_links` / `.board_links_for(rows)`.
    - Locale keys `datagrid.api_error.*` and `datagrid.drill.*`.
  - Headers: `BaseGrid.i18n_key`, `.column_header`, `.filter_header`, `.header_keys(name, filter:)`, through `default_column_options` / `default_filter_options` lambdas. Keys `grids.<grid>.<column>`, `grids.<grid>.filters.<filter>` and `grids.defaults.{selected,actions,drill}` in `config/locales/grids.{en,it}.yml`; spec `spec/grids/base_grid_headers_spec.rb`.
  - Palette:
    - `Shell::PaletteComponent(offline:)` (`DOM_ID` `command-palette`, ids `command-palette-{input,results,empty,status,title}`) and `Shell::PaletteTriggerComponent` (`#palette-trigger`, in the `search` slot of `Shell::TopBarComponent`).
    - `palette_controller.js` (targets `input list empty status`, values `entries searchUrl minChars`, actions `hotkey filter navigate pick`).
    - Route `palette_search` (`GET /palette/search`, `shell/palette#search`, JSON) served by `Shell::PaletteController`.
    - `Shell::PaletteSearch` (`MAX_RESULTS` 20, `MIN_QUERY` 2, `KINDS` meeting / team / swimmer / data_fix_session, `Result#to_h` with `kind_label`).
    - `Shell::Navigation.palette_entries(offline: false)` (every item, `group_label`, `context`).
    - `LookupController.search_scope(model, query)` (public class method).
    - Locale `config/locales/palette.{en,it}.yml` (`shell.palette.*`); stylesheet `shell/_palette.scss`.
- **Deviations (the code won).**
  - `LookupController` already had `meeting(s)` / `swimmer(s)` in `MODELS` / `SAFE_COLUMNS` since phase 13. Part B only made `search_scope` a public class method, so the palette searches "through LookupController".
  - Index actions converted: 17. These are the 15 grid request-spec controllers plus calendars and standard timings, which now have their own request specs with a 503 example. Trainings uses `render_api_error`. `api_meeting_reservations#expand` (a detail page, not an index) still redirects to root on an API error.
  - Spec assertions changed beyond `api_trainings_controller_spec.rb`'s redirect example: one. `api_users_controller_spec.rb` "renders the Devise tracking columns" now requests `locale: 'en'`, because the headers follow the locale (default `it`). Its stub is unchanged.
  - `header:` options:
    - The grids had 88 `header:` options (the plan said 82). 86 moved to the locale files. The 2 empty ones of `HealthFindingsGrid` stay `header: ''`.
    - Every column and filter without a header also got a key, so the Italian pages are translated throughout.
    - The three grids that used Datagrid's own `datagrid.<grid>_grid.{columns,filters}.*` keys moved to `grids.*` too: `operation_runs` (11/13), `remote_writes` (05) and `health_findings` (06). Their old blocks were deleted from `maintenance` / `remote_writes` / `health` `.{en,it}.yml`, and `operations/index` and `health/sections/show` were repointed.
    - The English texts are unchanged, with two intended exceptions. The Issues headers were evaluated once at class load, so the English page showed Italian ones. The Import queues `batch_sql` column now reads "SQL batch": its header was lost because `boolean_column` passes its options positionally into Datagrid's `query`. That last quirk is not fixed: fixing it would change the sorting and visibility of every boolean column.
  - CSV exports keep the English header row (`CSV_LOCALE`), so a spreadsheet built on them doesn't change with the default Italian locale. A CSV request answered by an API error redirects to the page.
  - Drill links:
    - Team managers are filtered by `team_name`: the admin2 index call passes no `team_id`, and its `APIProxy.call` arguments are frozen, although the API supports it.
    - "The local meeting's calendars grid" is the calendars of the meeting's season: the calendars API call takes only `season_id`.
    - The Season board link exists only for meetings of the board season (`SeasonDefaults.default_season_id`): the row anchor when a local calendar has `results_code`, the board otherwise.
    - The existing eye-icon lookups (badges, calendars, team affiliations, team managers) and the Import queues Outbox link use `Grid::DrillLinkComponent` too.
    - Teams' `tas_lookup` and swimmers' `badges_lookup` columns became `drill`.
  - Palette entries:
    - They are every navigation item, not only the sidebar ones (exit criterion "reaches every `Shell::Navigation` entry"). A contextual child carries `context` (its parent's label) and its registry path, which is the parent page; e.g. Season-start checklist leads to `/operations`.
    - In an API-offline session only the `offline_ok` items are listed and there is no search URL; `palette#search` is not offline-allowed.
  - A meeting result opens the Meetings grid filtered by `name` (FULLTEXT on description) and `season_id`: there is no local meeting page. A team or a swimmer opens its grid filtered by name. A Data-Fix session opens its Resume step, or the sessions list when the source file is gone.
  - `GET /palette/search` has `format: :json` by default, so an anonymous request gets Devise's 401 JSON instead of a redirect. It is listed in the navigation spec's non-page routes.
  - The trigger is icon-only under 1600 px, like the status pill labels; label and `Ctrl K` show above. At 1400 px the seven status pills must stay visible (app shell journey 12, remote writes journey). `.app-topbar-search` got `flex-shrink-0`. The palette modal has no `fade`, so open and close are instant and Turbo never caches an open palette.
  - Palette texts live in a new pair `palette.{en,it}.yml` (`shell.palette.*`), instead of the shared `shell.*.yml`.
  - The system journey covers a meeting opened by name, a sidebar page reached, arrows, Esc, and Ctrl+K ignored inside a field. A Data-Fix session opened by name is covered by the service and request specs only: a browser journey would need a phase file under the real `crawler/data`.
- **Not verified.**
  - A real API error page from a running goggles_api: all through stubs (`APIProxy::Result` doubles, unreachable result).
  - Cmd+K on macOS and Ctrl+K in Firefox. Only headless Chrome's Ctrl+K was exercised.
  - Palette search latency on the real `crawler/data`: `DataFix::SessionIndex` rescans the phase files and runs two grouped staging counts per search request.
  - Screen-reader behaviour of the combobox / listbox.
  - The palette and the grids with the dev server: not started, as instructed.

### Part C outcome (0.10.96, 2026-11-24)

Steps 11 and 12 (scope I and J) delivered on `feature/modernize-admin-console-ux`, in the working tree on top of 76c2fe8 (not committed). Decisions applied with their defaults: old GET redirects kept for one release, the engine goggle-cup partials keep a scoped compat subset, goggles_main stays on Bootstrap 4.

- **Compat reduction (step 11)**:
  - Deleted `app/assets/stylesheets/compat/_bs4.scss`, `app/javascript/bs4_compat.js` (its `application.js` import and `config/importmap.rb` pin), and the legacy layout leftovers `compat/_full_bleed_layout.scss` + `shell/_legacy_wrappers.scss` (no view used `.wrapper-body`, `.spacer-*`, `#footer.fixed-bottom` any more).
  - Scoped subset: `compat/_goggles_db_partials.scss` (BS4 spacing, `text-left/right`, `badge-<color>`, breakpoint variants, all under `.goggles-db-partial`) and the Stimulus controller `goggles_db_partial_controller.js` (copies `data-toggle/target/dismiss/parent/placement` to `data-bs-*`, MutationObserver limited to the wrapper). The engine partials need it: `_ranking` has `data: { toggle: 'collapse' }` on "Show base timings", and `mr-*/ml-*/pr-4/text-right/badge-primary`. The two views (`goggles_cup/_ranking.html.haml`, `goggles_cup/base_timings.html.haml`) now wrap the engine render in `.goggles-db-partial{ data: { controller: 'goggles-db-partial' } }` (the compute JSON renders the same partial, so the wrapper also comes with an AJAX ranking).
  - Before deleting, a runtime audit of the whole system suite (a throwaway hook on `expect_no_js_errors`, scratch only) plus a static HAML parse listed what the global behaviour rules of `_bs4.scss` still served: no `.row` child sized by the compat rule, no `select.form-control`, no `.btn-group-toggle`; labels without `.form-label` in `LegacyAutoCompleteComponent` (4) and the session card "Maps URI" label (now `.form-label`, same spacing); tinted `tr.bg-*` rows (Settings grid, Data-Fix result cards, `verify_result_controller.js`), so `.table tr[class*='bg-'] > * { --bs-table-bg: transparent }` moved to `components/_tables.scss`; the link look (no underline, underline on hover) moved to `base/_links.scss` as an app style.
  - Remaining tokens converted: `federnuoto_watch_alert_component` `mr-2` → `me-2` (2), the `tooltips_controller.js` comment, the `_slider_switch.scss` comment, the dead `.form-group .ts-wrapper` rule of `_tom_select.scss`; `app_notifications_channel.js` drops the `.main-content` fallback.
  - `spec/bs4_leftovers_spec.rb`: ROOTS add `app/assets/stylesheets`; `SWEPT` = every root; `EXCLUDED` = the two scoped files; the engine folder `goggles_db/goggle_cups` (from `GogglesDb::Engine.root`) is counted with `BASELINE` 16, the only baseline entry; new examples: the baseline holds only engine folders, and every engine token is one the subset serves (a `form-group` in the engine would fail); the hash-key match skips boolean values (`{ toggle: false }`, the BS5 Collapse option that made up 4 of the 5 `app/javascript/controllers` tokens). Printed table: total 16, all in `goggles_db:app/views/goggles_db/goggle_cups`.
  - `Footer::MainComponent` deleted (rb + haml; no spec existed); `Shell::UserMenuComponent`'s comment no longer names it.
  - CSS rebuilt with `bin/rails dartsass:build` (`app/assets/builds/application.css`: no unscoped BS4 class, `.goggles-db-partial .ml-2` & co. only).
- **Docs (step 12)**: CLAUDE.md (Commands crawler note, ops pruning, system specs need Chrome but no network + `SYSTEM_THEME`, Data-Fix line without the legacy wizard, Sources line, one PDFs line separating manifest extraction from result parsing, crawler status file vs WebSocket, Front-end section rewritten for the scoped engine subset, stylesheet folders, CSS build tracked); AGENTS.md (manifest extraction: no BatchRunner/status-file names left; backfill script goes to the Outbox; no `data_fix_helpers` mention); README (new "What it does" section, system specs note); `docs/introduction.md` rewritten; `docs/season_board.md` links the operator guide (its Pull/Push lines were already fixed in part A); `docs/pdf_processing/manifest_extraction.md` (TXT badge of the Sources tabs, no BatchRunner/route names); `docs/data_fix/PHASES.md` ("Sources" back link, no `data_fix_helpers`); `crawler/README.md` (no Pull dashboard, no UI layout ids, no personal path, status file vs WebSocket); `docs/crawler/crawler_interaction.md` needed no change (part A already had `pdfs/<season>`); new `docs/operator_guide.md`. UI copy: the Data-Fix back links and the commit report link now read "Sources" / "Back to Sources" (en + it).
- **Leftover notes from earlier phases**:
  - 14 `Ops::SessionStoreSetup.trim!` not scheduled: done in `ops:prepare` (`Ops::Database.prepare!` deletes ops `sessions` rows not updated for `SessionStoreSetup::RETENTION` = 30 days, returns `sessions_trimmed:`, the rake prints it; `trim!` defaults to the same constant).
  - 07 "`ops:status` does not list the new tables": done (every ops table, sorted after events/settings/snapshots).
  - 07/13 "`FileCounter` has no user": deleted with `spec/services/outbox/file_counter_shim_spec.rb`.
  - 13 "Sources should name the static calendar URLs in checklist step 7": done (`maintenance.season_start.steps.static_calendars.body` en/it and the HOWTO step 7: the watcher page `FedernuotoWatch::URL`, Sources › Crawler › FIN calendar, crawl the new season's calendar once).
  - 04 `Footer::MainComponent`: deleted. 04 dark-mode notes for the Pull/PDF/file-list pages: obsolete (pages rewritten in part A; no `bg-light`/`text-dark` in `app/views/sources`, `app/components/sources`).
  - 12 remaining BS4 tokens: done (zero in the app).
  - Not done, with reason: 02 `Import::DiffCalculator` (unused, but extracted on purpose in 02 for reuse: the owner's call; 50 lines + its spec); 07 `SystemStatus::OutboxProbe` pill (not in any plan: a new feature); 08 redundant `perform_later('sql')` in `jobs_utils.rake` (goggles_api, not this repo; harmless); 13 rake-parity baselines tied to goggles_test (informational: re-record after a test dump reload); 15A old GET redirects (`/pull/...`, `/pdf/extract_txt`) kept for this release by decision, and 07's `/push/index` redirect (`PushController`) could go in the same cleanup; `federnuoto_watch#pull_calendar` (watcher alert action that opens Sources › Crawler) keeps its route name; the i18n key `home.copyright_notice` is now unused (only the footer read it), left for a locale cleanup.
- **Specs**: new system examples in `spec/system/goggles_cup_and_stats_spec.rb` (stored ranking inside the wrapper: computed `text-align`/`padding-right`/badge background, `data-bs-toggle` copied and "Show base timings" opens; BS4 classes unstyled outside the wrapper; base timings page inside the wrapper); `spec/requests/layout_assets_spec.rb` (no `bs4` module in the importmap, the new controller is pinned); `spec/models/ops/database_spec.rb` and `spec/tasks/ops_rake_spec.rb` (session trim, `ops:status` tables).
- **Runs** (`rvm 3.4.13@goggles7-rails8.1 do bundle exec rspec`): `SKIP_SYSTEM=1` spec/components + spec/views + spec/requests + spec/bs4_leftovers_spec.rb + spec/i18n_parity_spec.rb + spec/services/shell/navigation_spec.rb + spec/models/ops + spec/tasks/ops_rake_spec.rb + spec/services/maintenance/season_start + spec/config: **1562 examples, 0 failures, 24 pending** (the existing placeholder specs); spec/system light **35 examples, 0 failures**, `SYSTEM_THEME=dark` **35 examples, 0 failures** (32 before + 3 new). `bin/rails dartsass:build` ok; rubocop clean on the 10 Ruby files touched; haml-lint on the 5 touched templates 93 lints before and after, identical per file and rule.
- **Visual check**: before/after screenshots in both themes (throwaway system spec, scratch only) of the GoggleCup ranking (with base timings open), the base timings page, Data-Fix Step 1 and Step 2, the teams grid with its edit modal and Settings: same layout (pixel differences only in the factory names and the top-bar user) except the expected 8 px shorter rows (switch toggle on the cup page, review filter buttons on Step 2); the engine partials look the same.
- **Not verified**: the full suite (coordinator); the real app in a browser on the dev server (not started: no remote API calls); goggles_main (out of scope, Bootstrap 4); pages without a system journey (e.g. health, operations, season start, DB sync, restore) were checked by the static HAML audit and their request specs only, not in a browser.

## Rollback note

- Each step is its own commit. Reverting steps 2-7 restores the Pull, PDF and file-list controllers and views from git; the new jobs are additive and can stay.
- Step 4 is the only one that deletes a runtime path (`BatchRunner`). Revert it together with the rake change.
- Grid steps revert per grid.
- Compat removal reverts by restoring the two compat files and their imports.
- No database change to undo.
