# Season board

Operator guide of `/season_board` (navbar "Season board", Home button, "Back to Season board" button on the Phase 6 report). The board shows the latest MASFIN season, one row per row of the FIN "Riepilogo Eventi" page (as last stored by the hourly watcher), with the linked local meeting (individual/relay result counts), the pipeline **state** and **one next action**.

Developer notes (state rules, jobs, files): `AGENTS.md`, section "Season board".

## Weekly routine

1. Open the board. The header shows when the FIN calendar was last checked; if a "FIN calendar changed" alert is pending, its button leads here. Rows for past meetings already done and rows without a FIN link are hidden by default (use the filter toggles to show them; the state chips filter by state).
2. Rows in **Not crawled** are normally crawled automatically when the watcher sees the link appear. If you want it now, press **Crawl**.
3. **Manifest to extract**: press **Extract manifest** (a manifest PDF was downloaded; the LLM engine creates the meeting structure).
4. **Structure ready** / **Results ready** / **Header only**: press **Review structure** / **Review results** / **Review header** to open the Data-Fix wizard (Phase 1 preselects the existing meeting and its sessions by FIN event id when the meeting was committed before). Go through the steps and commit in Step 5/6. An unfinished session shows **In review (step N)**: **Resume step N** continues it.
5. **SQL to push**: press **Push** (push dashboard) to send the commit SQL to the production API.
6. **Structure committed** (meeting exists, no results yet): once the meeting date is past, **Check for results** crawls the FIN page again. This also runs automatically every day (see below).
7. **Archived, unlinked** / orphan rows: local files or calendar rows that no FIN row points to. Use **Link to meeting...** (select the calendar row) to link a FIN row to an existing calendar; a SQL script for the change is written for the push dashboard.
8. **Done** rows (meeting has results) need nothing more.

## States

| State | Meaning | Next action |
|---|---|---|
| Cancelled | FIN row (or calendar/meeting) is cancelled or postponed | none |
| SQL to push | commit SQL waiting in `results.new` | Push |
| In review (step N) | Data-Fix phase files exist | Resume step N |
| Results ready | crawled source with results, no phase files yet | Review results |
| Structure ready | manifest-derived (meeting-only) source waiting for review | Review structure |
| Manifest to extract | manifest PDF downloaded, no meeting, not extracted | Extract manifest |
| Done | linked meeting has results | none |
| Structure committed | linked meeting without results | Check for results (only when past) |
| Header only | result-free page crawled, no manifest, no meeting | Review header |
| Archived, unlinked | local files but no meeting linked to the FIN id | Link |
| Not crawled | FIN link, nothing local | Crawl |
| No link yet | the FIN row has no URL yet | none |

While a crawl or extraction is queued or running for a row, its button is disabled and the row shows the activity (this is an overlay on top of the state).

## What runs automatically

| What | When | Queue |
|---|---|---|
| Watcher check (`FedernuotoWatchJob`) | hourly at minute 30; on a detected change it queues a crawl (`MeetingCrawlJob`) for every changed row still "Not crawled" and not tried before for the same URL | `default` |
| Daily re-check (`SeasonRecheckJob`, `season_board_recheck`) | every day at 5:15am: queues crawls for past meetings still without results and past "Not crawled" rows, most recent first, at most 15 per run, skipping rows crawled in the last 20 hours | `background` |
| Crawls / extractions (`MeetingCrawlJob`, `ManifestExtractJob`) | when queued by the above or by the board buttons | `background` |

The `background` queue has a single worker thread: crawls and extractions run strictly one at a time (a crawl is given up after 30 minutes). Jobs are not retried; a failure is shown on the row (press the button again to retry).

Both the watcher and the jobs need the Solid Queue supervisor running (inside Puma by default, see `CLAUDE.md`).

## Seeing queued and running work

The **activity strip** (top of the board, and in the crawler status box of the Pull pages) lists what is running now, how many jobs are queued, and the next scheduled watcher check and daily re-check. Each row also shows its own queued/running/failed state. The log is stored in `crawler/data/season-board.json`.

## One-time backfill

Meetings committed before this feature have no FIN event id stored in their calendar row, so the board cannot link them. Run once per season, before relying on the automatic crawl:

```bash
bin/rails season_board:backfill season=<season id>              # simulation: report + SQL only
bin/rails season_board:backfill season=<season id> simulate=0   # apply (also writes the SQL script to push)
```

It reads the FIN ids from the archived crawl files and the meeting ids from the commit SQL files; whatever it can't resolve is listed in the report (with same-date FIN rows as hints) and can be linked by hand with **Link to meeting...**. Re-running it is harmless.

## Live updates

The board refreshes by itself when a job changes state. This needs Solid Cable: the `cable:` entry in the local, gitignored `config/database.yml` plus `bin/rails solid:prepare`. Without it the board still works, but while something is queued or running it only refreshes every 20 seconds (and a missing cable database never breaks the jobs).
