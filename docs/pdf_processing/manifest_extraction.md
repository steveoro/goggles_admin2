# Meeting Manifest Extraction

The crawler downloads meeting manifests (the *manifesto* PDF with rules, venue info and the event program) into `crawler/data/manifests/<season_id>/manifest-*.pdf`. Manifest layouts vary wildly between organizers, so a regex-based parser is not viable: extraction is delegated to an **LLM engine** and its output is normalized deterministically into a `layoutType: 4` JSON source file.

Two engines are supported, sharing the same pipeline (`Extractor` + `Lt4Builder` + corrective pass):

- **`devin`** (default): shells out to the Devin CLI — each generation is a fresh `devin -p` non-interactive session (default model `swe-2-high`). Requires `devin` on PATH and `devin auth login` once. Scanned PDFs are handled by writing the rendered page PNGs into the session working dir for the agent to read.
- **`ollama`**: a locally-running Ollama server (default `gemma4:e4b`, vision-capable); scanned PDFs are submitted as base64 images to the configured vision model.

The generated files land in `crawler/data/results.new/<season_id>/<date>-<name>-lt4.json` — the same folder scanned by the phased data-import wizard — so opening them prefills **Phase 1** (meeting, sessions, pool, city) and **Phase 4** (event program). The operator reviews and corrects the data before any import; manifest-derived files contain **no results**: they can be committed as a bare meeting structure (shortened Phase 1 → Phase 6 chain, new meetings get `manifest: true`), and the results are added later by a second data-fix pass on the published-results source, which preselects the existing meeting by its FIN event id (see `docs/data_fix/PHASES.md`).

## Requirements

- `pdftotext` and `pdftoppm` (Poppler suite) on PATH.
- Engine `devin`: the [Devin CLI](https://devin.ai) on PATH, authenticated (`devin auth login`; check with `devin auth status`).
- Engine `ollama`: a local [Ollama](https://ollama.com) server (`ollama serve`) with an extraction model pulled. Tested default: `gemma4:e4b` (~7.5B, vision-capable).

Environment configuration:

| Variable                | Default                  | Purpose                                   |
|-------------------------|--------------------------|-------------------------------------------|
| `MANIFEST_ENGINE`       | `devin`                  | extraction engine (`devin`\|`ollama`)     |
| `DEVIN_MANIFEST_MODEL`  | `swe-2-high`             | Devin model used for text extraction      |
| `DEVIN_VISION_MODEL`    | = `DEVIN_MANIFEST_MODEL` | Devin model used for scanned/image-only PDFs |
| `OLLAMA_API_URL`        | `http://localhost:11434` | Ollama API endpoint                       |
| `OLLAMA_MANIFEST_MODEL` | `gemma4:e4b`             | model used for text extraction            |
| `OLLAMA_VISION_MODEL`   | = `OLLAMA_MANIFEST_MODEL`| model used for scanned/image-only PDFs    |

Devin engine notes: each `generate` (including the single corrective retry) spawns a `devin -p` session inside a dedicated temp working dir — the prompt is passed via `--prompt-file` and page images are written there for the agent to read (read-only tools auto-approve within the working dir). Agent/IDE context env vars (`ACP_BACKEND`, `AI_AGENT`, …) are scrubbed from the spawned process, because they make a nested `devin` report "Not logged in" even with valid credentials. A `devin` run is slower than a local Ollama call; SWE-2 models currently report `cost_tier: "Free"` in `devin models list`.

Ollama request options and pitfalls (context truncation, `think`, `format`,
few-shot prompting) are documented in `docs/pdf_processing/ollama_extraction_notes.md`.

## Usage

```bash
# Extract all manifests of a season (default season: 262, default engine: devin)
bundle exec rake manifests:extract season=262

# Single file
bundle exec rake manifests:extract file=crawler/data/manifests/262/manifest-....pdf

# Regenerate already-extracted outputs / override engine or model
bundle exec rake manifests:extract season=262 force=1 engine=ollama model=qwen3.5:4b
```

Each PDF is processed independently; failures are reported at the end and do not abort the batch. When the output `-lt4.json` already exists (it shares the name of the Data-Fix LT4 working copy of the crawled `<base>.json`):

- a **results source** (any result row) is never touched, not even with `force=1` (skip reason `results source already present`);
- a **previous manifest output** (`_meta.meeting_only`) is skipped unless `force=1` (`output already exists`);
- a **result-free plain working copy** with no phase files is backed up as `<base>-lt4.orig[-N].json` and replaced by the manifest LT4 (a warning records it); if phase files exist it is skipped unless `force=1`, in which case it is backed up and replaced.

The other direction is handled by `DataFix::SourceResolver`: when the crawled results later arrive, the manifest copy is backed up and rebuilt from the results (see AGENTS.md, exception 2 of the canonical source handling).

Processed manifests are then archived: the source `.pdf` and its extracted `.txt` sibling are moved from `crawler/data/manifests/<season_id>/` to `crawler/data/manifests.done/<season_id>/` (the same lifecycle used by `results.new` → `results.done`). This applies to files extracted during the run as well as files skipped with `output already exists` or `results source already present` (the job ends them as done with the message `skipped: <reason>`; the rake task prints the skip reason); only failed extractions keep their sources in place for a retry.

The task aborts early when the selected engine is not available (Devin CLI not installed/logged in, Ollama not reachable) **or** the configured model is not usable — the warning names the engine, the fix hint and the available models.

## UI-triggered extraction (one path: `PdfManifests::Extraction`)

The extraction has one implementation, `PdfManifests::Extraction.call(pdf_path:, engine:, data_root:)`: the engine preflight (`client.available?`, `model_available?`), the `Extractor` run on one PDF and the archival (`.pdf` + `.txt` to `manifests.done`). Its outcome is `:done` (`extracted (N events)` or `skipped: <reason>`) or `:failed` (`LLM engine unavailable`, `LLM model missing`, `extraction failed: <reason>`).

- **Sources page, Manifests tab** (`/sources/manifests`): **Extract** queues one `ManifestExtractJob` for the file (through the Season board scheduler when the PDF belongs to a FIN calendar row); **Extract next 20** checks the engine first, then queues the next 20 pending PDFs at priority 10, so the Season board crawls go first on the single `background` worker. The engine select (`devin`|`ollama`) is posted as the `engine` param; `MANIFEST_ENGINE` provides the default. Each job is tracked in `crawler/data/season-board.json` (queued / running / done / failed, the file name as label), shown by the tab, the activity strip and the dashboard "In progress" zone.
- **Season board**: **Extract manifest** on a row, and the automatic extractions of the pipeline planner (at most 3 attempts per PDF, 20 hours apart), queue the same job with the FIN event id.
- **`rake manifests:extract`** runs the same `PdfManifests::Extraction` inline, one file at a time (the engine is checked once), and writes the same activity entries, so the UI sees a rake run too.

The former in-page batch (`PdfManifests::BatchRunner` in a Puma thread, `crawler/data/manifests-extract-status.json`, `GET /pull/extraction_status`) is gone; a leftover status file can be deleted.

## Pipeline

1. **`PdfManifests::TextExtractor`** runs `pdftotext -layout` (reusing the `.txt` sibling when present, which also powers the TXT badge in the file list).
2. If the text layer is missing (scanned PDF) and the engine supports a vision path, **`PdfManifests::VisionExtractor`** renders the pages with `pdftoppm`; the engine consumes them (Ollama: base64 `images` param; Devin: PNG files the agent reads). Otherwise the file is skipped with a warning.
3. **`PdfManifests::ExtractionPrompt`** builds an Italian-language prompt asking for strict JSON: meeting name/edition/dates, venue name/address/city/province, pool length, max individual events, and the event list (distance in meters, stroke code, relay flag, `NxM` relay style, gender, day part, raw label).
4. **The engine client** (`DevinClient` or `OllamaClient`, resolved by `ClientFactory` from `engine=` param > `MANIFEST_ENGINE` > default `devin`) returns the parsed JSON object, retrying once on malformed output. Ollama calls `/api/generate` with `format: json` and `think: false`; Devin spawns `devin -p` with `--verbosity 0` and parses the JSON object out of stdout.
5. **`PdfManifests::Lt4Builder`** deterministically normalizes the response into LT4: dates sorted/deduped, `MX`/`misti` → `MI`, relays mapped to `M`/`S` + `NxM` codes (`M4X50SL`, `S4X100MI`…), event codes checked against `event_types`, duplicates dropped, filename-date cross-check. Every finding becomes a human-readable `_meta.warnings` entry **and** a structured `Issue` classified `retriable` (the model can plausibly fix it by re-reading the text: unknown event codes, skipped/dropped events, bad dates) or `advisory` (operator-only cues like filename/date mismatches).
6. **`PdfManifests::ProgramScanner`** scans the raw `pdftotext` output for program mentions (`200 sl`, `Staff 4x50 mix mista`…) and reports the normalized codes not covered by the extracted events. It is a completeness *heuristic* — false positives are possible and the result only feeds the corrective pass and the warnings list.
7. **Corrective pass (one-shot, text path only):** when retriable issues or missing-mention hints exist, the extractor calls the model once more with `ExtractionPrompt.build_correction` — the detected issues, the valid `event_types` code catalog, and the original manifest text. The retry output is kept **only when strictly better** (fewer retriable lines and no fewer events); either way the outcome is recorded in `_meta.warnings`. Unknown codes are never auto-remapped to a similar valid code.
8. `_meta.warnings` are shown as a banner on the DataFix Phase 1 page so the operator can verify flagged items before committing.

## LT4 manifest fields

In addition to the standard LT4 keys (`layoutType`, `meetingName`, `title`, `dates`, `place`, `seasonId`, `events`, `swimmers`, `teams`), manifest files add:

- `venueName`, `venueAddress`, `cityName`, `poolLength`
- `edition`, `maxIndividualEvents`
- `manifestSessions`: `[{date, session_order}]` — one entry per meeting day (supports >2-day meetings)
- `meetingURL`, `manifestURL`: carried over from the crawled sibling `<base>.json` (when present and non-blank), right after `layoutType`; the FIN event id parsed from them (`FINEventId`) is the key that links the meeting to its FIN calendar row (`calendars.results_code`)
- `_meta`: provenance (model, source PDF, timestamp, warnings)

`Phase1Solver` prefers `venueName`/`venueAddress` over `place`, carries `edition`/`maxIndividualEvents` into the phase-1 payload and builds one session per `manifestSessions` entry.

Extractions can also be started per meeting from the Season board (`ManifestExtractJob`, see `docs/season_board.md`).
