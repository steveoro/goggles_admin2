# Data-Fix: layoutType 4 (Microplus) Support

Last updated: 2025-09-15 22:26 (local)

## Status: complete (on legacy controller)

- Support into Data-Fix for layoutType 4 (Microplus) is complete into the original data-fix controller, currently renamed `DataFixLegacyController`.
- The legacy controller uses the `Import::MacroSolver` to solve the entities and map them into the JSON data file assuming the LT2-like schema.
- A new adapter `Import::Adapters::Layout4To2` is being successfully used to normalize the LT4 JSON into the canonical LT2-like schema.
- However, result files normalized from LT4 are memory huge and need to be processed 1 or 2 MeetingEvents at a time tops (not feasible for meetings with 15+ events like the national championships).
- A new controller `DataFixController` is being implemented to handle the new multi-stage process which should solve this issue.

## Inputs / Samples

- Relay-only examples:
  - `crawler/data/results.new/<season_id>/2025-06-24-...-4X50MI-l4.json`
  - `crawler/data/results.new/<season_id>/2025-06-24-...-4X50SL-l4.json`
- Individual results with laps:
  - `crawler/data/results.new/<season_id>/2025-06-24-...-800SL-l4.json`
  - `crawler/data/results.new/<season_id>/2025-06-24-...-200RA-l4.json`
- Crawler notes: `crawler/README.md`

## Canonical Internal Schema (LT2-like)

The canonical schema is the one described in `docs/data_fix_refactoring_and_enhancement.md` and used by `Import::MacroSolver`:

- Header keys (example): `name`, `meetingURL`, `manifestURL?`, `dateDay1`, `dateMonth1`, `dateYear1`, `dateDay2?`, `dateMonth2?`, `dateYear2?`, `venue1`, `address1`, `venue2?`, `address2?`, `poolLength`, `sections`.
- Sections array: one per event/category/gender tuple with fields like `title`, `fin_sesso`, `fin_sigla_categoria`, `rows`.
- Individual row (example): `name`, `year`, `sex`, `team`, `timing`, `score?`, optional badge parts.
- Relay row: `relay: true`, plus `swimmer1..N`, `year_of_birth{1..N}`, `gender_type{1..N}` (if present by source), `team`, `timing`.
- Optional blocks indicated in the doc (rankings/stats). Laps: stored/derived so that solver can emit `lap` / `relay_lap` entities.

## High-level Field Mapping (LT4 -> canonical)

- Meeting header:
  - LT4 `meetingName` -> canonical `name`.
  - LT4 `meetingURL` -> canonical `meetingURL`.
  - LT4 `dates` (CSV `YYYY-MM-DD,YYYY-MM-DD`) -> canonical `dateDay1/Month1/Year1` (and `dateDay2/Month2/Year2` if present).
  - LT4 `place` -> used to infer `address1`/`venue1` when appropriate (fallbacks if not provided by LT4).
  - LT4 `seasonId` -> path-derived `season_id` already; controller still extracts from path for consistency.
  - LT4 likely lacks `poolLength` and detailed venue addresses; set from known context if available, else leave blank to be filled in #review_sessions.

- Sections and metadata:
  - LT4 event descriptors (from file name or internal event blocks) -> canonical `sections[].title`.
  - Gender -> canonical `fin_sesso`.
  - Category -> canonical `fin_sigla_categoria`.

- Rows (individual):
  - LT4 swimmer blocks and event result rows -> canonical row with `name` ("LAST FIRST"), `year`, `sex`, `team`, `timing`, `score?`.
  - Laps: map to a per-row `laps` structure so that `MacroSolver#process_mir_and_laps` can build `lap` entities.

- Rows (relay):
  - LT4 team relay result row -> canonical row with `relay: true`, `team`, `timing`, and swimmers expanded across `swimmer1..N`, `year_of_birth{1..N}`, `gender_type{1..N}`.
  - Relay laps: attach per-leg laps arrays so `MacroSolver#process_mrr_and_mrs` can build `relay_lap` & `meeting_relay_swimmer` entities.

- Rankings:
  - LT4 team rankings (if present) -> canonical `sections[]` with `ranking: true` and normalized rows compatible with `process_team_score`.

## Mapping rules (from LT4 clarifications)

- Root dictionaries:
  - `swimmers` is a root-level dictionary keyed by a composite string (e.g., `F|LAST|FIRST|YYYY|TEAM`).
    - Individual results always reference swimmers via this key.
    - In relays, swimmer keys may sometimes lack gender when the run was focused only on relays (gender unknown at crawl time). The adapter should be tolerant: leave `gender_type{N}` blank when not inferable.
  - `teams` may be present and redundant (key same as value) but is future-proof for team enrichment. We will keep using the team string from the result row.

- Events container:
  - LT4 groups processed events in a large `events` array; each element is an event object with structure:
    - `eventCode`, `eventGender`, `eventLength`, `eventStroke`, `eventDescription`, `relay` (boolean), `results` (array)
  - There is no per-event key; we iterate the array in order.

- Results and laps:
  - Each event’s `results[]` contains one object per result.
  - Individual results include: `ranking`, `swimmer` (composite key), `team`, `timing`, `category`, and `laps` (array; may be empty, e.g., 50m events).
  - Relay results include `relay: true` at event level; relay legs and their laps are provided in `laps` and include a `swimmer` key per lap. The adapter must collect unique leg swimmer keys in order of first appearance to populate `swimmer1..N`, `year_of_birth{N}`, `gender_type{N}` (when available).
  - Laps are nested per result (both individual and relay), so the adapter should attach a `laps` array into each canonical row for MacroSolver to generate `lap` / `relay_lap` entities.

- Categories:
  - LT4 does not split sections by category; instead each result row contains a `category` code (e.g., `M25`).
  - The adapter should pass `category` through (e.g., as `fin_sigla_categoria` on rows) so MacroSolver can derive `meeting_program` keys correctly.

- Gender handling:
  - For individual results, gender can be read from the swimmer key prefix (`F|`, `M|`).
  - For relays, `eventGender` can be `F`, `M` or `X` (mixed). Per-leg unknown-gender swimmer keys are allowed; the MacroSolver logic is already robust to missing swimmer gender and may infer from context when needed.

## Normalization Steps

1. Adapter
   - File: `app/strategies/import/adapters/layout4_to2.rb`
   - Module: `Import::Adapters::Layout4To2`
   - API: `def self.normalize(data_hash:) -> Hash`

2. Header normalization
   - Parse `dates` into `dateDay1/Month1/Year1` and optional day 2.
   - Map `meetingName` -> `name`, `meetingURL` passthrough.
   - Leave `poolLength`, `venue1`, `address1` blank if unknown (editable in Step 1).

3. Sections builder
   - Detect and emit one canonical `sections[]` entry per event/category/gender.
   - Create `title`, set `fin_sesso`, `fin_sigla_categoria` when derivable.

4. Row mappers
   - Individual rows: produce canonical fields and attach laps array (even if empty for 50m events).
   - Relay rows: set `relay: true`, expand swimmers into `swimmer1..N`, `year_of_birth{1..N}`, `gender_type{1..N}`; attach relay laps per leg if present.

5. Rankings and stats
   - If LT4 contains team rankings, add a `sections[]` with `ranking: true` and normalized rows.
   - Ignore stats for DB storage (consistent with current solver).

6. Controller
   - In `DataFixController#parse_file_contents` (or immediately after JSON load), if `layoutType == 4`, call adapter, then set `layoutType: 2` on the normalized copy before passing to `Import::MacroSolver`.
   - Add optional feature flag to bypass adapter for debugging (e.g., `params[:raw_lt4]`).

## Testing

- Implemented unit specs for the adapter:
  - `spec/strategies/import/adapters/layout4_to2_spec.rb`
  - Covers:
    - Individual events: inline `lapXX`/`deltaXX` keys + laps array preserved
    - Relays: inline `lapXX`/`deltaXX` keys + swimmers and laps preserved
    - Relay category normalization (U80→60-79, M80→80-99, M100→100-119, M120→120-159, M160→160-199, …)

How to run:

```bash
bundle exec rspec spec/strategies/import/adapters/layout4_to2_spec.rb -f doc
```

## Running notes

- Storage paths remain unchanged: Data-Fix reads from `crawler/data/results.new/<season_id>/<date>-<meeting>.json` and moves to `crawler/data/results.done/...` after commit.
- We will preserve original files on disk; the controller will write back the canonical form when saving changes.
