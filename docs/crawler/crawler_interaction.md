# Crawler Interaction

The `goggles_admin2` application relies on an external Node.js crawler service (expected to be running locally, typically on `http://localhost:7000/`) for fetching data from public sources, primarily the Italian Swimming Federation (FIN) website.

## Triggering the Crawler

Every manual crawl starts from the **Crawler** tab of the Sources page (`/sources/crawler`, phase 15) or from a calendar CSV of its **Calendars** tab. The page never calls the crawler: `POST /sources/crawls` checks the request (`Sources::CrawlRequest`: the crawl kind, the season, a URL of the kind's site — `Sources::CrawlKinds` — or a calendar CSV inside `calendar.new/<season>`) and queues a `SourceCrawlJob` (`background` worker, one crawl at a time with the Season board crawls, priority 10 so the queued board crawls go first). The job starts the crawler server if needed, waits for any running crawl to end, calls the endpoint through `CrawlerClient`, polls the crawler status until the run ends (`Crawler::RunWatcher`, 30 minutes per meeting, at most 12 hours) and lists the new files of the season folders; a toast on every open page links to the first one. The activity (queued, running with a heartbeat, done / failed) is in `crawler/data/season-board.json` under a `src:<sha1>` key, so the activity strip and the dashboard "In progress" zone show it.

1. **Calendar crawling (kind `calendar`):**
    * The user selects a target season, the FIN menu item (`Eventi`, `Riepilogo Eventi`, `Archivio 2012-`) and optionally the season text (default: the years of the season, e.g. "2023/2024"). The FIN watcher's "Pull calendar" link opens the tab with `Riepilogo Eventi` preselected.
    * `CrawlerClient#pull_calendar` calls the crawler's `/pull_calendar` API endpoint; the crawler navigates the FIN website for the specified season.
    * **Output:** a `.csv` file listing the meetings found for that season (calendar), saved under `crawler/data/calendar.new/<season_id>/`.

2. **Result crawling of a calendar CSV (kind `calendar_results`) and the meeting selection page:**
    * **Select meetings** on a CSV of the Calendars tab (`/sources/calendars/meetings?path=…`) lists one row per CSV meeting with the derived state: raw `date`/`year`/`name`/`place`, a `meetingUrl` presence flag, the manifest status (none / pending download in `manifests/<season>/` / already extracted in `manifests.done/<season>/`) and the source-file status (`results.new`/`.done`). The manifest path prediction reuses a Ruby port of the crawler's naming rules (`CrawlerCalendar::Sheet`/`Row`), so it matches `manifest-<first_iso_date>-<normalized_name>.pdf` byte-for-byte.
    * Toolbar presets auto-select rows (all/none, with meetingUrl only, only rows without a manifest on disk); cancelled or URL-less rows are disabled. "Hide extracted" and "hide uncrawlable" toggles collapse rows.
    * On submit (`POST /sources/crawls` with the selected rows) a new `<base>-sel-<timestamp>.csv` is written next to the source file with only the selected rows (same headers, verbatim field values) and a calendar CSV crawl is queued on it. The original CSV is left untouched; the generated file inherits the normal consume lifecycle (moved to `calendar.done` after the run, leftovers appended as a `-skip.csv` sibling). The page footer links to the Manifests tab when `manifests/<season>/` holds pending PDFs.
    * **Crawl all** on the Calendars tab (or the calendar CSV form of the Crawler tab) queues the whole original `.csv` without review.
    * `CrawlerClient#pull_results_from_file` calls `/pull_results` with the CSV path and the result layout of the season (1 before season 182, 2 from then on: layouts 2 and 3 are the same for result pages); the crawler visits the result links of each meeting listed.
    * **Outputs:**
        * If results are available directly on the web page, the crawler parses them and saves them as a standardized `.json` file under `crawler/data/results.new/<season_id>/`.
        * If a PDF link for results is found, the crawler downloads the `.pdf` file under `crawler/data/pdfs/<season_id>/` (`CrawlUtil.pdfsFolder`, see `crawler/server/results-crawler.js`), listed by the PDFs tab.
        * Meeting manifests (when present on the meeting page) are downloaded under `crawler/data/manifests/<season_id>/manifest-<first_date>-<normalized_name>.pdf`, listed by the Manifests tab.

3. **Direct FIN result crawling (kind `fin_meeting`, layout 2):**
    * The user enters a FIN meeting result URL (`https://www.federnuoto.it/home/master/circuito-supermaster/eventi-circuito-supermaster.html#/risultati/...`).
    * `CrawlerClient#pull_meeting` calls the crawler's `/pull_results` endpoint with `meeting_url` and `layout=2`.
    * The crawler processes the single URL, extracts the meeting header and event results, and writes one standardized layout-2 `.json` file (plus any available PDF/manifest artifacts) under the season folders.
    * No calendar file is consumed and no skipped-rows CSV is produced.

4. **Microplus result crawling (kind `microplus`, LT4 output):**
    * The user enters a Microplus meeting page URL (`https://finYYYY.microplustiming.com/...`) and, optionally, an event title to crawl only the matching events.
    * `CrawlerClient#pull_microplus` calls `/pull_results_microplus`; the output is a single LT4 JSON file under `crawler/data/results.new/<season_id>/`.

5. **Direct FICR result crawling (kind `ficr`, LT4 output):**
    * The user enters a full `https://nuoto.ficr.it/#/NUO/<page>/...` meeting URL. Any FICR meeting page works (`tempi`, `programma`, `iscritti`, `resultatleta`): they all share the same `<description>/<year>/<eqCode>/<meeting>` URL layout the crawler needs. Special characters in the meeting name (encoded UTF-8, `escape()`-style bytes, or FICR's double-encoded "mojibake" descriptions) are tolerated and repaired.
    * `CrawlerClient#pull_ficr` calls the local crawler server's `/pull_results_ficr` endpoint.
    * The FICR crawler reads the public FICR JSON services, enumerates all available gender/category/event combinations, and enriches individual rows from the swimmer history endpoint. A browser/network fallback is used when direct API acquisition fails. It processes the complete meeting.
    * Output is a single LT4 JSON file under `crawler/data/results.new/<season_id>/` (`layoutType` 4, consumed by the DataFix V2 pipeline).

6. **Direct Go&Swim result crawling (kind `goandswim`, LT4 output):**
    * The user enters a `https://risultati.goandswim.it/evento/<id>` meeting URL.
    * `CrawlerClient#pull_goandswim` calls the local crawler server's `/pull_results_goandswim` endpoint.
    * The Go&Swim crawler reads the site's public JSON API directly (no browser) and processes the whole meeting.
    * Output is a single LT4 JSON file under `crawler/data/results.new/<season_id>/` (`layoutType` 4).

The non-FIN LT4 sources (Microplus, FICR, Go&Swim) appear in the Results tab as **non-FIN**, with a **Prepare** button (background Data-Fix steps 1-5, then the inbox).

The Node server still broadcasts its status every second on its own WebSocket; nothing in the Rails app listens to it any more (the probes and the jobs read the status file or `GET /status`).

## Data Storage

The crawler saves the fetched/generated files locally within the `goggles_admin2` project structure:

* **Calendars:** `crawler/data/calendar.new/<season_id>/some_calendar_file.csv` (moved to `calendar.done/<season_id>/` once crawled)
* **Results (JSON):** `crawler/data/results.new/<season_id>/<date>-<name>.json` (LT2) or `...-lt4.json` (LT4)
* **Results (PDF):** `crawler/data/pdfs/<season_id>/<date>-<name>-res.pdf`
* **Manifests (PDF):** `crawler/data/manifests/<season_id>/manifest-<date>-<name>.pdf`

These files are listed and managed by the tabs of the Sources page (Results, Calendars, Manifests, PDFs, Files) and are the input for the subsequent processing steps within `goggles_admin2` (PDF scan, manifest extraction, data linking, review, and commit).

## JSON output structure

The standardized results JSON produced by the crawler has the following structure:

* **Top-level metadata**:
  * `title`, `dates`, `place`, `meetingName`, `competitionType`, `layoutType`, `seasonId`, `meetingURL`.

* **`swimmers`** (map):
  * Keys are stable identifiers:
    * Known gender: `"G|LASTNAME|First|YYYY|Team Name"` (e.g., `"F|ROSSI|Maria|1980|TeamA"`)
    * Unknown gender: `"|LASTNAME|First|YYYY|Team Name"` (leading pipe indicates unknown)
  * Values include: `lastName`, `firstName`, `gender` (`'M'`, `'F'`, or `null`), `year`, `team`, `category`.

* **`teams`** (map):
  * Keys are team names. Values: `{ name }`.

* **`events`** (array):
  * Each event has: `eventCode` (e.g., `800SL`), `eventGender`, `eventLength` (meters), `eventStroke`, `eventDescription`, `relay` (boolean), and `results` (array).

* **`results`** (array within each event):
  * Each result has: `ranking`, `swimmer` (key into `swimmers`), `team`, `timing`, `category`, `heat_position`, `lane`, `nation`, and optionally `laps`.

* **`laps`** (array within each result, when available):
  * Each lap: `{ distance: "<meters>m", timing: "..", position?: "..", delta?: ".." }`.
  * Distances are normalized to the strict `"<meters>m"` format (e.g., `450m`).

Notes:

* Older/alternative sources may provide a legacy `heats` structure (`heats[].results[]`). The crawler and tools support both `events[].results[]` and `heats[].results[]`.

## Gender Detection

The crawler uses a multi-level fallback strategy for detecting event and swimmer gender:

### Detection Priority

1. **Event list page** (`td.GaraRound.aCenter`): Primary source from the calendar event list containing "FEMMINE", "MASCHI", or "MISTO".

2. **Event header fallback** (`#tdGaraRound`): If event list detection fails, the crawler extracts gender from the event detail page header (e.g., "FEMMINE - 50 M STILE LIBERO").

3. **Category header fallback**: If still unknown, gender is inferred from RIEPILOGO category headers like "MASTER 80F" or "MASTER 95M" where the trailing letter indicates gender.

### Gender Values

| Context                              | Valid Values                    | Notes                                                                         |
|--------------------------------------|---------------------------------|-------------------------------------------------------------------------------|
| **Event gender** (`eventGender`)     | `'M'`, `'F'`, `'X'`, `''`       | `'X'` only valid for relay events; individual events use `''` if unknown      |
| **Swimmer gender** (`gender`)        | `'M'`, `'F'`, `null`            | Never `'X'`; mixed relay swimmers get `null`                                  |

### Helper Functions (utility.js)

* `extractGenderFromEventHeader(headerText)`: Parses "FEMMINE - 50 M STILE LIBERO" → `'F'`
* `extractGenderFromCategoryHeader(categoryText)`: Parses "MASTER 80F" → `'F'`

## Microplus Timing (layout 4) specifics

The new Microplus result pages sometimes render long-distance events (e.g., 800m) across two adjacent rows per athlete: the first row with regular splits (≤400m) and a continuation row with additional splits (≥450m).

* **Continuation mapping (≥450m):**
  * Continuation cells are mapped to distances starting from 450m in +50m steps.
  * If headers are partially missing in the continuation row, mapping is right-aligned and synthesized so the last cells still map to the last distances present (e.g., 700m, 750m), even if intermediate cells (e.g., 650m) are blank.

* **Distance label normalization:**
  * All split distance labels are normalized to the strict format `"<meters>m"` (e.g., `450m`, `700m`).
  * This avoids space/case variance from the source (e.g., `"450 m"`).

* **Debugging continuation parsing:**
  * Set environment variable `MICROPLUS_DEBUG=1` to enable verbose logs for continuation detection and the list of appended split distances.
  * Example: `MICROPLUS_DEBUG=1 npm test` (for the unit tests) or set it in the crawler process environment.

* **Test coverage:**
  * Unit tests cover continuation mapping and a scenario with a missing `650m` continuation cell to ensure tail distances (e.g., `700m`, `750m`) are still appended in order.
