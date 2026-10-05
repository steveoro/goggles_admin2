# Goggles Admin2 Agent Notes

## DataFix V2 canonical source handling

- `DataFixController` maps LT2 inputs to persistent sibling `-lt4.json` working copies via `resolve_working_source_path` and `materialize_lt4_working_copy`.
- Reuse existing LT4 working copies when present; regenerate only when missing.
- Phase review/update/add/delete actions must use the canonical source path and propagate `file_path` in redirects.
- Phase1 fixture sources use `layoutType: 4` to keep existing phase-path assumptions stable.

## Phase 1 DataFix pool/city rehydration

- JS helpers `rehydrateSessionPoolAndCity` and `rehydrateSessionCityFromId` live in `app/javascript/packs/data_fix_helpers.js`.
- `_session_form_card.html.haml` wires the existing-pool dropdown and city hidden-id `onchange` to trigger refresh.
- `Phase1SessionUpdater` detects `swimming_pool.id` changes and overwrites pool/city fields from the DB pool/city, clearing city fields when the selected pool has no city.
- Request specs for rehydrate, city-clear, and stale-city overwrite are in `spec/requests/data_fix_controller_phase1_spec.rb`.

## PDF manifest extraction (meeting data)

- `rake manifests:extract season=<id>` turns `crawler/data/manifests/<season>/manifest-*.pdf` into `layoutType: 4` sources under `crawler/data/results.new/<season>/` via `PdfManifests::Extractor` (pdftotext + local Ollama LLM, default `gemma4:e4b`; vision fallback for scanned PDFs only when the model advertises `vision`).
- Manifest LT4 files carry extra prefill keys: `venueName`, `venueAddress`, `cityName`, `poolLength`, `edition`, `maxIndividualEvents`, `manifestSessions` (one per meeting day) — `Phase1Solver` prefers them over `place`.
- Manifest files are meeting-only (no results): meant for operator prefill/review, not end-to-end commit.
- Ollama calling conventions/gotchas (must set `num_ctx`, `think:false`, `format:'json'`): `docs/pdf_processing/ollama_extraction_notes.md`.

## Grid toolbar bespoke content & local lookups

- `Grid::ToolbarComponent` accepts a content block rendered at the end of the toolbar row — use it for page-specific buttons (see `api_team_managers/index.html.haml`).
- `GET /lookup/:domain[/:id]` (`LookupController`) serves whitelisted localhost-DB JSON lookups (seasons/teams/users) for `LegacyAutoCompleteComponent` widgets; the remote API cannot search seasons by description.
- `TeamManagerSqlCreate` (`POST /api_team_managers/sql_create`) creates `team_affiliations`/`managed_affiliations` on localhost inside a transaction that also writes the `SqlMaker` batch file into `crawler/data/results.new/<season_id>/` — a file-write failure rolls back the local rows.
