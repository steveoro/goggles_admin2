# Meeting Manifest Extraction

The crawler downloads meeting manifests (the *manifesto* PDF with rules, venue info and the event program) into `crawler/data/manifests/<season_id>/manifest-*.pdf`. Manifest layouts vary wildly between organizers, so a regex-based parser is not viable: extraction is delegated to an **LLM engine** and its output is normalized deterministically into a `layoutType: 4` JSON source file.

Two engines are supported, sharing the same pipeline (`Extractor` + `Lt4Builder` + corrective pass):

- **`devin`** (default): shells out to the Devin CLI — each generation is a fresh `devin -p` non-interactive session (default model `swe-2-high`). Requires `devin` on PATH and `devin auth login` once. Scanned PDFs are handled by writing the rendered page PNGs into the session working dir for the agent to read.
- **`ollama`**: a locally-running Ollama server (default `gemma4:e4b`, vision-capable); scanned PDFs are submitted as base64 images to the configured vision model.

The generated files land in `crawler/data/results.new/<season_id>/<date>-<name>-lt4.json` — the same folder scanned by the phased data-import wizard — so opening them prefills **Phase 1** (meeting, sessions, pool, city) and **Phase 4** (event program). The operator reviews and corrects the data before any import; manifest-derived files contain **no results** and are not meant to be committed end-to-end.

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

Each PDF is processed independently; failures are reported at the end and do not abort the batch. Existing `-lt4.json` outputs are skipped unless `force=1`.

Processed manifests are then archived: the source `.pdf` and its extracted `.txt` sibling are moved from `crawler/data/manifests/<season_id>/` to `crawler/data/manifests.done/<season_id>/` (the same lifecycle used by `results.new` → `results.done`). This applies to files extracted during the run as well as files skipped because their `-lt4.json` output already existed; only failed extractions keep their sources in place for a retry.

The task aborts early when the selected engine is not available (Devin CLI not installed/logged in, Ollama not reachable) **or** the configured model is not usable — the warning names the engine, the fix hint and the available models.

## UI-triggered extraction (`PdfManifests::BatchRunner`)

The same batch can also be launched from the web UI: the meeting-selection page (`/pull/calendar_meetings?file_path=…`, reachable from the checkbox icon on calendar CSVs in `/pull/calendar_files`) shows an "Extract manifests" button when `crawler/data/manifests/<season>/` holds pending PDFs, and posts to `POST /pull/extract_manifests`.

`PullController#extract_manifests` runs `PdfManifests::BatchRunner` inside a Puma thread (fire-and-forget, like the crawler API) after the same preflight checks as the rake task (`client.available?`, `model_available?`, non-empty pdf list). The page offers an engine select (`devin`|`ollama`) posted as the `engine` param; `MANIFEST_ENGINE` provides the default. `BatchRunner.archive` — shared with `manifests:extract` — performs the `.pdf` + `.txt` move to `manifests.done`.

Progress is persisted to `crawler/data/manifests-extract-status.json` (gitignored) and polled by the page through `GET /pull/extraction_status` (`manifest_extraction_controller.js`, 3s interval); when the run finishes, the page reloads so the per-meeting manifest ticks flip to "extracted". `BatchRunner.running?` combines a process-local flag with a 10-minute staleness window on the status heartbeat, so a killed run doesn't lock the button forever. Note that `rake manifests:extract` does **not** write the status file: avoid launching the rake task and a UI batch on the same season at the same time. A batch aborted by an unexpected error is reported on the status line (`status: 'ERROR'`).

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
- `_meta`: provenance (model, source PDF, timestamp, warnings)

`Phase1Solver` prefers `venueName`/`venueAddress` over `place`, carries `edition`/`maxIndividualEvents` into the phase-1 payload and builds one session per `manifestSessions` entry.
