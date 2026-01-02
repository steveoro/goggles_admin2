# Crawler Interaction

The `goggles_admin2` application relies on an external Node.js crawler service (expected to be running locally, typically on `http://localhost:7000/`) for fetching data from public sources, primarily the Italian Swimming Federation (FIN) website.

## Triggering the Crawler

The crawler is triggered via specific actions in the `PullController`:

1.  **Calendar Crawling (`PullController#run_crawler_api`):**
    *   Triggered from the main crawler dashboard (`/pull/index`).
    *   The user selects a target season (e.g., "2023/2024").
    *   The controller calls the crawler's `/pull_calendar` API endpoint.
    *   The crawler navigates the FIN website for the specified season.
    *   **Output:** The crawler generates a `.csv` file containing a list of meetings found for that season (calendar). This file is saved locally within `goggles_admin2` under `crawler/data/calendar.new/<season_id>/`.

2.  **Result Crawling (`PullController#process_calendar_file`):**
    *   Triggered by selecting a specific `.csv` calendar file from the file list view (`/pull/calendar_files`).
    *   The controller calls the crawler's `/pull_results` API endpoint, passing the path to the selected `.csv` file.
    *   The crawler reads the `.csv`, visits the result links for each meeting listed within it.
    *   **Outputs:**
        *   If results are available directly on the web page, the crawler parses them and saves them as a standardized `.json` file locally under `crawler/data/results.new/<season_id>/`.
        *   If a PDF link for results is found, the crawler downloads the `.pdf` file, saving it under `crawler/data/results.new/<season_id>/`.

## Data Storage

The crawler saves the fetched/generated files locally within the `goggles_admin2` project structure:

*   **Calendars:** `crawler/data/calendar.new/<season_id>/some_calendar_file.csv`
*   **Results (JSON):** `crawler/data/results.new/<season_id>/meeting_<id>.json`
*   **Results (PDF):** `crawler/data/results.new/<season_id>/meeting_<id>.pdf`

These files are then listed and managed using the `FileListController` actions and are the input for the subsequent processing steps within `goggles_admin2` (PDF processing, data linking, review, and commit).

## JSON output structure

The standardized results JSON produced by the crawler has the following structure:

- __Top-level metadata__:
  - `title`, `dates`, `place`, `meetingName`, `competitionType`, `layoutType`, `seasonId`, `meetingURL`.

- __`swimmers`__ (map):
  - Keys are stable identifiers:
    - Known gender: `"G|LASTNAME|First|YYYY|Team Name"` (e.g., `"F|ROSSI|Maria|1980|TeamA"`)
    - Unknown gender: `"|LASTNAME|First|YYYY|Team Name"` (leading pipe indicates unknown)
  - Values include: `lastName`, `firstName`, `gender` (`'M'`, `'F'`, or `null`), `year`, `team`, `category`.

- __`teams`__ (map):
  - Keys are team names. Values: `{ name }`.

- __`events`__ (array):
  - Each event has: `eventCode` (e.g., `800SL`), `eventGender`, `eventLength` (meters), `eventStroke`, `eventDescription`, `relay` (boolean), and `results` (array).

- __`results`__ (array within each event):
  - Each result has: `ranking`, `swimmer` (key into `swimmers`), `team`, `timing`, `category`, `heat_position`, `lane`, `nation`, and optionally `laps`.

- __`laps`__ (array within each result, when available):
  - Each lap: `{ distance: "<meters>m", timing: "..", position?: "..", delta?: ".." }`.
  - Distances are normalized to the strict `"<meters>m"` format (e.g., `450m`).

Notes:
- Older/alternative sources may provide a legacy `heats` structure (`heats[].results[]`). The crawler and tools support both `events[].results[]` and `heats[].results[]`.

## Gender Detection

The crawler uses a multi-level fallback strategy for detecting event and swimmer gender:

### Detection Priority

1. **Event list page** (`td.GaraRound.aCenter`): Primary source from the calendar event list containing "FEMMINE", "MASCHI", or "MISTO".

2. **Event header fallback** (`#tdGaraRound`): If event list detection fails, the crawler extracts gender from the event detail page header (e.g., "FEMMINE - 50 M STILE LIBERO").

3. **Category header fallback**: If still unknown, gender is inferred from RIEPILOGO category headers like "MASTER 80F" or "MASTER 95M" where the trailing letter indicates gender.

### Gender Values

| Context | Valid Values | Notes |
|---------|--------------|-------|
| **Event gender** (`eventGender`) | `'M'`, `'F'`, `'X'`, `''` | `'X'` only valid for relay events; individual events use `''` if unknown |
| **Swimmer gender** (`gender`) | `'M'`, `'F'`, `null` | Never `'X'`; mixed relay swimmers get `null` |

### Helper Functions (utility.js)

- `extractGenderFromEventHeader(headerText)`: Parses "FEMMINE - 50 M STILE LIBERO" → `'F'`
- `extractGenderFromCategoryHeader(categoryText)`: Parses "MASTER 80F" → `'F'`

## Microplus Timing (layout 4) specifics

The new Microplus result pages sometimes render long-distance events (e.g., 800m) across two adjacent rows per athlete: the first row with regular splits (≤400m) and a continuation row with additional splits (≥450m).

- **Continuation mapping (≥450m):**
  - Continuation cells are mapped to distances starting from 450m in +50m steps.
  - If headers are partially missing in the continuation row, mapping is right-aligned and synthesized so the last cells still map to the last distances present (e.g., 700m, 750m), even if intermediate cells (e.g., 650m) are blank.

- **Distance label normalization:**
  - All split distance labels are normalized to the strict format `"<meters>m"` (e.g., `450m`, `700m`).
  - This avoids space/case variance from the source (e.g., `"450 m"`).

- **Debugging continuation parsing:**
  - Set environment variable `MICROPLUS_DEBUG=1` to enable verbose logs for continuation detection and the list of appended split distances.
  - Example: `MICROPLUS_DEBUG=1 npm test` (for the unit tests) or set it in the crawler process environment.

- **Test coverage:**
  - Unit tests cover continuation mapping and a scenario with a missing `650m` continuation cell to ensure tail distances (e.g., `700m`, `750m`) are still appended in order.
