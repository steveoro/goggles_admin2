# DataFix redesign with phase split: Plan with TO-DO list

This plan tracks the redesign of the Data-Fix pipeline to reduce memory footprint and improve maintainability by splitting work into per-phase files and per-entity solvers, while keeping a legacy fallback.

## Goals

- Reduce memory/time usage for large result files (notably heavy relay events)
- Improve debuggability and testability via smaller, focused solvers
- Maintain operability with a legacy fallback during rollout
- Support both LT2 and LT4 input flows

## Architecture Summary

- Keep `DataFixLegacyController` as fallback (complete, current behavior)
- Introduce new `DataFixController` progressively
- Use per-phase JSON files written via `PhaseFileManager`
- Split `MacroSolver` responsibilities into smaller solvers (Team, Swimmer, EventProgram, Results)
- Adopt stable binding keys across phases; add DB IDs as they are discovered
- Each solver must be able to run in isolation and generate a valid payload from an original source LT2/LT4 json file
- Each solver must collect all entities it needs to resolve and store them in the phase file; to "solve" an entity, it must have all its dependencies resolved either by database lookup or by previous phase files or manual editing in the UI
- Each phase will analyze the original source file and generate a payload that can be used to build the database; this payload will be stored in a per-phase file and will be used at the end of all phases to generate a single-transaction SQL file that can be sent to the remote server via the existing PushController.
- For example, the TeamSolver will:
  - gather a list of all teams found in the source file
  - resolve each team name to a database ID or prepare (store) the attributes needed to create a new team, including the actual team ID only when a match is found
  - store the attributes for the destination entity (Team) inside the phase file itself

## Routing and Feature Flags

- Keep current routes pointing to `DataFixController`
- `DataFixController` will dispatch per-action using params (feature buttons in UI)
  - `?phase_v2=1` (generic enable)
  - Optional finer-grained toggles per action, e.g. `?phase2_v2=1`
- `DataFixLegacyController` remains reachable (temporary route or dev-only param)

## Phase Files

- File naming: `<original-file>-phaseN.json`
- File shape:
  - `_meta`: schema_version, created_at, generator, source_path, parent_checksum, dependencies
  - `data`: phase payload only
- Manager: `app/services/phase_file_manager.rb` (exists)

## Phase Breakdown and Solvers

1) Phase 1: Sessions (Step 1 UI)
   - Entities: Season, Meeting, MeetingSession (>=1), SwimmingPool (per session), City (optional)
   - Solver: `Import::Solvers::Phase1Solver` (exists)
   - Inputs: LT2 header preferred; LT4 header + operator-fed fields
   - Output: `phase1.json` with minimal session/pool/city payload

2) Phase 2: Teams (Step 2 UI)
   - Entities: Team, TeamAffiliation (per season)
   - Solver: `TeamSolver`
   - Inputs: prefer LT4 `teams` dictionary; fallback to LT2 scan if absent
   - Output: `phase2.json` (team dict + matches + optional pre-resolved IDs)
   - UI: review and resolve team matches (paged)

3) Phase 3: Swimmers (Step 3 UI)
   - Entities: Swimmer, Badge (per season/team)
   - Solver: `SwimmerSolver`
   - Inputs: prefer LT4 `swimmers` dict; fallback to LT2 scan
   - Output: `phase3.json` (swimmer/badge dict + matches + IDs if any)
   - UI: review and resolve swimmer matches (paged)

4) Phase 4: Events/Programs (Step 4 UI)
   - Entities: MeetingEvent, MeetingProgram
   - Solver: `EventProgramSolver`
   - Inputs: section-wise LT2 data or adapter-normalized LT4; consider a per-section index
   - Output: `phase4.json` (event/program dict + section index)
   - UI: event/program editing (add/update)

5) Phase 5: Results (Step 5 UI)
   - Entities: MIR, MRR, Lap, RelayLap, MeetingRelaySwimmer, MeetingTeamScore
   - Solver: `ResultsSolver`
   - Inputs: per-section streaming (avoid loading all rows)
   - Output: `phase5.json` (result slices with references, minimal duplication)
   - UI: summary display, pre-commit checks

## Binding Keys and IDs

- Stable keys across phases:
  - Team: team name (string)
  - Swimmer: `LAST|FIRST|YOB` (string)
  - Badge: `SWIMMER_KEY|TEAM_KEY|SEASON_ID`
  - Event/Program: `event_code|gender|category_code`
  - Results: existing LT2/LT4-derived keys remain
- DB IDs stored when resolved and carried forward in phase files

## Data Flows

- Prefer LT4 seeding for teams/swimmers when present; otherwise, LT2 scan
- After completing Phase 2/3, do not carry LT4 dictionaries further
- Stream results in Phase 5; inline `lapXX/deltaXX` already supported by adapter

## Step-by-step Implementation Plan (Checklist)

- [ ] 0. RFC doc and decision log (link in this file)
- [x] 1. Routing/Controller groundwork
  - [x] 1.1 Ensure `DataFixLegacyController` exists (done)
  - [x] 1.2 Create `DataFixController` (skeleton and phased dispatch implemented)
  - [x] 1.3 Add action-level param flags (e.g., `phase_v2`, `phase2_v2`, `phase3_v2`)

- [ ] 2. Phase 1
  - [ ] 2.1 Finish `Phase1Solver` date/venue extraction and tests
  - [x] 2.2 Implement `/review_sessions` in `DataFixController` to read/write `phase1.json` (renders v2 view)
  - [x] 2.3 Update views to load only Phase 1 payload (no large `data_hash`)
  - [ ] 2.4 UI: phase 1 must allow user to edit both the meeting details and all session matches, change the meeting or session details (not the keys for the data_hash) or add new sessions;
    - [ ] 2.4.1 the meeting edit form must include:
      - a dropdown list of the existing meetings matches found, that allows to overwrite all meeting details when selecting an item (including the meeting ID - if an ID remains nil it implies a new record)
      - a season selector
      - all meeting details (date, name)
    - [ ] 2.4.2 the session edit form must be available for any listed session and must include:
      - a dropdown list of the existing sessions matches found, that allows to overwrite all session details when selecting an item (including the meeting session ID)
      - a date picker for editing the session date
      - all venue and pool details for the session
      - all city details for the session

- [ ] 3. Phase 2
  - [x] 3.1 Implement `TeamSolver` with LT4 team seeding and LT2 fallback
  - [ ] 3.2 Implement `/review_teams` in `DataFixController` using `phase2.json`
  - [x] 3.3 Paginate team keys
  - [ ] 3.4 UI: allow user to edit team matches, change the team name (not the key) or add new teams; the team edit form must be available for any listed team and must include a search box for manual search, that allows to overwrite team details with the search results (including the team ID)

- [ ] 4. Phase 3
  - [x] 4.1 Implement `SwimmerSolver` with LT4 swimmer seeding, badge building
  - [ ] 4.2 Implement `/review_swimmers` in `DataFixController` using `phase3.json`
  - [x] 4.3 Paginate swimmer keys
  - [ ] 4.4 UI: allow user to edit swimmer matches, change the swimmer name (not the key) or add new swimmers; the swimmer edit form must be available for any listed swimmer and must include a search box for manual search, that allows to overwrite swimmer details with the search results (including the swimmer ID)

- [ ] 5. Phase 4
  - [ ] 5.1 Implement `EventProgramSolver` with per-section index
  - [ ] 5.2 Implement `/review_events` in `DataFixController` using `phase4.json`

- [ ] 6. Phase 5
  - [ ] 6.1 Implement `ResultsSolver` with streaming builds (batch flush to disk)
  - [ ] 6.2 Implement `/review_results` in `DataFixController` using `phase5.json`

- [ ] 7. Commit pipeline
  - [ ] 7.1 Adapt phase files to existing MacroCommitter or design a new strategy class that can consume all phase files into a single-transaction SQL file (that can be sent to the remote server via the existing PushController)
  - [ ] 7.2 Do NOT consume phase files directly, instead move all "committed" files to the designated directory `crawler/data/results.done/<season_id>/`. This is the same folder used by the PushController for the "already processed and sent" files and acts as a backup for both the phase/json and sql files.

## Testing

- Unit tests per solver (minimal fixtures)
  - `Phase1Solver`: header parsing, date mapping (LT4 `dates` CSV)
  - `TeamSolver`: LT4 team seeding vs LT2 scan (added)
  - `SwimmerSolver`: LT4 swimmer seeding vs LT2 scan, badge inference (added)
  - `SwimmerSolver`: LT4 swimmer seeding vs LT2 scan, badge composition
  - `EventProgramSolver`: section index, category/gender mapping
  - `ResultsSolver`: MIR/MRR/laps mapping (including relay lap inline keys fidelity)
- Integration tests per phase flow (Phase 1 → Phase 2 → Phase 3, etc.)
- Performance harness measuring memory/time on heavy relay files

## UI/UX

- Add feature buttons to trigger v2 flows per step (action params)
- Maintain pagination; ensure server-side pagination does not load full dicts
- Stream subsets (per-section) in events/results

## Risks and Mitigations

- Binding coherence across files
  - Use stable keys and persist DB IDs when resolved
  - Dependency metadata with checksums on phase files
- Mixed LT2/LT4 inputs
  - Solver accepts both; prefer LT4 seeds when present
- Operator workload on Phase 1 for LT4
  - Keep forms ergonomic; provide sensible defaults from header/filename

## Decision Log

- 2025-09-15: proceed with separate new controller (`DataFixController`), keep legacy controller as fallback
- Action-level flags preferred over env flags to enable UI buttons