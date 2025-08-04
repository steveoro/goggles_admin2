# Microplus Timing Crawler

This document outlines the usage and technical details of the Microplus Timing crawler, a Node.js module designed to extract swimming competition results from websites using the MicroplusTiming layout.

## Overview

The crawler is responsible for navigating a target meeting URL, extracting detailed results for each event, and saving the data to a structured JSON file. It is built using Puppeteer to control a headless Chrome browser, allowing it to handle the complex AJAX-based navigation of the MicroplusTiming websites.

The system consists of two main parts:
1.  `microplus-crawler.js`: The core crawler logic.
2.  `api.js`: A server that exposes the crawler via a RESTful API endpoint.

## API Endpoint

The crawler is triggered by making a `GET` request to the following endpoint:

`/pull_results_microplus`

### Parameters

The endpoint accepts the following query parameters:

| Parameter      | Type   | Required | Description                                                                                                                               | Example                                                              |
| -------------- | ------ | -------- | ----------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `season_id`    | String | Yes      | The internal database ID for the swimming season. Used for organizing the output file.                                                    | `242`                                                                |
| `meeting_url`  | String | Yes      | The full, URL-encoded link to the main results page of the MicroplusTiming meeting.                                                       | `https%3A%2F%2Ffin2025.microplustiming.com%2FMA_2025_06_24-29_Riccione_web.php` |
| `target_event` | String | No       | An optional parameter to restrict the crawl to a single event. The string must exactly match the event description text on the page. Useful for debugging. | `50 m Stile Libero`                                                  |

### Example Request

```bash
curl -X GET "http://localhost:7000/pull_results_microplus?season_id=242&meeting_url=https%3A%2F%2Ffin2025.microplustiming.com%2FMA_2025_06_24-29_Riccione_web.php"
```

## Running the Crawler

1.  **Navigate to the crawler directory:**
    ```bash
    cd /home/steve/Projects/goggles_admin2/crawler
    ```

2.  **Install dependencies:**
    ```bash
    npm install
    ```

3.  **Start the server:**
    ```bash
    npm start
    ```
    The server will start on port 7000 by default.

4.  **Trigger the crawl:**
    Use `curl` or any other HTTP client to make a request to the `/pull_results_microplus` endpoint as described above.

## Output

The crawler saves the extracted data in a JSON file located at:

`crawler/data/results/results_s<season_id>_l4.json`

For example, for `season_id=242`, the output file will be `crawler/data/results/results_s242_l4.json`. The `l4` indicates the layout version (4 for MicroplusTiming).

## Debugging

The crawler includes robust error handling and debugging features:

-   **Live Console Logs**: Detailed progress is logged to the console during the crawl.
-   **Error Snapshots**: If an error occurs while processing an event, the crawler saves:
    -   A screenshot of the page: `crawler/data/debug/error_screenshot_<timestamp>.png`
    -   The full HTML of the page: `crawler/data/debug/error_page_<timestamp>.html`

These artifacts are invaluable for diagnosing issues with selectors or page structure changes.
