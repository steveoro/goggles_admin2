# Goggles Admin2 Results Crawler Server

This directory contains the Node.js crawler service used by `goggles_admin2` to retrieve swimming meeting calendars and results. The service runs locally, normally on port 7000; the Rails crawl jobs (Season board and Sources crawler tab) start it when needed and call its HTTP API.

The results crawlers currently support:

- **FIN results** — legacy FIN result pages and calendar-file processing, layouts 1–3.
- **Microplus Timing** — AJAX-driven MicroplusTiming pages, layout 4.
- **FICR results** — FICR JSON services with LT4 JSON output (Sources crawl kind `ficr`).
- **Go&Swim results** — Go&Swim public JSON API with LT4 JSON output (Sources crawl kind `goandswim`).

All crawlers write artifacts under `crawler/data/` and report asynchronous progress through `crawler-status.json`: the Rails pages and status pill read that file, the Rails crawl jobs poll `GET /status`. (The server still broadcasts the status on its own WebSocket every second; nothing in the Rails app listens to it any more.)

## Common server setup

```bash
cd crawler   # from the goggles_admin2 root
npm install
npm start
```

The local server listens on port 7000 by default. The Rails crawl jobs start it when it is not running (`CrawlerLauncher`; also the "Start crawler" button of the Sources crawler tab).

Available API endpoints:

| Endpoint | Crawler | Use |
| --- | --- | --- |
| `/pull_calendar` | Calendar crawler | Crawl a FIN season calendar. |
| `/pull_results` | FIN results crawler | Process a calendar CSV or a direct FIN layout-2 URL. |
| `/pull_results_microplus` | Microplus crawler | Crawl a MicroplusTiming meeting URL. |
| `/pull_results_ficr` | FICR crawler | Crawl a complete FICR meeting URL. |
| `/pull_results_goandswim` | Go&Swim crawler | Crawl a complete Go&Swim meeting URL. |
| `/status` | Server | Read the current crawler status. |

## FIN results crawler

The FIN results crawler is implemented in `server/results-crawler.js`. It supports the older FIN result layouts and the current FIN result pages accessed from the Rails calendar workflow.

### API endpoint

`GET /pull_results`

The endpoint accepts either a local calendar CSV or a direct meeting URL:

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `season_id` | String | Yes | Goggles season ID used for output organization. |
| `layout` | Integer | Yes for direct mode | FIN result layout: `1`, `2`, or `3`. Layouts 2 and 3 use the current result-page parser. |
| `file_path` | String | CSV mode | Path to a local calendar CSV under `crawler/data/calendar.new/<season_id>/`. |
| `meeting_url` | String | Direct mode | One FIN meeting result URL. Direct URL mode currently requires `layout=2`. |

A direct FIN request has the following shape:

```bash
curl "http://localhost:7000/pull_results?season_id=242&layout=2&meeting_url=https%3A%2F%2Fwww.federnuoto.it%2Fhome%2Fmaster%2Fcircuito-supermaster%2Feventi-circuito-supermaster.html%23%2Frisultati%2F<meeting>"
```

CSV mode is used when the operator crawls a calendar file from the Sources Calendars tab ("Crawl all", or "Select meetings" for a subset). The crawler visits each meeting URL, skips cancelled/unavailable rows, parses the result page, and moves the processed calendar file to the appropriate completed directory.

### FIN layouts

- **Layout 1** — older/pre-2018 FIN result pages.
- **Layout 2** — direct FIN result pages and most post-2018 archived meetings.
- **Layout 3** — current-season FIN calendar/result handling; result parsing shares the layout-2 result-page logic.

The FIN crawler extracts the meeting header, event sections, swimmer/team data, rankings, timings, categories, and any result PDF links available from the source page. JSON results are written under:

`crawler/data/results.new/<season_id>/`

The resulting files are consumed by the existing DataFix/import workflow. PDF files and skipped calendar rows are kept as separate artifacts when applicable.

## Microplus Timing crawler

The Microplus crawler is implemented in `server/microplus-crawler.js`. It navigates MicroplusTiming meeting pages with Puppeteer, switches to the `PER EVENTO` view, loads each event, parses both `RISULTATI`/heat data and `RIEPILOGO`/ranking data, and merges them into a structured JSON result file.

The crawler handles individual and relay events, rankings, heats, lanes, timings, swimmer/team lookup dictionaries, and lap splits. Long-distance events such as 800m can span continuation rows; the parser maps continuation splits from 450m onward and normalizes distances to the strict `"<meters>m"` format.

### Microplus API endpoint

`GET /pull_results_microplus`

| Parameter | Type | Required | Description | Example |
| --- | --- | --- | --- | --- |
| `season_id` | String | Yes | Internal Goggles season ID used for the output directory. | `242` |
| `meeting_url` | String | Yes | Full URL of the MicroplusTiming meeting page. | `https%3A%2F%2Ffin2025.microplustiming.com%2FMA_2025_06_24-29_Riccione_web.php` |
| `target_event` | String | No | Optional event-description filter for debugging. Empty means all events. | `50 m Stile Libero` |

Example:

```bash
curl "http://localhost:7000/pull_results_microplus?season_id=242&meeting_url=https%3A%2F%2Ffin2025.microplustiming.com%2FMA_2025_06_24-29_Riccione_web.php"
```

### Microplus execution flow

1. Open the supplied meeting URL with Puppeteer.
2. Handle consent overlays and select `PER EVENTO`.
3. Extract the event list and source gender.
4. For every event, load heat results and parse individual or relay rows.
5. Switch to `RIEPILOGO` and parse category-bound ranking rows.
6. Merge rankings with heats, preferring heat timings and lap data where available.
7. Save the merged LT4 JSON output and update crawler status.

### Microplus output

The crawler writes results under:

`crawler/data/results.new/<season_id>/`

Files use a date/meeting/event/layout naming convention such as:

`<date>-<meeting>-l4.json`

The `l4` suffix identifies the Microplus/LT4 result structure. The output contains root-level `swimmers` and `teams` lookup tables and an `events` array whose result rows reference those dictionaries.

### Microplus debugging

The crawler includes robust error handling and diagnostic artifacts:

- Live progress is written to the console and `crawler-status.json`.
- If an event fails, a screenshot is saved under `crawler/data/debug/error_screenshot_<timestamp>.png`.
- The failed page HTML is saved under `crawler/data/debug/error_page_<timestamp>.html`.
- Set `MICROPLUS_DEBUG=1` for verbose continuation-row, gender-detection, and split-mapping logs.

For example:

```bash
MICROPLUS_DEBUG=1 npm test
```

## FICR results crawler

The FICR crawler is implemented in `server/ficr-crawler.js` and uses `server/ficr-api-client.js` for the public FICR JSON services. It processes a complete FICR meeting rather than only the event in the starting URL.

### FICR API endpoint

`GET /pull_results_ficr`

Required query parameters:

| Parameter | Description |
| --- | --- |
| `season_id` | Goggles season ID used for the output directory. |
| `meeting_url` | Full FICR hash URL, for example `https://nuoto.ficr.it/#/NUO/tempi/<meeting>/<year>/<eqCode>/<meetingId>/<category>/<event>`. |

The crawler enumerates the available gender/category/event/subcategory combinations, preserves category-bound ranks from filtered event results, and enriches individual results from the same-meeting athlete-history endpoint. If direct API acquisition fails, it opens the FICR page with Puppeteer and repeats the same JSON acquisition through the browser context.

FICR categories are normalized to Goggles conventions (`25F` → `M25`, `UNF` → `A20`, and relay age ranges such as `10X` → `100-119`). FICR zero-valued points that the source UI displays as blank are emitted as `null`. Missing athlete history is logged as a warning and does not discard the event result.

The optional `target_event` field used for Microplus debugging is ignored by FICR because the FICR crawler processes the complete meeting.

### FICR output

FICR writes a single LT4 JSON file to:

`crawler/data/results.new/<season_id>/<date>-<meeting>-lt4.json`

The file contains LT4 root fields, `swimmers` and `teams` lookup dictionaries, normalized `events[].results[]` entries, relay rows, points, and lap timings. The emitted JSON `layoutType` is 4, so it enters the DataFix V2 Phase 1–6 pipeline.

## Go&Swim results crawler

The Go&Swim crawler is implemented in `server/goandswim-crawler.js`, with pure payload helpers in `server/goandswim-crawler-utils.js` and the JSON client in `server/goandswim-api-client.js`. It processes a complete meeting (`risultati.goandswim.it`) and writes one LT4 file shaped like the FICR output.

### Go&Swim API endpoint

`GET /pull_results_goandswim`

Required query parameters:

| Parameter | Description |
| --- | --- |
| `season_id` | Goggles season ID used for the output directory. |
| `meeting_url` | Go&Swim meeting URL: `https://risultati.goandswim.it/evento/<eventId>` or `https://risultati.goandswim.it/gara/<eventRaceId>`. |

Example:

```bash
curl "http://localhost:7000/pull_results_goandswim?season_id=262&meeting_url=https://risultati.goandswim.it/evento/5ce2d74fd05d4a659b511251caec6132"
```

The endpoint replies at once with the current status, while the crawl runs in the background.

### Go&Swim flow

- The site is a single-page app: the crawler calls its public JSON API (`https://risultati.goandswim.it/GasRestApi/`) directly, with no browser.
- Accepted URLs are `/evento/<id>` (the whole meeting) and `/gara/<id>` (resolved to its meeting), also on `www.risultati.goandswim.it`; path segments and ids are case-insensitive.
- Races are processed in programme order (race date, then programme number) and merged into one event per event code and gender (relays included, flagged with `relay`); each result keeps its category.
- Overall individual races (category `A` or any category other than `M<age>`, e.g. "800 STILE LIBERO ASSOLUTI MISTI") are skipped with one warning when per-category master races with results cover the same length and stroke, because they repeat the same swims. Otherwise they are crawled, and the gender of each swimmer of a mixed (`X`) race comes from the same athlete in an M/F race of the meeting; when none is found the row keeps `gender: null` and a warning is added.
- Swimmer names are normalised like `Import::SwimmerNameSplitter` on the Rails side (backtick and `’` become `'`) before the split and the keys. One-word names are kept with a warning, because Phase 3 skips swimmers without a first name.
- Lap distances are deduced from the number of splits (race length / split count). Only 25, 50 or 100 m intervals are accepted, because the distance published by the site is unreliable. A last split within 0.50 s of the final time counts as the final time. Splits are requested for relays and races of 100 m or more, and for 50 m races only when the probed results carry 25 m splits.
- When the split count does not fit, no laps are written, the raw split string is kept in `source_splits`, and a warning is added to `crawlerWarnings`. A failed split request (or an empty, invalid or 404 reply) only adds a warning and the result is kept without laps; a failed results request for a race stops the crawl, naming the race.
- Disqualified rows are kept without timing. No-show rows (status `N`) are dropped and counted in a single warning.
- Relay results carry the event gender (`M`, `F` or `X`). Splits are folded into one lap per leg, using the leg count of the event (`4X50` → 4).
- Relay members come as names only (no year of birth). Each leg is attached to an individual swimmer of the same meeting when name and team match exactly once (that swimmer must have a year of birth and, for M/F races, the same gender); otherwise a year-less swimmer is registered. When the number of members differs from the number of legs, the laps are written without swimmers and a warning is added.
- Relays without usable splits, and disqualified relays, keep their members: one lap per leg with a blank `delta` (as in the Microplus output), so Data-Fix still imports the relay swimmers.
- Pool length is not published by the site and must be set in Data-Fix Phase 1.
- Requests are sequential, with a 150 ms default delay between them and up to 2 retries.

### Go&Swim output

Go&Swim writes a single LT4 JSON file to:

`crawler/data/results.new/<season_id>/<date>-<meeting>-lt4.json`

The emitted JSON `layoutType` is 4, so the DataFix V2 Phase 1–6 pipeline can consume it.

## Result JSON conventions

The standardized LT4 result structure uses:

- Meeting metadata: `meetingName`, `dates`, `place`, `meetingURL`, `seasonId`, and `layoutType`.
- `swimmers`: lookup map keyed by `G|LAST|FIRST|YOB|TEAM`.
- `teams`: lookup map keyed by normalized team name.
- `events`: event metadata plus result rows.
- Individual rows: swimmer/team references, category, ranking, timing, heat/lane, nation, and optional laps.
- Relay rows: `relay: true`, team, category, ranking, timing, and optional relay members/laps.
- Laps: normalized `distance`, cumulative `timing`, delta timing, and optional position/swimmer reference.

Results are stored under `crawler/data/results.new/<season_id>/`, then processed through the Rails DataFix workflow. The crawlers do not write directly to the production database.

## Tests

```bash
cd crawler   # from the goggles_admin2 root
npm test
```

The crawler tests cover FIN direct-input behavior, Microplus HTML/relay/continuation parsing, FICR API normalization using captured payloads under `crawler/data/samples/ficr/`, and Go&Swim API client and crawler normalization using the captured fixture `crawler/data/samples/goandswim/goandswim-sample.json` (tests: `crawler/test/goandswim-api-client.test.js`, `crawler/test/goandswim-crawler.test.js`). Tests do not call the live FIN, Microplus, FICR, or Go&Swim services.
