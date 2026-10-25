# Goggles Admin2 Agent Notes

## DataFix V2 canonical source handling

- `DataFixController` maps LT2 inputs to persistent sibling `-lt4.json` working copies via `resolve_working_source_path` and `materialize_lt4_working_copy`.
- Reuse existing LT4 working copies when present; regenerate only when missing.
- Phase review/update/add/delete actions must use the canonical source path and propagate `file_path` in redirects.
- Phase1 fixture sources use `layoutType: 4` to keep existing phase-path assumptions stable.

## Phase 1 DataFix pool/city rehydration

- JS helpers `rehydrateSessionPoolAndCity` and `rehydrateSessionCityFromId` live in `app/javascript/data_fix_helpers.js`.
- `_session_form_card.html.haml` wires the existing-pool dropdown and city hidden-id `onchange` to trigger refresh.
- `Phase1SessionUpdater` detects `swimming_pool.id` changes and overwrites pool/city fields from the DB pool/city, clearing city fields when the selected pool has no city.
- Request specs for rehydrate, city-clear, and stale-city overwrite are in `spec/requests/data_fix_controller_phase1_spec.rb`.

## Calendar meeting selection before result crawling

- `/pull/calendar_meetings?file_path=…` (checkbox icon on `.csv` files in `/pull/calendar_files`) renders one row per meeting with URL/manifest/source state; `POST /pull/process_selected_meetings` writes a `<base>-sel-<ts>.csv` subset next to the source and calls `/pull_results` on it. The ⚡ bolt icon still runs the whole-file `process_calendar_file` path.
- `CrawlerCalendar::Sheet`/`Row` (`app/strategies/crawler_calendar/`) are FAITHFUL Ruby ports of the JS crawler's `normalizeText`/`parseDaysDate`/`getOutputJSONFilename` — including quirks (`undefined-` basename for dateless rows, `2026-10-8_11-31` for `31/10-8_11`, cancelled only on literal `true`/`canc`). The predicted `manifest-<date>-<name>.pdf` must match `results-crawler.js` byte-for-byte — keep them in sync when touching either side.
- Manifest state per row: `:done` (pdf in `manifests.done/<season>/`), `:pending` (in `manifests/<season>/`, awaiting extraction), `:none`; source state reports `-lt4.json`/`.json` presence in `results.new`/`results.done`.

## PDF manifest extraction (meeting data)

- `rake manifests:extract season=<id>` turns `crawler/data/manifests/<season>/manifest-*.pdf` into `layoutType: 4` sources under `crawler/data/results.new/<season>/` via `PdfManifests::Extractor` (pdftotext + local Ollama LLM, default `gemma4:e4b`; vision fallback for scanned PDFs only when the model advertises `vision`). Successfully-extracted and already-extracted manifests (.pdf + .txt) are moved to `crawler/data/manifests.done/<season>/`; the task aborts with a warning when the configured model is not pulled.
- The same batch runs from the UI via `POST /pull/extract_manifests` → `PdfManifests::BatchRunner` in a Puma thread; progress is written to `crawler/data/manifests-extract-status.json` and polled through `GET /pull/extraction_status` by `manifest_extraction_controller.js`. `BatchRunner.archive` is the shared .pdf+.txt→`manifests.done` move used by the rake task; `BatchRunner.running?` combines a process flag with a 10-min status-heartbeat staleness window.
- Manifest LT4 files carry extra prefill keys: `venueName`, `venueAddress`, `cityName`, `poolLength`, `edition`, `maxIndividualEvents`, `manifestSessions` (one per meeting day) — `Phase1Solver` prefers them over `place`.
- Manifest files are meeting-only (no results): they can be committed as a bare meeting structure after Phase 1 (`Import::StructureValidator` gates the commit; new meetings get `manifest: true`). Results are added with a second data-fix pass on the published-results source — select the existing meeting in Step 1 and rescan sessions to avoid duplicates.
- `Lt4Builder` emits structured `issues` (retriable vs advisory) alongside `_meta.warnings`; `ProgramScanner` adds a completeness hint (program mentions vs extracted events). Retriable issues trigger ONE corrective extraction pass (`ExtractionPrompt.build_correction` feeds issues + valid event codes back to the model); the retry is kept only when strictly better. Never auto-remap unknown event codes.
- `_meta.warnings` from the LT4 source render as an info banner on the Phase 1 review page.
- Ollama calling conventions/gotchas (must set `num_ctx`, `think:false`, `format:'json'`): `docs/pdf_processing/ollama_extraction_notes.md`.

## Grid toolbar bespoke content & local lookups

- `Grid::ToolbarComponent` accepts a content block rendered at the end of the toolbar row — use it for page-specific buttons (see `api_team_managers/index.html.haml`).
- `GET /lookup/:domain[/:id]` (`LookupController`) serves whitelisted localhost-DB JSON lookups (seasons/teams/users) for `LegacyAutoCompleteComponent` widgets; the remote API cannot search seasons by description.
- `TeamManagerSqlCreate` (`POST /api_team_managers/sql_create`) creates `team_affiliations`/`managed_affiliations` on localhost inside a transaction that also writes the `SqlMaker` batch file into `crawler/data/results.new/<season_id>/` — a file-write failure rolls back the local rows.
