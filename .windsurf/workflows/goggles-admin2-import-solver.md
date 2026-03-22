---
description: Extend or debug the Import MacroSolver/MacroCommitter pipeline — entity resolution, commit order, SQL generation
auto_execution_mode: 2
---

# Import Solver & Committer

Use this skill when extending, debugging, or understanding the `Import::MacroSolver` and `Import::MacroCommitter` classes in `goggles_admin2`.

## Architecture

All import strategy files live in `/home/steve/Projects/goggles_admin2/app/strategies/import/`:

```text
import/
├── adapters/           # Data format adapters (normalize input)
├── committers/         # Per-entity commit logic (if split out)
├── solvers/            # Per-entity solver logic
├── verification/       # Post-commit verification checks
├── category_computer.rb   # Resolves CategoryType from age + gender
├── diff_calculator.rb     # Calculates diffs between solver runs
├── entity.rb              # Import::Entity wrapper (row + bindings)
├── macro_committer.rb     # Orchestrates commit in dependency order
├── macro_solver.rb        # Orchestrates entity resolution
├── phase5_populator.rb    # Phase 5 data population
└── phase_commit_logger.rb # Logging for commit phases
```

## Import::Entity Wrapper

`Import::Entity` (`entity.rb`) wraps a model row that may or may not exist in the DB yet:

- Stores the ActiveRecord model instance (possibly unsaved)
- Stores a `bindings` hash: foreign key name → string key of the related entity
- Bindings are resolved during commit by looking up the cached instance

Example:

```ruby
entity = Import::Entity.new(
  row: GogglesDb::SwimmingPool.new(name: 'Piscina Comunale', ...),
  bindings: { 'city' => 'BOLOGNA' }
)
```

## MacroSolver — Entity Resolution

`Import::MacroSolver` (`macro_solver.rb`, ~2700 lines):

### Constructor

```ruby
solver = Import::MacroSolver.new(
  season_id: 242,
  data_hash: JSON.parse(file_contents),
  toggle_debug: true  # or 2 for STDOUT output of DB searches
)
```

### What It Does

1. Reads the L2 JSON hash (`data_hash` with `layoutType: 2`)
2. For each entity type, searches the DB for a matching row
3. If not found, creates a local (unsaved) row wrapped in `Import::Entity`
4. Stores everything in `solver.data` keyed by entity type and string key

### Key Data Structure (`solver.data`)

```ruby
{
  'layoutType' => 2,
  'name' => 'Meeting description',
  'meeting' => <Import::Entity or GogglesDb::Meeting>,
  'city' => {
    'BOLOGNA' => <Import::Entity wrapping GogglesDb::City>,
    'ROMA' => <Import::Entity wrapping GogglesDb::City>
  },
  'swimming_pool' => { 'pool key' => <Import::Entity> },
  'meeting_session' => [<Import::Entity>, ...],  # Array, indexed by session order
  'team' => { 'team key' => <Import::Entity> },
  'team_affiliation' => { 'team key' => <Import::Entity> },
  'swimmer' => { 'swimmer key' => <Import::Entity> },
  'badge' => { 'badge key' => <Import::Entity> },
  'meeting_event' => { 'event key' => <Import::Entity> },
  'meeting_program' => { 'program key' => <Import::Entity> },
  'meeting_individual_result' => { 'result key' => <Import::Entity> },
  'meeting_relay_result' => { 'relay key' => <Import::Entity> },
  'lap' => { 'lap key' => <Import::Entity> },
  'meeting_relay_swimmer' => { 'mrs key' => <Import::Entity> },
  'sections' => [...]  # Original parsed sections (cleared by committer)
}
```

### Accessing Cached Instances

```ruby
# Get the resolved model instance:
solver.cached_instance_of('swimmer', 'ROSSI MARIO')
# => GogglesDb::Swimmer (found from DB or newly built)

# Get the bindings hash:
solver.cached_instance_of('swimmer', 'ROSSI MARIO', 'bindings')
# => { 'gender_type' => '1' }
```

## MacroCommitter — Commit + SQL

`Import::MacroCommitter` (`macro_committer.rb`, ~870 lines):

### Constructor

```ruby
committer = Import::MacroCommitter.new(solver: solver)
```

### Commit Order (strict dependency chain)

The `commit_all` method processes entities in this exact order to satisfy foreign key constraints:

1. `commit_meeting` — Meeting row (must exist before everything else)
2. `check_and_commit_calendar` — Calendar row (needs meeting_id)
3. `commit_cities` — City rows (independent, but needed by pools)
4. `commit_pools` — SwimmingPool rows (needs city_id)
5. `commit_sessions` — MeetingSession rows (needs meeting_id + swimming_pool_id)
6. `commit_teams_and_affiliations` — Team rows, then TeamAffiliation rows (needs team_id + season_id)
7. `commit_swimmers_and_badges` — Swimmer rows, then Badge rows (needs swimmer_id + team_id + season_id)
8. `commit_events` — MeetingEvent rows (needs meeting_session_id + event_type_id)
9. `commit_programs` — MeetingProgram rows (needs meeting_event_id + category_type_id + gender_type_id)
10. `commit_ind_results` — MeetingIndividualResult rows (needs meeting_program_id + swimmer_id + team_id)
    - `commit_laps` — Lap rows (needs meeting_individual_result_id)
11. `commit_rel_results` — MeetingRelayResult rows (needs meeting_program_id + team_id)
    - `commit_relay_swimmers` — MeetingRelaySwimmer rows
    - `commit_relay_laps` — RelayLap rows
12. `commit_team_scores` — Team score aggregation

### Key Method: `commit_and_log`

For each entity, the committer:

1. Calls `difference_with_db(model_row)` to get changed attributes
2. If row has an ID → UPDATE only changed columns
3. If row has no ID → INSERT with all non-nil attributes
4. Generates SQL via `SqlMaker` and appends to `@sql_log`
5. Returns the committed (persisted) model row

### Key Method: `difference_with_db`

```ruby
# For new rows (no ID): returns all non-nil attributes (minus timestamps)
# For existing rows: returns only attributes that differ from DB
MacroCommitter.difference_with_db(model_row, db_row = nil)
```

### Binding Resolution Pattern

Each commit method follows this pattern:

```ruby
model_row = @solver.cached_instance_of('entity_type', entity_key)
bindings_hash = @solver.cached_instance_of('entity_type', entity_key, 'bindings')

bindings_hash.each do |binding_model_name, binding_key|
  update_method = "#{binding_model_name}_id="
  next unless model_row.respond_to?(update_method)
  binding_row = @solver.cached_instance_of(binding_model_name, binding_key)
  model_row.send(update_method, binding_row.id)
end
```

## Debugging Tips

### Solver Issues

- **Entity not found**: Check `GogglesDb::DbFinders` — the fuzzy matching may not find the row. Inspect the search parameters.
- **Wrong entity matched**: Fuzzy matching can produce false positives for common names. Check the match threshold.
- **Category not resolved**: Verify `CategoriesCache` has the correct season's `CategoryType` rows.
- **Missing bindings**: Check that all parent entities are resolved before the child entity.

### Committer Issues

- **Foreign key violation**: An entity's binding wasn't resolved before commit. Check the commit order.
- **Duplicate key**: The "re-seek" logic in commit methods (e.g., `GogglesDb::MeetingEvent.where(...)`) may not match. Add more specific WHERE clauses.
- **SQL log empty**: Check that `commit_and_log` is being called and that `difference_with_db` returns non-empty changes.
- **Transaction rollback**: The entire `commit_all` is wrapped in a transaction. Any exception rolls back everything. Check Rails logs.

### Testing

```bash
cd /home/steve/Projects/goggles_admin2
bundle exec rspec spec/strategies/import/macro_solver_spec.rb
bundle exec rspec spec/strategies/import/macro_committer_spec.rb
```

### Console Debugging

```ruby
# Full pipeline test:
season = GogglesDb::Season.find(242)
f = File.read('path/to/result.json')
data_hash = JSON.parse(f)
solver = Import::MacroSolver.new(season_id: season.id, data_hash: data_hash, toggle_debug: 2)
committer = Import::MacroCommitter.new(solver: solver)
committer.commit_all
puts committer.sql_log.join("\n")
```
