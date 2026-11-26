# Operator guide

How to run admin2 day to day: from a meeting published by FIN to its results on the live site. This page is the routine in plain words; each section links the technical page with every rule and state.

admin2 runs only on your own computer. It works on a **local copy of the production database**: you check and commit the data here first, then **push** their SQL scripts to the production API, which queues them and runs them on the server. Nothing reaches production without your click on **Push**.

## The routine at a glance

1. Sign in.
2. Open the **Dashboard** and read **Needs you**.
3. Open the **Season board** for the current season.
4. Let the crawls and the automatic preparation run (or start them yourself).
5. Review the meeting in the **Data-Fix** steps when it asks for it.
6. Open the **Commit summary** and press **Commit**.
7. Read the **Commit report**.
8. Push the script from the **Outbox**.
9. Confirm: the script shows **applied** and the **DB sync** check stays green (no **DB sync** pill of its own in the top bar).

The sections below follow the same order.

## 1. Sign in

Open the app in the browser on your computer and sign in with your admin account. admin2 checks your password on the local database, then asks the API configured in Settings (normally production) for a token (shown in the top bar as the **API target**).

If the API can't be reached (wrong URL, server down), you still get in, but in an **API-offline** session: a banner says so, and only the pages that need no API open (Dashboard, Outbox, DB sync, Settings, Remote writes). Fix the API URL in **System > Settings**, then sign in again.

The top bar shows, from left to right: the API target, the **status pills** (API, crawler, jobs, live updates, FIN watcher, ops DB, DB sync: a single green **All OK** pill while every check is fine, otherwise one pill per check needing attention plus an **N OK** pill for the others; hover one to read it; the OK pill opens the dashboard System column), a search button (**Ctrl+K**, see [Finding things](#finding-things)), the theme toggle and your user menu (language, version, log out).

## 2. Dashboard: what needs you

The Dashboard (`/`) is the first page after the sign-in. It never waits for the API: every value comes from the last background check.

- **Needs you**: one line per thing waiting for you, with one button each, most urgent first: blockers (for example a red DB sync), failed jobs, scripts to push, meetings to review or ready to commit, crawls and extractions to start, notices. A line disappears by itself when its cause is gone.
- **In progress**: crawls, extractions, preparations and other background jobs running or queued.
- **Season progress**: how many meetings of the current season are in each state; a chip opens the Season board filtered on that state.
- **System status**, **Data health**, **Counters** and the latest **Activity** (every commit, push, purge and job is logged; **Activity** lists them all).

Details: [dashboard.md](dashboard.md).

## 3. Season board

**Import > Season board** shows the current FIN Masters season: one row per row of the FIN "Riepilogo Eventi" page, the local meeting linked to it, its **state** and **one next action**. A watcher reads the FIN page every hour; when it changes, an alert appears on every open page.

The usual path of a row: **Not crawled** → (crawl) → **Manifest to extract** or **Results ready** → (preparation) → **Ready to commit** or **Needs review at step N** → (commit) → **SQL to push** → (push) → **Done**.

Details, every state and button: [season_board.md](season_board.md).

## 4. Crawls and automatic preparation

With the automation on (the default), most of the work happens by itself:

- a new or changed FIN row is **crawled** (results page, result PDFs, manifest PDF);
- a manifest PDF is **extracted** by the LLM engine into a meeting structure;
- every source is **prepared**: the Data-Fix steps 1-5 are built and checked in the background, and the row becomes **Ready to commit · +2 teams, +37 swimmers**, **Needs review at step N · K issues** or **Preparation failed at step N**.

The automation never commits and never pushes: those two clicks are always yours.

You can also act yourself on any row: **Crawl**, **Extract manifest**, **Prepare**, **Retry**, **Hold automation**. A crawl takes a while (the FIN server is slow: allow up to 30 minutes for a big meeting) and only one crawl runs at a time; the row shows when it is queued or running.

Meetings that are not on the FIN calendar (Microplus, FICR, Go&Swim, PDF results) start from **Sources** instead: see [Sources](#sources).

## 5. Review in Data-Fix

**Resume step N** (or **Review results** / **Review structure**) opens the Data-Fix wizard on that source. The five steps are:

1. **Sessions**: meeting, sessions, pools and cities;
2. **Teams**;
3. **Swimmers**;
4. **Events**;
5. **Results**.

Each step lists what it matched in the database and what is new. With the review filter on, you see only what needs a decision; **j** / **k** (or the arrows next to the counter) jump to the next and previous issue. Fix a wrong match, confirm a new team or swimmer, save. What you edit is kept: no automatic build ever overwrites a step you changed.

While a step builds (opening a step not built yet, **Rescan**, **Rebuild**, **Verify all**), a thin progress strip under the top bar shows what it is doing and how far it got. It never blocks the page: it floats over the top of the page without moving it, clicks go through it, it closes by itself when the work ends (or after a minute without news), and its **×** hides it. **Rescan** (in the menu of the active step) asks for a confirmation first.

**Import > Data-Fix sessions** lists every source with a review in progress (highest step, last change), with **Resume** and the purge of its staging rows.

Details: [data_fix/README.md](data_fix/README.md) and [data_fix/PHASES.md](data_fix/PHASES.md).

## 6. Commit summary

**Commit** on the board row (or the link at Step 5) opens the **Commit summary**: what the commit will create and update (meeting, sessions, teams, swimmers, badges, events, results), the new teams and swimmers by name, and a preflight check. Blocking problems are listed and the commit is refused until they are fixed.

Press **Commit** once. The commit runs in the background on the local database, in a single transaction: either everything is written or nothing is. If the DB sync check is not green, you are asked to tick a confirmation first (red blocks the commit, see [DB sync](#db-sync-and-the-guided-restore)).

## 7. Commit report

The commit opens its **Commit report**, which updates by itself: **Queued** → **Committing** → **Committed** (or **Failed** / **Refused**, with the reason and the step to review). A committed report shows the statistics, the SQL script it wrote and the season health checks queued after it. **Open the Outbox** leads to the next step; **Back to the Season board** returns to the board.

## 8. Push from the Outbox

Every script that changed the local database waits in **Import > Outbox**, numbered in one global order. The Season board's **Push** button and the commit report open the Outbox on the right script.

1. Press **Push next**, **Push all**, **Push selected** or **Push this script**.
2. Read the confirmation page: the scripts in order, the target API, its environment, a fresh ping and the DB sync verdict. Tick what it asks for (for example the DB sync warning), then confirm.
3. The push runs in the background, one script after the other in order, and stops at the first error.

Details, every state and action: [outbox.md](outbox.md).

## 9. Confirm

- In the Outbox, a pushed script is **sent** ("not verified") until the server reports it: then **applied**, or **failed** with the database error (nothing after it runs on the server until you **Retry**, **Withdraw** or delete it).
- After each push, a DB sync check runs: it should stay green (no **DB sync** pill of its own in the top bar).
- The board row turns **Done** (the meeting has results) or **Structure committed** (a manifest-only meeting: its results come later, see below).

A meeting first committed from its manifest (structure only) is crawled again when FIN publishes the results; it then comes back as **Results ready** and goes through the same routine.

## Sources

**Import > Sources** shows every file of one season (chosen at the top, remembered), in six tabs:

- **Results**: the sources waiting to be committed, with their FIN id or **non-FIN**, their steps and preparation state, and one button each (open the step, commit summary, **Prepare**). **Prepare** on a non-FIN source (Microplus, FICR, Go&Swim, PDF) runs the same background preparation as the board; the source then shows in **Needs you** like a board meeting.
- **Calendars**: the FIN calendar files; **Select meetings** to crawl some of them, **Crawl all** for the whole file.
- **Manifests**: the manifest PDFs waiting for extraction; **Extract** one or **Extract next 20**.
- **PDFs**: the result PDFs; open one to scan it with the result formats and send the result to Data-Fix.
- **Crawler**: start a crawl by hand (FIN calendar, calendar file, FIN meeting, Microplus, FICR, Go&Swim) with the meeting URL; it runs in the background and a notice tells you when it ends. Crawls never run two at a time: yours waits for the board's.
- **Files**: rename, edit or delete any file under the crawler data folder (a JSON is checked before saving; backups and archives are read-only).

Details: the *Sources* section of [season_board.md](season_board.md), [crawler/crawler_interaction.md](crawler/crawler_interaction.md), [pdf_processing/manifest_extraction.md](pdf_processing/manifest_extraction.md) and [pdf_processing/pdf_processing.md](pdf_processing/pdf_processing.md).

## Data health and operations

**Data quality > Data health** checks every season on the local database (duplicate badges, meetings without results, possible duplicate swimmers, results without swimmer, ...). One cell per season and group opens its findings; you can **Acknowledge** a finding, **Ignore** it with a note, or fix it.

**Fix** opens the matching operation (**Data quality > Operations**) with its form already filled:

1. **Dry run**: shows what would change (console output, summary, warnings, the SQL); nothing is written.
2. **Apply locally and add to Outbox**: after the confirmation the dry run asks for (a tick, or a typed text such as `MERGE 12 INTO 34` for merges), the SQL runs on the local database, then its script joins the Outbox.
3. Push it from the Outbox like a commit script.

The finding turns resolved at the next check once the problem is gone. **Operations** also lists every run (with its live progress and console) and the read-only checks.

Details: the *Data health* section of [season_board.md](season_board.md).

## Season-start checklist

At the start of each championship season (usually September/October), open **Data quality > Operations > Season-start checklist** and pick the new season. Eight steps, each opening only when the previous ones are done: season rows, categories, migrated databases, standard-timings file, standard-timings import, remote season, static calendar URLs, Season board backfill.

Details: [HOWTO_prepare_new_season_at_championship_start.md](HOWTO_prepare_new_season_at_championship_start.md).

## DB sync and the guided restore

**Data quality > DB sync** answers one question: does the local database still mirror production? Its verdict (in the top bar a green one is part of the **All OK** pill; amber or red shows a **DB sync** pill):

- **green**: fine;
- **amber**: something to read (for example remote edits made from admin2: **Acknowledge** them once checked);
- **red**: the next commit could collide with production data, or a script failed on the server: commits and operations are blocked;
- **unknown**: no comparison (API unreachable, sign in again).

**Check now** runs a fresh check. When the verdict is red because production moved on, the fix is a fresh copy of the production database: **Restore local DB...** opens the guided restore. It replaces the local database with a production dump already on your computer, keeps your sign-in, the Outbox history and the crawler files, and refuses to start while scripts are still waiting to be pushed. Every page says "Local DB restore in progress" while it runs.

Details: [db_sync.md](db_sync.md) and [db_restore.md](db_restore.md).

## Finding things

Press **Ctrl+K** (Cmd+K on a Mac), or the search button of the top bar, and type: it finds any page of the sidebar and, from two letters, meetings, teams, swimmers and Data-Fix sessions of the local database. Arrows to move, Enter to open, Esc to close.

The entity pages (**Entities**, **Support**) list the production data through the API, with filters and links to related pages; an API error shows on the page with a **Retry** button.

## Kill switches

- **Automation** (master switch), **Auto-extract manifests** and **Auto-prepare**: in the dashboard **System status** zone and on the Season board header. Off = nothing is crawled, extracted or prepared by itself; every button keeps working. **Needs you** shows **Automation paused** while the master switch is off.
- `ADMIN2_AUTOMATION=0` in the server environment forces all three off without touching the stored switches (restart the server to apply or remove it).
- **Hold automation** on a board row stops the automatic preparation of that meeting only.
- Operations: the ops setting `operations.enabled` set to false hides the **Fix** buttons and refuses the applies.

Every toggle is logged in **Activity**.

## After updating admin2

After pulling a new version (read its `CHANGELOG.md` entry first: it lists the steps a version needs):

1. `bin/rails ops:prepare`: creates or migrates the local ops database (with a backup before any migration) and prunes old events and web sessions. Always safe to run.
2. Restart the server (and the `bin/jobs` workers when you run them in their own process): new jobs and queues are only picked up after a restart.
3. Sign in again if you are asked to. After the update that moved the web sessions to the ops database (0.10.91) everybody signs in once more.

The old `/pull/...` and `/pdf/extract_txt` addresses still open the matching **Sources** tab for this release; update your bookmarks.
