# Season board

Operator guide of `/season_board` (sidebar "Season board", the dashboard's "Season progress" chips and inbox items, "Back to Season board" button on the Phase 6 report). The board shows the latest MASFIN season, one row per row of the FIN "Riepilogo Eventi" page (as last stored by the hourly watcher), with the linked local meeting (individual/relay result counts), the pipeline **state** and **one next action**.

The whole routine, from sign-in to the push, is in the [operator guide](operator_guide.md). Developer notes (state rules, jobs, files): `AGENTS.md`, section "Season board".

## Weekly routine

1. Open the board. The header shows when the FIN calendar was last checked; if a "FIN calendar changed" alert is pending, its button leads here. Rows for past meetings already done and rows without a FIN link are hidden by default (use the filter toggles to show them; the state chips filter by state). The board remembers the chip and the toggles you choose (cookie `season_board_filters`): the sidebar link, the page after every button (Crawl, Extract, Prepare, Link, the switches) and the links without a filter land on the same chip; a link that carries a filter (for example a "Season progress" chip of the dashboard) wins and becomes the remembered one. A link to one row (Outbox, Sources, a health finding, the meetings grid, the inbox **Link** item: `?row=<FIN id>`) shows the whole board when the remembered chip would hide that row, for that visit only (the chip stays remembered). **All** clears the chip; a remembered chip with no row left stays shown with (0), so it can be cleared.
2. Rows in **Not crawled** are normally crawled automatically when the watcher sees the link appear. If you want it now, press **Crawl**. A row with the badge **a local meeting on this date is not linked yet** is never crawled automatically: a season calendar row without FIN id falls on its dates, so the meeting may already exist (e.g. imported from FICR/Microplus). Link it with **Link to meeting...** if it is the same meeting, otherwise press **Crawl**.
3. **Manifest to extract**: press **Extract manifest** (a manifest PDF was downloaded; the LLM engine creates the meeting structure).
4. **Structure ready** / **Results ready** / **Header only**: with the automation on (the default, see [Pipeline automation](#pipeline-automation)) these rows are **prepared in the background** within minutes: the Data-Fix steps 1-5 are built and checked, and the row turns into **Ready to commit · +2 teams, +37 swimmers**, **Needs review at step N · K issues** or **Preparation failed at step N: ...**. You can still press **Review structure** / **Review results** / **Review header** to open the Data-Fix wizard yourself (Phase 1 preselects the existing meeting and its sessions by FIN event id when the meeting was committed before). An unfinished session without a check shows **In review (step N)**: **Resume step N** continues it; **Prepare** (next to it) builds the missing and stale steps in the background, never touching a step you edited.
   - **Ready to commit**: press **Commit**: it opens the commit summary; commit there (one click), then push from the Outbox (second click). Nothing is ever committed or pushed without these clicks.
   - **Needs review at step N**: **Resume step N** opens that step with the review filter on.
   - **Preparation failed**: fix the cause (the message says what failed), then **Retry**. A failed row is prepared again by itself only once its source file changes (e.g. after a re-crawl).
5. **SQL to push**: press **Push**: it opens the [SQL Outbox](outbox.md) focused on the row's commit script, pushed from there (in global sequence order, after a confirmation, as a background job).
6. **Structure committed** (meeting exists, no results yet): once the meeting date is past, **Check for results** crawls the FIN page again. This also runs automatically every day (see below).
7. **Archived, unlinked** / orphan rows: local files or calendar rows that no FIN row points to. Use **Link to meeting...** (select the calendar row) to link a FIN row to an existing calendar; a SQL script for the change is registered in the [SQL Outbox](outbox.md) (the header shows how many non-commit scripts of the season await push, with a link to the Outbox). Only calendar rows without FIN id and not cancelled can be selected; orphans whose FIN id is not on the current FIN calendar are marked and cannot be link targets (a row with nothing to link to says so).
8. **Done** rows (meeting has results) need nothing more.

A Phase 6 commit fails (and nothing is written) when the source's FIN event id is already linked, through a calendar row, to a different meeting than the one selected in Phase 1: the error names the calendar, the FIN event and both meetings. Fix the link or select that meeting in Phase 1.

When results appear for a meeting whose structure came from the manifest, the manifest-derived source and its Data-Fix phase files are replaced; copies are kept next to them as `*.orig.json` (`*-phaseN.orig.json`).

## States

| State | Meaning | Next action |
|---|---|---|
| Cancelled | FIN row (or calendar/meeting) is cancelled or postponed | none |
| SQL to push | commit SQL waiting in `results.new` (kind `commit` in the Outbox registry) | Push (opens the Outbox) |
| Preparation failed | the last background preparation failed, the source did not change since | Retry |
| Needs review | prepared (or reviewed): a step needs a decision, or is blocked; also a "ready" whose files changed since the check | Resume step N (review filter on) |
| Ready to commit | prepared: every step clean and checked after the last change (and the new teams/swimmers still new) | Commit (opens the commit summary) |
| In review (step N) | Data-Fix phase files exist without a current check (e.g. files from before 0.10.88, adopted as edited) | Resume step N (and Prepare) |
| Results ready | crawled source with results, no phase files yet | Review results |
| Structure ready | manifest-derived (meeting-only) source waiting for review | Review structure |
| Manifest to extract | manifest PDF downloaded, no meeting, not extracted | Extract manifest |
| Done | linked meeting has results | none |
| Structure committed | linked meeting without results | Check for results (only when past) |
| Header only | result-free page crawled, no manifest, no meeting | Review header |
| Archived, unlinked | local files but no meeting linked to the FIN id | Link |
| Not crawled | FIN link, nothing local | Crawl |
| No link yet | the FIN row has no URL yet, and none could be taken from the "Eventi" calendar (see [Links from the "Eventi" calendar](#links-from-the-eventi-calendar)) | none |

While a crawl, extraction or preparation is queued or running for a row, its POST buttons (Crawl, Extract, Retry, Prepare, Link) are disabled and the row shows the activity (this is an overlay on top of the state, not a state). The links (**Resume step N**, **Review ...**, **Commit**, **Push**) stay enabled while the job is only queued: the Data-Fix pages refuse edits only while a job holds the source lease. They are disabled, with a tooltip saying why, while the row is **locked**: a preparation holds the source lease, or a crawl, extraction or preparation of the row is running.

The three pipeline states come from the ops DB (`SeasonBoard::PipelineIndex`: the stored stage and verdicts of the row's source, checked against the files on disk at every build); without the ops DB, or for files the pipeline never checked, the board shows the former states. Each of the five checks is compared with the files it read (the working copy and the steps up to its own; never the LT2 once the LT4 working copy exists, so a re-crawl that only rewrites the LT2 changes nothing): a check older than one of its files is outdated. A **Ready to commit** whose checks are outdated shows **Checks outdated** (and the planner rebuilds them). A preparation merely queued keeps the row's state (the row is busy: no second Prepare or Retry); only a running one (or the lease) shows the row as being prepared. Since the steps ignore the LT2 once the working copy exists, a row whose crawl file is newer than its working copy gets the informational flag **newer crawl on disk** (nothing changes by itself: to use the newer crawl, delete the `-lt4.json` working copy in Sources › Files and open or prepare the meeting again).

## Links from the "Eventi" calendar

The board rows come from the FIN "Riepilogo Eventi" page, where many meetings get their link late; the FIN "Eventi" calendar has a meeting link for every row. A row without a link **adopts** the link of the "Eventi" row that matches it, so it can be crawled and its files reach the board pipeline like any linked row. The row then shows the link with the flag **link from the Eventi calendar** (the tooltip gives the date of the calendar file it comes from).

- **Where it comes from**: only the newest `<YYYYMMDD>-<season>-2-FIN-calendar.csv` of the season in `calendar.new/<season>` or `calendar.done/<season>` (never a `-sel-` selection or a `-skip` leftover). It is used only when all of these hold, otherwise no link is taken at all (an older file is never used in its place) and one board warning says why: it can be read and has data rows; it is the "Eventi" calendar (every row's `startURL` is the "Eventi" page: an "Archivio" crawl writes the same file name); every meeting in it falls within the board season (15 days of margin: the season is the one chosen on the crawler tab); its date (from the file name) is at most 14 days older than the last check of the "Riepilogo Eventi" page. To refresh it, crawl the "Eventi" calendar again: Sources › Crawler › FIN calendar, menu item "Eventi". Nothing is stored: the match is made again at every board build (the board summary is rebuilt when a calendar file changes).
- **How rows match**: same first and last date, same place (without the province suffix, accents or punctuation; several places as a set). Names are never compared (the two pages spell them differently). A link is adopted only when exactly one "Eventi" row and exactly one "Riepilogo" row share the date and place (a cancelled twin or a linked twin counts too), the "Eventi" row is not cancelled and carries a FIN results link (never a manifest download link), and its FIN id appears only once in the whole file and on no other board row.
- **Self-check**: the meetings listed with a link on both pages are compared first. If more than 10 % of them get another FIN id from the "Eventi" calendar, or fewer than 3 can be compared, no link is adopted and a board warning says why.
- **The "Riepilogo Eventi" link always wins**: as soon as FIN publishes a link for the row, the board uses it (and the flag goes away). If it differs from the "Eventi" one, a board warning names both FIN ids.
- **What it changes**: an adopted row works as a linked one: **Crawl** (the crawl job checks the adopted link again against the calendar file, never trusting the link it was given), the background preparation of the crawled files and the dashboard items; a result-free crawl moves it to **Header only** / **Manifest to extract** like any row. The daily re-check crawls a past adopted row (or retries a failed one) at most once a day and stops after 3 failed crawls in a row: then only **Crawl**, or the link published later on the "Riepilogo Eventi" page, crawls it again. The automatic crawl after a watcher change still needs the "Riepilogo Eventi" link. **Link to meeting...** on an adopted row always opens a confirmation page first: it says the FIN id and the link come from the "Eventi" calendar file (name and date), not from the summary page, since the link goes into the local calendar and into an SQL script for production.
- **Files whose FIN id is on no row**: when an adoption goes away (a newer or too old calendar, a failed self-check, a new twin), or for a meeting listed only on the "Eventi" calendar, the files already crawled stay where they are. Their pending work is never hidden: the board lists them in a warning ("pending sources have a FIN id that is on no board row"), the dashboard inbox shows one item per source (opening it in Data-Fix), and the Sources Results tab labels them **FIN <id> · not on the board**; a pending commit script stays in the Outbox as always.

## What runs automatically

| What | When | Queue |
|---|---|---|
| Watcher check (`FedernuotoWatchJob`) | hourly at minute 30; on a detected change it queues a crawl (`MeetingCrawlJob`) for every changed row still "Not crawled" and not tried before for the same URL | `default` |
| Daily re-check (`SeasonRecheckJob`, `season_board_recheck`) | every day at 5:15am: queues crawls for past meetings still without results and past "Not crawled" rows, most recent first, then retries the failed automatic crawls of any date; at most 15 per run, skipping rows crawled in the last 20 hours and rows with a not-yet-linked local meeting on their dates | `background` |
| Crawls / extractions (`MeetingCrawlJob`, `ManifestExtractJob`) | when queued by the above, the pipeline planner or the board buttons | `background` |
| Re-crawl on "results published" (`CrawlPlanner#plan_recrawl`) | on a watcher change: a **Structure committed** row listed by FIN under "with results" is crawled again, at most once per 20 hours | `background` |
| Pipeline planner (`PipelinePlannerJob`, `pipeline_planner`) | after every crawl, extraction, successful preparation and watcher change, every 15 minutes, and on **Prepare all** (see [Pipeline automation](#pipeline-automation)) | `default` |
| Preparations (`DataFixPrepareJob`) | when queued by the planner or by **Prepare** / **Retry** (also **Prepare** on a non-FIN source of the Sources Results tab) | `pipeline` (shared with the commit job, which runs first) |
| Manual crawls (`SourceCrawlJob`) | **Crawl** on the Sources crawler tab, **Crawl selected** / **Crawl all** on a calendar CSV | `background`, priority 10 (after the queued board crawls) |
| PDF scans (`PdfScanJob`) | **Scan** on a PDF of the Sources PDFs tab | `pipeline`, priority 10 (a queued commit runs first) |

The `background` queue has a single worker thread: crawls and extractions run strictly one at a time (a crawl is given up after 30 minutes). A failure is shown on the row (press the button again to retry; failed automatic crawls are also retried by the daily re-check). If a job could not even be queued, the board shows the error in a flash message. A queued or running job with no progress for too long shows **seems stuck** and its button is enabled again.

Every planner pass (every 15 minutes, also with the automation off) first reconciles the activity log with the jobs (`SeasonBoard::ActivityReconciler`): a preparation still shown queued or running whose run has ended is closed with the run's outcome, and a queued crawl, extraction or preparation whose job is no longer in the Solid Queue queue (2 minutes after it was queued) is closed as failed, "lost" (the inbox offers **Retry**). Every way out of a preparation closes its row entry itself, also a refusal before the start and a run skipped by a DB restore (closed as refused, "a DB restore is in progress": the planner queues it again later).

The manual crawls of the [Sources](#sources) crawler tab (`SourceCrawlJob`) run on the same worker with the same concurrency key, at a lower priority: a manual crawl queued while a board crawl runs waits for it (the form says how many crawls are ahead), and the queued board crawls go first. The crawl job also waits (up to 5 minutes) for a crawl the crawler reports as running.

Both the watcher and the jobs need the Solid Queue supervisor running (inside Puma by default, see `CLAUDE.md`).

## Pipeline automation

The board takes a meeting from crawl through manifest extraction to **Ready to commit** or **Needs review at step N** by itself. The boundary is fixed: jobs may crawl, extract manifests, build the Data-Fix steps 1-5 and flag issues; the local **commit** and the remote **push** always need your click (Commit on the commit summary, Push in the Outbox). There is no bulk commit. A preparation makes no remote write; its only possible API call is the read-only DB sync check of the [DB sync](db_sync.md) gate (`GET tools/db_fingerprint`, light), as before a commit (`spec/automation_boundary_spec.rb` pins both).

**The chain.** Watcher change → crawl (`MeetingCrawlJob`) → planner pass → preparation (`DataFixPrepareJob`, steps 1-5, or step 1 only for a result-free source) → **Ready to commit** / **Needs review** in the board and the inbox. A pending manifest PDF is extracted automatically (`ManifestExtractJob`), then the extracted structure is prepared. When FIN later marks a structure-committed meeting as having results, it is crawled again. If a link of the chain is lost (a job died, the server was down), the 15-minute planner pass picks it up.

**What the planner queues** (`SeasonBoard::PipelinePlanner`, board season only, FIN rows only):

| Row | Queued |
|---|---|
| Results ready | prepare steps 1-5 |
| Structure ready / Header only | prepare step 1 |
| Needs review / Ready to commit, with a stale or outdated check | rebuild the stale steps |
| Needs review / Ready to commit, new teams or swimmers and a commit since | refresh the new-entity matches (as opening Step 2/3 does) |
| Step 5 blocked by a staging collision whose other source is now committed | rebuild step 5 |
| Preparation failed, source changed since | prepare again |
| Manifest to extract | extract the PDF (at most 3 automatic attempts per PDF, at least 20 hours apart, only while the LLM engine answers; every automatic attempt that did not end well counts, including one left hanging by a restart, but not one refused because the automation was off; then the inbox item **Extract manually**) |

Never queued: rows held by you, busy rows, rows prepared less than 10 minutes ago (1 hour after a refusal), outdated checks of a source unchanged since its last successful preparation (that preparation would build nothing), and **any source holding an edited step** (your edits, or files from before 0.10.88, which count as edited): use the row's **Prepare** button for those, which never rewrites an edited step either. At most 5 preparations and 3 extractions per pass.

**Preparation rules** (`DataFixPrepareJob`): no retries; a failure ends as **Preparation failed** with its message; it refuses to start while automation is off (automatic runs), without the ops DB, on a red DB sync verdict or during a DB restore (an amber/unknown verdict is noted on the run), when the source left `results.new` or a commit of it is pending; it holds the source lease for the whole run (Data-Fix edits, "Rebuild (discard edits)" and the category recompute of that source are refused meanwhile, "being prepared, retry in a moment"); a soft deadline of 20 minutes (the largest real meeting prepares in under 2 minutes); between two steps it yields to a queued commit. An automatic preparation takes the lease and checks the edits before anything else, and never lets the source resolver rewrite the working copy of a source that already has steps (LT2 data under the `-lt4` name, a manifest copy replaced by the published results, categories to normalize): it stops with "the source needs an operator review first", and opening the source in the Data-Fix wizard does the rewrite as before. Progress and history live in the ops DB (`pipeline_runs`).

**Fail closed.** When the ops DB cannot be read (for example a locked SQLite file), automatic work stops instead of guessing: an unreadable switch counts as off, an unreadable commit or busy check counts as busy, an unreadable attempt count as "given up", unreadable board facts queue no preparation in that pass. The board buttons keep working.

**Kill switches** (dashboard system column, and the **Automation** line of the board header; one switch each, flipped in place: the board keeps its chip and the open panel; each toggle is logged in `/activity`):

- **Automation (master switch)**: off = nothing is crawled, extracted or prepared automatically (the buttons keep working);
- **Auto-extract manifests**: the unattended LLM extraction;
- **Auto-prepare (Data-Fix steps 1-5)**: the unattended preparation.

`ADMIN2_AUTOMATION=0` in the server environment forces all three off at once without touching the stored values (restart the server to apply or remove it): the switches then show off and cannot be flipped (the tooltip says why). A switch whose stored value cannot be read shows off (fail closed). While the master switch is off, the inbox shows **Automation paused**. The **Auto-prepare** switch of a row (on by default) turned off holds that meeting: the automation never prepares it (its buttons keep working); turned on again it releases the hold; the row updates in place. **Prepare all** (board header) runs a planner pass now.

### Worker mode

By default the Solid Queue workers run inside Puma (`plugin :solid_queue`), so preparations share the CPU with the web UI. To keep the UI responsive during long preparations, run the workers in their own process: in `Procfile.dev` uncomment the `jobs:` line **and** add `SOLID_QUEUE_IN_PUMA=false` to the `web:` line (both lines are written there as comments), then restart foreman:

```
web: env -u DATABASE_URL RAILS_ENV=development SOLID_QUEUE_IN_PUMA=false bin/rails server -p 3000
jobs: env -u DATABASE_URL RAILS_ENV=development SOLID_QUEUE_IN_PUMA=false bin/jobs
```

Never run both variants together (two supervisors). The dashboard system column shows which mode is active.

## Sources

The **Sources** page (`/sources`, Import menu; it replaces the former Pull, PDF and file-list pages, whose old URLs redirect for one release) shows the files of one season (chosen at the top, remembered) in six tabs:

- **Results**: the sources waiting in `results.new/<season>`, with their FIN id (a link to the board row) or **non-FIN**, layout, phase files, staged rows and preparation state. A FIN meeting is followed on the board. A non-FIN source (Microplus, FICR, Go&Swim, PDF) offers **Prepare**: the same background preparation as the board (steps 1-5, it stops at review; while it waits in the queue the row shows a disabled **Preparation queued**); the source then shows in "Needs you" as **Ready to commit**, **Needs review at step N** or **Preparation failed** like a board row. The automatic planner never prepares a non-FIN source by itself: the click is the opt-in.
- **Calendars**: the FIN calendar CSVs (originals, `-sel-` selections, `-skip` leftovers, already crawled). **Select meetings** opens the meeting selection; **Crawl all** queues the whole file.
- **Manifests**: the manifest PDFs waiting for extraction: **Extract** one file, or **Extract next 20** (lower priority, so the board crawls go first). One extraction path for the board, this tab and `rake manifests:extract`.
- **PDFs**: a result PDF opens on a page with the first text page, the scan form (format family, page range, verbose log) and the last scan result; **Scan** runs in the background and ends as "parsed with <format>" (with **Open in Data-Fix**) or "no format matched at page N", with the checked formats and the parser log.
- **Crawler**: the crawler server state, the background activity and one form per crawl kind (FIN calendar, calendar CSV, FIN meeting, Microplus, FICR, Go&Swim) with a real URL field checked against the site; each crawl is queued as a job and a toast on every page tells when it ends, with a link to the new file.
- **Files**: every folder of `crawler/data` (also `misc`, `goggle_cups`, `normalize`); rename, edit or delete a file. Paths never leave `crawler/data`; the backup and dated folders (`pdfs.done`, `pdfs.backup`, `results.backup`, `results.old`, `redo`, `results.done.YYYY`) and the state files of the data root are read-only, SQL scripts are left to the Outbox. A JSON is validated before saving; saving a Data-Fix phase file marks the step as edited by you, so no automatic build overwrites it.

## Seeing queued and running work

The **activity strip** (top of the board, and in the activity card of the Sources crawler tab) lists what is running now (crawls, extractions, preparations, also the manual ones of the Sources pages, under their label), how many jobs are queued, and the next scheduled watcher check and daily re-check. Each row also shows its own queued/running/failed state. The log is stored in `crawler/data/season-board.json` (kinds `crawl`, `extract`, `prepare`; a preparation entry keeps the id of its run); the preparation and automatic-extraction runs are also kept in the ops DB (`pipeline_runs`). A crawl of the Sources crawler tab is logged under its own key, and also as a finished crawl of each FIN meeting found in its new result files (unless that meeting has a crawl queued or running), so the rows show the right "last crawl".

## One-time backfill

Meetings committed before this feature have no FIN event id stored in their calendar row, so the board cannot link them. Run once per season, before relying on the automatic crawl:

```bash
bin/rails season_board:backfill season=<season id>              # simulation: report + SQL only
bin/rails season_board:backfill season=<season id> simulate=0   # apply (also writes the SQL script to push)
```

It reads the FIN ids from the archived crawl files and the meeting ids from the commit SQL files; whatever it can't resolve is listed in the report (with same-date FIN rows as hints) and can be linked by hand with **Link to meeting...**. Re-running it is harmless.

Both write the local DB, so they pass the [DB sync](db_sync.md) gate first: **Link to meeting...** asks you to tick the DB sync warning (amber, red or unknown) on a confirmation page before linking; `simulate=0` stops on a red verdict unless you add `force=1` (other warnings are printed).

## SQL scripts in the season folders

Every script that changes the local DB (commit, calendar link, backfill, flag cancelled, team manager, rake merge/fix, ...) is written by `Outbox::Writer` with the next number of one **global** sequence (`NNNN-` prefix, every folder and producer) and registered in the [SQL Outbox](outbox.md) with its kind. `SeasonBoard::DiskIndex` asks the registry for the kinds (one query per build): only `commit` scripts are source SQL (they drive **SQL to push** and the `pushed` flag); any other script of the season folder (team manager, merge, calendar link, ...) is counted apart (`other_sql_paths`, the header counter) and never shows up as a file without FIN id. Without the ops DB the name decides (`BOARD_SQL_REGEXP` => other, a `-lt4`/`-l4` suffix => commit). Cross-season scripts (rake tasks) go to `results.new/misc/`.

## The dashboard summary

The dashboard (`/`, see [dashboard.md](dashboard.md)) shows the board without opening it: one "Needs you" item per row with a next action (the same button as on the row; pushes are left out, and so are the busy rows whose action is a POST and the locked rows: a review or commit link stays while a job is only queued; the rows **Ready to commit**, **Needs review** and **Preparation failed** have their own sources with the state text, plus **Extract manually** after 3 failed automatic extractions, **Retry** for a failed or stuck crawl or extraction and for a stuck or lost preparation, and **Automation paused**), the queued and running work, and the state counts as "Season progress" (each chip opens the board filtered on that state).

It reads a **stored summary** of the board instead of building it on every landing:

- `SeasonBoard::Snapshot` keeps the summary of the last full build in the ops DB (`Ops::Snapshot` key `season_board:<season_id>`): state counts, the rows (FIN id, name, dates, URL, state, next action, busy, locked, flags), the files without FIN id, the board SQL waiting, warnings.
- `Snapshot.fetch(season)` serves the stored summary while its **fingerprint** still matches and it is less than 10 minutes old, else it rebuilds the board and stores the new one. The fingerprint covers the watcher and activity-log files, the five season folders scanned by `DiskIndex`, the season's calendars and meetings (count and last update) and the last commit / purge / calendar-link event. An in-place edit of a phase file changes none of these: the 10-minute limit covers it.
- Every full build stores its summary: the board page (always built live on GET), `CrawlPlanner`, `PipelinePlanner`, `SeasonRecheckJob`. The crawl, extraction and preparation jobs (queued, started, finished) drop it (`Snapshot.invalidate!`, next to their `SeasonBoard::Notifier.ping`); a commit, a staging purge or a calendar link changes its fingerprint, and so do the pipeline facts of the season (stage, lease or hold of a source, a prepare run queued or finished, the db generation; not the throttled progress writes).
- The board's POST buttons (crawl, extract, link) look the row up in `Snapshot.fetch` (URLs come from the stored row, never from the request), so a click runs no build while the summary is fresh.
- Without the ops DB everything still works: `fetch` builds live and stores nothing.

The target of a row's next action (Data-Fix review step, the Outbox focused on the row's script, a POST to the board, or the board row itself for **Link**) comes from `SeasonBoard::ActionPaths.target_for(row.next_action)`, shared by the board rows and the dashboard inbox: `http_method` (`:get` or `:post`), `path` and the POST `params` (the FIN event id only). `ActionPaths.board_row_path(fin_event_id, state:)` opens the board on one row.

## Live updates

The board refreshes by itself when a job changes state. This needs Solid Cable: the `cable:` entry in the local, gitignored `config/database.yml` plus `bin/rails solid:prepare`. Without it the board still works, but while something is queued or running it only refreshes every 20 seconds (and a missing cable database never breaks the jobs).

## Data health (closed seasons)

The board covers the current season; `/health` (sidebar **Data quality > Data health**) checks every season with data, closed ones included, on the **local mirror** (the local MySQL DB, which may differ from production). One row per season, one column per group (Meetings, Badges, People, Results, Setup) with the open error / warning counts; a cell opens the season page, whose sections (one per check, loaded when opened) list the findings with filters, bulk **Acknowledge / Ignore (note required) / Reopen**, and a detail page: evidence, entity links, the rake command with the ids filled in, the how-to text.

- Checks are read-only (`Health::Checks::*`, catalogue in `Health::Registry`): meetings without results (no source / source on disk), cancelled flags out of step, calendar rows never imported or sharing a FIN id, meetings without events, results flag not set, duplicate badges (sure / possible), relay-category badges, similar teams, possible swimmer duplicates, duplicate results, results without swimmer, several results per badge and program, season setup. Findings and runs live in the ops DB (`health_findings`, `health_runs`); the triage survives the next runs (a finding is keyed by its check and entity ids).
- They run as `Health::SeasonRunJob` on the single-thread `maintenance` worker: hourly heartbeat `health_sweep` (current and upcoming seasons once a day after 06:30, one overdue closed season per heartbeat, skipped when its data stamp is unchanged), **Re-run** / **Run all** buttons, and every group of the season after a Data-Fix commit.
- **Fix** buttons (phase 11, sidebar **Data quality > Operations**, `/operations`): a finding offers the maintenance operations that fix it (`Maintenance::Registry`). Each opens the operation form prefilled from the finding, then a **dry run** page (console output of the strategy, summary, warnings, errors, the SQL and its digest; nothing is written), then **Apply locally and add to Outbox** with the confirmation the dry run asks for (one click; a checkbox; or a typed text such as `MERGE 12 INTO 34` for merges and for risky options) and the DB sync tick when the check is not green (red blocks). The apply re-plans on the live data and is refused when anything changed since the dry run; the SQL runs on the local DB first, and only then is `NNNN-<name>.sql` registered in `results.new/misc/` (push it from the Outbox). The season's health group then re-runs and the finding turns resolved once the problem is gone. Operations: **Flag cancelled** (`meeting.set_cancelled`: meetings and calendars without results; prefer **Ignore with a note** for a meeting that took place without published results), **Merge badges** (`badge.merge`: sure / possible duplicates, one pair per apply; relay-category fix), **Fix NULL swimmers** (`results.null_swimmers_fix`), **Delete duplicates** (`results.dedupe`, refused while the meeting has an open NULL-swimmers finding), **Recompute ranks** (`ranks.recompute`, suggested after a dedupe or a badge merge, never chained), **Run the backfill** (`season_board.backfill`), **Merge swimmers** / **Merge teams** (typed confirmation). The run history and every run page (live status) are on `/operations`; the commit report lists the Fix links of its badge and duplicate findings. The **Operations** switch (dashboard system column and `/operations` header; ops setting `operations.enabled`, event `operations.switched`) turned off hides the Fix buttons and refuses the applies (rollback switch); scripts already registered stay in the Outbox. The switch stays on `/operations` while off, so that it can be turned back on; without the ops DB, or when the stored value cannot be read, it is greyed out with the reason next to it. The rake tasks keep working as before (`simulate=1` stays rake-only).
- **More operations, inspectors and the season-start checklist** (phase 13): **Merge meetings** (`meeting.merge`, typed; the post-merge counts check is appended to the run console), **Fix the team in the meeting** (`meeting.team_fix`), **Fix the team / the swimmer of badges** (`badge.team_fix`, typed with *nuke team*; `badge.swimmer_fix`), **Purge the meeting** (`meeting.purge`, typed), **Normalize coded names** (`coded_names.normalize`, typed), **Import the standard timings** (`standard_timings.import`: the script goes to `results.new/<season>/`, held until the remote season exists) and **Fix the season badges** (`season.badge_fix`, typed: one step per run, the sure duplicate merges first, then the relay-only and the relay badges, the possible merges only on request with a team filter; one script per step, each badge in its own transaction; long, with progress and **Cancel** on the run page; its button sits on the `badges.duplicate.sure` section and on the sure / relay badge findings; run it again while it suggests itself). **Clone the categories** (`categories.clone`) is opened only from the season-start checklist. The id fields of the forms look the names up in the local DB. Read-only **checks** (the `check:*` reports: team / swimmer / badge merge checks, season badge analysis, team badge map, swimmer results map, duplicate badges of a team, badges with duplicate results in a meeting) run as dry runs with nothing to apply. The **Season-start checklist** (`/operations/season_start/<season_id>`, also linked by the `season.setup` findings) is described in `docs/HOWTO_prepare_new_season_at_championship_start.md`. The operational rake tasks (`merge:*`, `fix:*`, `purge:meeting`, `recompute:ranks`, `normalize:coded_names`, `import:*`, `check:*`, `season_board:backfill`) are now thin callers of the same operations (`Maintenance::RakeRunner`, history on `/operations` with origin *rake*): same names, options, texts, prompts and exits; `simulate=1` registers the script held *not applied locally*, `simulate=0` checks the DB sync gate (`force=1` overrides red), applies locally, then registers it.
- Before phase 11, **Flag cancelled** wrote `NNNN-meeting_cancel-<meeting_id>.sql` / `NNNN-calendar_cancel-<calendar_id>.sql` into `results.new/<season>/` (still recognised by the board); the old `/health/cancellations/new` URL now opens the operation form.
- Season board's current-season meetings show up too, but only 14 days after their date (the board handles the recent ones).
