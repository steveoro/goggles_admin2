# Meeting Manifest Extraction

The crawler downloads meeting manifests (the *manifesto* PDF with rules, venue info and the event program) into `crawler/data/manifests/<season_id>/manifest-*.pdf`. Manifest layouts vary wildly between organizers, so a regex-based parser is not viable: extraction is delegated to a **locally-running Ollama LLM** and its output is normalized deterministically into a `layoutType: 4` JSON source file.

The generated files land in `crawler/data/results.new/<season_id>/<date>-<name>-lt4.json` — the same folder scanned by the phased data-import wizard — so opening them prefills **Phase 1** (meeting, sessions, pool, city) and **Phase 4** (event program). The operator reviews and corrects the data before any import; manifest-derived files contain **no results** and are not meant to be committed end-to-end.

## Requirements

- `pdftotext` and `pdftoppm` (Poppler suite) on PATH.
- A local [Ollama](https://ollama.com) server (`ollama serve`) with an extraction model pulled. Tested default: `gemma4:e4b` (~7.5B, vision-capable).

Environment configuration:

| Variable                | Default                  | Purpose                                   |
|-------------------------|--------------------------|-------------------------------------------|
| `OLLAMA_API_URL`        | `http://localhost:11434` | Ollama API endpoint                       |
| `OLLAMA_MANIFEST_MODEL` | `gemma4:e4b`             | model used for text extraction            |
| `OLLAMA_VISION_MODEL`   | = `OLLAMA_MANIFEST_MODEL`| model used for scanned/image-only PDFs    |

Ollama request options and pitfalls (context truncation, `think`, `format`,
few-shot prompting) are documented in `docs/pdf_processing/ollama_extraction_notes.md`.

## Usage

```bash
# Extract all manifests of a season (default season: 262)
bundle exec rake manifests:extract season=262

# Single file
bundle exec rake manifests:extract file=crawler/data/manifests/262/manifest-....pdf

# Regenerate already-extracted outputs / override model
bundle exec rake manifests:extract season=262 force=1 model=qwen3.5:4b
```

Each PDF is processed independently; failures are reported at the end and do not abort the batch. Existing `-lt4.json` outputs are skipped unless `force=1`.

## Pipeline

1. **`PdfManifests::TextExtractor`** runs `pdftotext -layout` (reusing the `.txt` sibling when present, which also powers the TXT badge in the file list).
2. If the text layer is missing (scanned PDF) and the configured vision model is installed and advertises the `vision` capability, **`PdfManifests::VisionExtractor`** renders the pages with `pdftoppm` and submits them as images. Otherwise the file is skipped with a warning.
3. **`PdfManifests::ExtractionPrompt`** builds an Italian-language prompt asking for strict JSON: meeting name/edition/dates, venue name/address/city/province, pool length, max individual events, and the event list (distance in meters, stroke code, relay flag, `NxM` relay style, gender, day part, raw label).
4. **`PdfManifests::OllamaClient`** calls `/api/generate` with `format: json` and `think: false`, retrying once on malformed JSON.
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
