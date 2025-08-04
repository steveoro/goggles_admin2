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
