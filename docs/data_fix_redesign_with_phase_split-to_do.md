# DataFix redesign with phase split: Plan with TO-DO list

This plan tracks the redesign of the Data-Fix pipeline to reduce memory footprint and improve maintainability by splitting work into per-phase files and per-entity solvers, while keeping a legacy fallback.

## 🚧 Current Status (Updated: 2025-10-06 22:45)

### Phase 1 (Sessions): 100% Complete ✅ 🎉
**Status**: All features, UI, refactoring, and test coverage complete. Production-ready!

**✅ Completed**:
- Phase1Solver with fuzzy matching
- DataFixController actions: review_sessions, update_phase1_meeting, update_phase1_session, add_session, rescan_phase1_sessions, delete_session
- review_sessions_v2.html.haml view (mirrors all legacy functionality)
- AutoCompleteComponent integration for Meeting, SwimmingPool, City
- PhaseFileManager service
- Routes configured
- **Complete RSpec coverage**: 44 tests, all passing ✅
  - 29 controller integration tests (18 new)
  - 15 service unit tests for Phase1NestedParamParser (new)
  - Covers happy paths, error handling, validation, nested data updates
- **Bug fixes**: Form nesting issue (rescan button), nested parameter parsing (pool/city updates)
- **UI improvements**: Meeting name in metadata header, collapsible meeting/session forms, scheduled date in session header, session deletion button
- **Service objects**: Phase1NestedParamParser, Phase1SessionUpdater, Phase1SessionRescanner
- **Controller refactoring**: Reduced update_phase1_session from 129→20 lines, rescan_phase1_sessions from 76→18 lines

**Optional Future Enhancements**:
- End-to-end Cucumber feature test (not blocking deployment)
- Additional service tests for Phase1SessionUpdater/Rescanner (low priority - already covered by integration tests)

**🎯 Next Phase**:
Phase 1 is **complete and production-ready**. Ready to move to Phase 2 (Teams) or Phase 3 (Swimmers).

### Phase 2 (Teams): ~40% Complete 🚧
TeamSolver implemented, controller actions exist, view incomplete.

### Phase 3 (Swimmers): ~40% Complete 🚧
SwimmerSolver implemented, controller actions exist, view incomplete.

### Phase 4 (Events): ~20% Complete 🚧
EventSolver partially implemented.

### Phase 5 (Results): ~10% Complete 🚧
ResultSolver skeleton exists.

---

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
  - [x] 2.1 Finish `Phase1Solver` date/venue extraction and tests
  - [x] 2.2 Implement `/review_sessions` in `DataFixController` to read/write `phase1.json` (renders v2 view)
  - [x] 2.3 Update views to load only Phase 1 payload (no large `data_hash`)
  - [ ] 2.4 UI: Meeting & Sessions editing
    - [x] 2.4.1 Meeting edit form (see legacy `_meeting_form.html.haml` for reference):
      - [x] Fuzzy matches dropdown (pre-populated from solver via Phase1Solver#find_meeting_matches)
      - [x] All required meeting fields: id, description, code, season_id, header_year, header_date, edition, edition_type_id, timing_type_id, cancelled, confirmed, max_individual_events, max_individual_events_per_session
      - [x] Season selector (numeric field)
      - [x] Date picker (header_date field)
      - [x] Coded-name controller integration for auto-generating `code` from `description`
      - [x] Controller updated to handle all new meeting fields
    - [x] 2.4.2 Session edit form for each session (see legacy `_meeting_session_form.html.haml`):
      - [x] Session fields: id, description, session_order, scheduled_date, day_part_type_id
      - [x] Date picker with validation warning icon if blank
      - [x] Nested SwimmingPool form (see legacy `_swimming_pool_form.html.haml`):
        - [x] AutoComplete search by pool `name`
        - [x] Additional dropdown filtered by city_id when city is selected
        - [x] Fields: id, name, nick_name, address, pool_type_id, lanes_number, maps_uri, plus_code, latitude, longitude, city_id
        - [x] Dynamic Google Maps search button (constructs URL from name + address + city)
        - [x] Coded-name controller for nick_name generation
      - [x] Nested City form (see legacy `_pool_city_form.html.haml`):
        - [x] AutoComplete search by city `name` or `area`
        - [x] Fields: id, name, area, zip, country, country_code, latitude, longitude
      - [x] Dynamic session addition (add_session action implemented)
      - [ ] Dynamic session deletion (UI button exists but backend not implemented)
      - [x] Validation constraints and default values
      - [x] Controller updated to handle nested pool/city data (meeting + session + pool + city)
    - [x] 2.4.3 "Rescan sessions from meeting" feature implemented (rescan_phase1_sessions action)
    - [x] 2.4.4 Form submission pattern: split into dedicated actions (update_phase1_meeting, update_phase1_session)
  - [ ] 2.5 Testing Phase 1
    - [x] 2.5.1 Basic request specs for review_sessions (spec/requests/data_fix_controller_phase1_spec.rb)
    - [x] 2.5.2 Test update_phase1_meeting action (basic + full fields + validation)
    - [x] 2.5.3 Test update_phase1_session action (basic + nested pool + nested city + validation)
    - [x] 2.5.4 Test Phase1Solver fuzzy matches integration
    - [ ] 2.5.5 Test rescan_phase1_sessions action (CRITICAL - not yet implemented)
      - [ ] Test with valid meeting_id (should rebuild sessions array)
      - [ ] Test with blank meeting_id (should clear sessions array)
      - [ ] Test with non-existent meeting_id (should clear sessions array)
      - [ ] Test that downstream data is cleared (meeting_event, meeting_program, results, etc.)
    - [ ] 2.5.6 Test add_session action
      - [ ] Test session creation with default values
      - [ ] Test session_order increment
      - [ ] Test nested structure creation (swimming_pool, city)
    - [ ] 2.5.7 End-to-end workflow test (consider Cucumber feature)
      - [ ] Upload file → Phase1 solver builds phase file
      - [ ] Edit meeting → Save → Verify persistence
      - [ ] Add session → Edit session → Save → Verify persistence
      - [ ] Rescan sessions from meeting → Verify sessions rebuilt
      - [ ] Proceed to Phase 2 (verify file_path passes correctly)
  - [ ] 2.6 Refactoring & Cleanup
    - [ ] 2.6.1 Extract rescan logic into service object (RescanSessionsService)
    - [ ] 2.6.2 Extract session creation logic into service object (SessionBuilderService)
    - [ ] 2.6.3 Reduce controller method complexity (AbcSize, MethodLength warnings)
    - [ ] 2.6.4 Consider extracting nested param parsing into concern or helper
    - [ ] 2.6.5 Add YARD documentation for all controller actions
  - [ ] 2.7 Optional Enhancements
    - [ ] 2.7.1 Implement session deletion/purge action for Phase 1 V2
    - [ ] 2.7.2 Add AJAX form submission to avoid full page reloads
    - [ ] 2.7.3 Add client-side validation for date fields
    - [ ] 2.7.4 Improve error messages for validation failures

- [ ] 3. Phase 2 (Teams)
  - [x] 3.1 Implement `TeamSolver` with LT4 team seeding and LT2 fallback
{{ ... }}
  - [ ] 3.2 Implement `/review_teams` in `DataFixController` using `phase2.json`
  - [x] 3.3 Paginate team keys
  - [ ] 3.4 UI: Team editing (see legacy `_team_form.html.haml` for reference)
    - [ ] 3.4.1 Paginated team list with edit form per team
    - [ ] 3.4.2 Fuzzy matches dropdown (pre-populated from solver)
    - [ ] 3.4.3 AutoComplete search component (search by `name`, label shows `editable_name`)
    - [ ] 3.4.4 Team fields: id, name, editable_name, name_variations, city_id
    - [ ] 3.4.5 Nested City AutoComplete (same as Phase 1, search by `name`)
    - [ ] 3.4.6 Mandatory selection: operator MUST select from matches or perform manual search before saving
    - [ ] 3.4.7 Save action per team (or batch save for page)

- [ ] 4. Phase 3 (Swimmers)
  - [x] 4.1 Implement `SwimmerSolver` with LT4 swimmer seeding, badge building
  - [ ] 4.2 Implement `/review_swimmers` in `DataFixController` using `phase3.json`
  - [x] 4.3 Paginate swimmer keys
  - [ ] 4.4 UI: Swimmer editing (see legacy `_swimmer_form.html.haml` for reference)
    - [ ] 4.4.1 Paginated swimmer list with edit form per swimmer
    - [ ] 4.4.2 Fuzzy matches dropdown (pre-populated from solver, displays: "COMPLETE_NAME (GENDER, YOB)")
    - [ ] 4.4.3 AutoComplete search component (search by `complete_name` with secondary filter by `year_of_birth`)
    - [ ] 4.4.4 Swimmer fields: id, complete_name, first_name, last_name, year_of_birth, gender_type_id
    - [ ] 4.4.5 Field validation: names uppercase, year range 1910..current_year
    - [ ] 4.4.6 Mandatory selection: operator MUST select from matches or perform manual search
    - [ ] 4.4.7 Badge creation: implicit, linked to swimmer_id + team_id + season_id
    - [ ] 4.4.8 Save action per swimmer (or batch save for page)

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

- Component tests
  - `AutoCompleteComponent` (existing spec at `spec/components/auto_complete_component_spec.rb`)
    - **Current coverage**: basic parameter rendering, data attribute verification
    - **Missing coverage**: edge cases (API failures, empty results, JWT expiration), multi-target updates, inline vs remote data modes
    - **Recommended additions**:
      - Test with inline payload (no API calls)
      - Test with remote API (mock API responses)
      - Test secondary filtering (search2_column + search2_dom_id)
      - Test multi-target updates (verify all 12 external targets)
      - Test error states (network failures, 401/403 responses)
      - Test cascading lookups (e.g., SwimmingPool → City via city_id)

- Integration tests per phase flow (Phase 1 → Phase 2 → Phase 3, etc.)
  - Test complete workflow: upload → phase1 → phase2 → phase3 → phase4 → phase5 → commit
  - Test editing and re-saving entities within each phase
  - Test pagination in phase 2/3 (teams/swimmers)
  - Test form validation and error messages

- Performance harness measuring memory/time on heavy relay files
  - Benchmark memory usage: legacy (full load) vs new (streaming)
  - Measure file I/O overhead for phase files
  - Profile phase transitions (reading/writing JSON)

## UI/UX Requirements

### General Principles

- **Mandatory selection from matches**: When existing entity matches are found during the initial scanning/solver phase, the operator MUST select from drop-downs before proceeding. This ensures data consistency and prevents duplicate records.
- **Quick database search**: For each entity type, provide a dedicated search mechanism allowing operators to query existing database rows using entity-specific search criteria.
- **Pagination**: Maintain server-side pagination; ensure pagination does not load full dictionaries into memory.
- **Streaming**: Stream subsets (per-section) in events/results to manage memory efficiently.

### Entity-Specific Search Fields

Each entity requires specific search capabilities:

- **Swimmer**: search by `complete_name` (may include secondary filter by `year_of_birth`)
- **Team**: search by `name`
- **Meeting**: search by `description`
- **SwimmingPool**: search by `name` (with optional associated `City` lookup via `city_id`)
- **City**: search by `name`
- **MeetingSession**: linked to sessions array, searchable by date and description
- **MeetingEvent**: searchable by event type label/code

### Component Options

#### Option A: Reuse AutoCompleteComponent (Recommended for Phase 1-3)

**Advantages:**
- Already implemented and tested
- Supports JWT-authenticated API calls
- Multi-tiered search (e.g., pool → city via `city_id`)
- Can update up to 12 target DOM nodes on selection
- Works with Bootstrap modals
- Supports both inline payload and remote API data sources
- Supports secondary filtering (e.g., swimmers by name + year_of_birth)

**Current capabilities:**
- Base entity ID field + search field
- Up to 2 internal target fields (field2, field3)
- Up to 9 external target fields (target4..target12) via DOM IDs
- Automatic detail retrieval via optional detail endpoint
- Description label updates on selection

**Required updates:**
- Enhance specs for edge cases (missing matches, API failures)
- Add integration tests with actual API endpoints
- Consider adding loading/error states to UI

#### Option B: Create New Dedicated Components

**When to consider:**
- If AutoCompleteComponent becomes too complex for maintenance
- If we need significantly different UX patterns
- If we want to move away from jQuery dependency (currently uses EasyAutocomplete)

**If creating new components, maintain these features:**
- JWT authentication support
- Multi-field updates on selection
- Inline and remote data support
- Secondary filter capability
- Clear error states

### Forms and Field Requirements

Based on legacy forms, each phase requires these fields:

#### Phase 1 (Meeting & Sessions)

**Meeting fields** (`_meeting_form.html.haml`):
- `id` (with fuzzy matches dropdown + AutoComplete search)
- `description` (required, main search field)
- `code` (required, auto-generated via coded-name controller)
- `season_id` (required, numeric)
- `header_year` (required, format: "YYYY/YYYY+1")
- `header_date` (required, date picker with warning icon if blank)
- `edition` (required, numeric)
- `edition_type_id` (required, dropdown)
- `timing_type_id` (required, dropdown)
- `cancelled` (checkbox)
- `confirmed` (checkbox, default true)
- `max_individual_events` (required, default: 3)
- `max_individual_events_per_session` (required, default: 3)

**AutoComplete config for Meeting:**
- `search_endpoint`: 'meetings'
- `search_column`: 'description'
- `detail_endpoint`: 'meeting'
- External targets: description, code, season_id, header_year, header_date, edition, edition_type_id, timing_type_id, cancelled, confirmed

**MeetingSession fields** (`_meeting_session_form.html.haml`):
- `id` (meeting_session_id, numeric)
- `description` (required)
- `session_order` (required, numeric)
- `scheduled_date` (required, date picker with warning icon if blank)
- `day_part_type_id` (dropdown)
- References nested SwimmingPool and City forms

**SwimmingPool fields** (`_swimming_pool_form.html.haml`):
- `id` (swimming_pool_id, with existing pools dropdown filtered by city_id)
- `name` (required, main search field)
- `nick_name` (required, coded name via coded-name controller)
- `address`
- `pool_type_id` (dropdown)
- `lanes_number` (numeric)
- `maps_uri` (with dynamic Google Maps search button)
- `plus_code`
- `latitude`
- `longitude`
- `city_id` (linked to City form)

**AutoComplete config for SwimmingPool:**
- `search_endpoint`: 'swimming_pools'
- `search_column`: 'name'
- `detail_endpoint`: 'swimming_pool'
- External targets: name, nick_name, address, pool_type_id, lanes_number, maps_uri, latitude, longitude, plus_code, city_id

**City fields** (`_pool_city_form.html.haml`):
- `id` (city_id)
- `name` (main search field)
- `area`
- `zip`
- `country`
- `country_code`
- `latitude`
- `longitude`

**AutoComplete config for City:**
- `search_endpoint`: 'cities'
- `search_column`: 'name'
- `detail_endpoint`: 'city'
- `label_column`: 'area'
- External targets: name, area, zip, country, country_code, latitude, longitude

#### Phase 2 (Teams)

**Team fields** (`_team_form.html.haml`):
- `id` (with fuzzy matches dropdown + AutoComplete search)
- `name` (required, main search field)
- `editable_name` (required, display name)
- `name_variations` (optional, pipe-separated aliases)
- `city_id` (nested City AutoComplete, see above)

**AutoComplete config for Team:**
- `search_endpoint`: 'teams'
- `search_column`: 'name'
- `detail_endpoint`: 'team'
- `label_column`: 'editable_name'
- External targets: editable_name, city_id, name, name_variations

#### Phase 3 (Swimmers)

**Swimmer fields** (`_swimmer_form.html.haml`):
- `id` (with fuzzy matches dropdown + AutoComplete search)
- `complete_name` (required, computed from first + last)
- `first_name` (required, uppercase)
- `last_name` (required, uppercase)
- `year_of_birth` (required, numeric, range: 1910..current_year)
- `gender_type_id` (dropdown)

**AutoComplete config for Swimmer:**
- `search_endpoint`: 'swimmers'
- `search_column`: 'complete_name'
- `detail_endpoint`: 'swimmer'
- `label_column`: 'complete_name'
- `search2_column`: 'year_of_birth' (secondary filter)
- `search2_dom_id`: year_of_birth field DOM ID
- External targets: gender_type_id, last_name, first_name, complete_name

**Badge fields** (implicit, derived from Swimmer):
- `team_id` (from phase 2)
- `season_id` (from phase 1)
- `swimmer_id` (from current phase)

#### Phase 4 (Events/Programs)

**MeetingEvent fields** (`_event_form.html.haml`):
- `meeting_session_key` (dropdown selector, index into sessions array)
- `event_order` (required, numeric, min: 0)
- `begin_time` (time picker, min: '07:30', step: 15 min)
- `event_type_id` (AutoComplete with inline payload)
- `heat_type_id` (dropdown)

**AutoComplete config for EventType:**
- Uses inline `payload` (not remote API)
- `search_column`: 'label_column'
- `label_column`: 'long_label'
- `base_name`: 'event_type'

**MeetingProgram fields** (implicit):
- Derived from MeetingEvent + category/gender from section data
- `category_type_id`
- `gender_type_id`

#### Phase 5 (Results)

**Read-only summary display**:
- No editing forms required
- Display aggregated statistics
- Show validation warnings (missing links, invalid times, etc.)
- Provide pre-commit checklist

### Additional UI Components Required

1. **Fuzzy matches dropdown**: Pre-populated select element showing solver-found matches, with `onchange` event to copy selected ID to AutoComplete target
2. **Dynamic Google Maps search button**: Constructs search URL from pool name + address + city
3. **Coded-name controller** (existing): Auto-generates standardized codes from descriptive names
4. **Validation indicators**: Warning icons for missing required dates/fields
5. **Confirmation dialogs**: On save actions with i18n messages
6. **Pagination controls**: For team/swimmer review pages

### Form Submission Pattern

All legacy forms use:
```ruby
form_for(entity, url: data_fix_update_path(entity, model: '<model_name>'), method: :patch)
```

With hidden fields:
- `key`: entity key in data hash (for retrieval)
- `dom_valid_key`: sanitized key for DOM IDs (underscores replace special chars)
- `file_path`: path to JSON file being processed

**TODO for new implementation:**
- Decide if we keep single `PATCH /data_fix/update` action or split into per-phase dedicated actions
- Current single action is "convoluted unmaintainable mess" per refactoring doc
- Recommend: dedicated actions per phase (e.g., `PATCH /data_fix/update_team`, `PATCH /data_fix/update_swimmer`)

## Risks and Mitigations

- Binding coherence across files
  - Use stable keys and persist DB IDs when resolved
  - Dependency metadata with checksums on phase files
- Mixed LT2/LT4 inputs
  - Solver accepts both; prefer LT4 seeds when present
- Operator workload on Phase 1 for LT4
  - Keep forms ergonomic; provide sensible defaults from header/filename

## Component Reuse Decision

### Recommendation: **Reuse AutoCompleteComponent for Phases 1-3**

**Rationale:**

1. **Proven implementation**: Already handles complex scenarios (multi-target updates, JWT auth, cascading lookups)
2. **Comprehensive feature set**: Supports all required use cases (inline/remote data, secondary filtering, 12 external targets)
3. **Legacy compatibility**: Current legacy forms already use it extensively
4. **Time efficiency**: Avoids reimplementing complex functionality
5. **Risk reduction**: Well-tested component vs new untested code

**Action items:**

- Enhance existing specs (`spec/components/auto_complete_component_spec.rb`) with edge cases
- Add integration tests with mocked API responses
- Consider UI improvements (loading states, error messages)
- Document component usage patterns for new developers

**When to reconsider:**

- If jQuery dependency becomes a blocker (framework migration)
- If AutoCompleteComponent complexity becomes unmaintainable
- If significant UX changes require different interaction patterns

### Form Reuse Decision

**Recommendation: Reuse legacy form partials as starting point, refactor incrementally**

**Approach:**

1. Copy legacy form partials to new phase-specific views
2. Remove unnecessary data_hash dependencies
3. Adapt to phase file structure (phase1.json, phase2.json, etc.)
4. Keep AutoCompleteComponent integration intact
5. Refactor progressively based on testing feedback

**Benefits:**

- Faster initial implementation
- Proven field layouts and validation patterns
- Maintains operator familiarity
- Reduces risk of missing critical fields

## Decision Log

- 2025-10-06 22:50: **Service Tests Added**: Created 15 comprehensive unit tests for Phase1NestedParamParser covering mixed params, edge cases, security filtering, and real-world AutoComplete scenarios. Fast tests (0.5s) with high value for documenting complex parameter parsing logic. Decided not to test Phase1SessionUpdater/Rescanner as service objects since they're already well-covered by integration tests. Total test count: 44 passing.
- 2025-10-06 22:45: **Test Coverage Complete**: Added 18 new RSpec tests for add_session, delete_session, and rescan_phase1_sessions actions. All 29 controller tests passing. Phase 1 is now 100% complete and production-ready!
- 2025-10-06 22:00: **Controller Refactoring Complete**: Extracted three service objects (Phase1NestedParamParser, Phase1SessionUpdater, Phase1SessionRescanner) to reduce controller complexity. Reduced update_phase1_session from 129→20 lines (~84% reduction), rescan_phase1_sessions from 76→18 lines (~76% reduction). All RuboCop complexity warnings resolved. Phase 1 now at ~98% complete.
- 2025-10-06 21:30: **Session Deletion Implemented**: Added delete_session controller action, route, and UI button. Session headers now show scheduled date alongside description for better identification. Deletion clears downstream phase data correctly.
- 2025-10-06 20:30: **UI Improvements**: Added collapsible sections for meeting and session forms. Added meeting name to Phase Metadata header for easier identification. Both improvements requested by operator feedback. Phase 1 now at ~95% complete.
- 2025-10-06 19:56: **BUG FIX: Nested Parameter Parsing**: Fixed critical bug where session pool/city updates weren't being saved. Root cause was mixed parameter structure from AutoComplete (indexed nested params) + form fields (top-level params). Controller now merges both structures correctly.
- 2025-10-06 19:22: **BUG FIX: Form Nesting Issue**: Fixed critical bug where "Rescan sessions from meeting" button was submitting the wrong form due to invalid HTML (nested forms). Moved rescan form outside meeting form in review_sessions_v2.html.haml. Bug prevented rescan feature from working at all.
- 2025-10-06 17:00: **Phase 1 Status Review**: Implementation ~90% complete. All core features working (meeting edit, session edit, add session, rescan sessions). Missing: test coverage for rescan_phase1_sessions and add_session actions, session deletion feature. Recommendation: Complete critical tests before marking Phase 1 as done.
- 2025-10-06 17:00: **Test Gaps Identified**: No tests for rescan_phase1_sessions (critical), add_session, or end-to-end workflow. Added detailed test requirements to section 2.5.
- 2025-10-06 17:00: **Refactoring Needs**: Controller methods have AbcSize/MethodLength warnings. Recommend extracting service objects (RescanSessionsService, SessionBuilderService) after tests pass.
- 2025-09-30: Documented detailed UI/UX requirements based on legacy forms analysis
- 2025-09-30: Recommended reusing AutoCompleteComponent for Phases 1-3
- 2025-09-15: Proceed with separate new controller (`DataFixController`), keep legacy controller as fallback
- 2025-09-15: Action-level flags preferred over env flags to enable UI buttons