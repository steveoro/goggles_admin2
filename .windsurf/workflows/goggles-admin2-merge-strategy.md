---
description: Add or debug a merge strategy (badge, swimmer, team, meeting) in goggles_admin2 — checker + executor pattern, SQL generation, duplicate resolution
auto_execution_mode: 2
---

# Merge Strategy

Use this skill when adding or debugging a merge strategy in `goggles_admin2`. Merges resolve duplicate entities by moving all data from a source row into a destination row, then removing the source.

## Background

- Merge strategies live in `/home/steve/Projects/goggles_admin2/app/strategies/merge/`
- Each entity type has a **Checker** (feasibility analysis) and an **Executor** (SQL generation)
- Merges produce SQL scripts — they do NOT directly modify the DB
- The SQL is then sent to the remote server via `ApiProxy`

## Existing Merge Strategies

| Entity | Checker | Executor | Complexity |
| --- | --- | --- | --- |
| Swimmer | `SwimmerChecker` | `Swimmer` | High (badges, results, laps, relay swimmers) |
| Team | `TeamChecker` | `Team` | High (affiliations, badges, results) |
| Badge | `BadgeChecker` | `Badge` | Medium (results, laps linked to badge) |
| Meeting | `MeetingChecker` | `Meeting` | High (sessions, events, programs, all results) |

Additional helpers:

- `BadgeSeasonChecker` — checks badge conflicts within a season
- `DuplicateResultCleaner` — removes exact duplicate result rows
- `TeamInBadge` — merges team references within badges
- `TeamInMeeting` — merges team references within a meeting context

## The Checker + Executor Pattern

### Checker (`<Entity>Checker`)

Analyzes whether two rows can be safely merged:

```ruby
module Merge
  class <Entity>Checker
    attr_reader :log, :errors, :warnings, :source, :dest,
                :src_only_<sub_entities>, :shared_<sub_entities>

    def initialize(source:, dest:)
      raise(ArgumentError, '...') unless valid_types?(source, dest)
      @source = source
      @dest = dest
      @log = []
      @errors = []
      @warnings = []
    end

    # Runs the full feasibility check.
    # Returns true if merge is feasible, false otherwise.
    def run
      collect_sub_entities
      check_for_conflicts
      @errors.empty?
    end

    def display_report
      @log.each { |line| Rails.logger.debug(line) }
    end

    private

    def collect_sub_entities
      # Partition sub-entities into:
      # - src_only: exist only in source (safe to move)
      # - shared: exist in both (potential conflicts)
    end

    def check_for_conflicts
      # Add to @errors if conflicts are unresolvable
      # Add to @warnings if conflicts can be forced
    end
  end
end
```

### Executor (`Merge::<Entity>`)

Generates the SQL merge script:

```ruby
module Merge
  class <Entity>
    attr_reader :sql_log, :checker, :source, :dest

    def initialize(source:, dest:, skip_columns: false, force: false)
      @checker = <Entity>Checker.new(source: source, dest: dest)
      @source = @checker.source
      @dest = @checker.dest
      @skip_columns = skip_columns
      @force = force
      @sql_log = []
    end

    # Prepares the merge SQL script.
    def prepare
      result_ok = @checker.run
      return unless result_ok || @force

      @sql_log << 'SET AUTOCOMMIT = 0;'
      @sql_log << 'START TRANSACTION;'

      update_dest_columns unless @skip_columns
      move_sub_entities
      delete_source

      @sql_log << 'COMMIT;'
    end

    private

    def update_dest_columns
      # UPDATE dest row with source column values
    end

    def move_sub_entities
      # UPDATE sub-entity foreign keys from source.id to dest.id
    end

    def delete_source
      # DELETE source row
    end
  end
end
```

## Merge Rules

### When a merge SUCCEEDS (checker returns true):

- Source and dest are in **different seasons** (no overlap)
- Source and dest are in the **same team** with **compatible** (non-conflicting) sub-entities
- Shared sub-entities are exact duplicates (can be safely deleted)

### When a merge FAILS (checker returns false):

- **Same season, different teams**: two swimmers enrolled in different teams
  - Fix: merge the teams first, then retry the swimmer merge
- **Same meeting, conflicting results**: both have results in the same meeting program
  - Fix: use `force: true` if results are complementary, or resolve manually
- **Overlapping detail data**: sub-entities that cannot be auto-reconciled

### Force mode (`force: true`):

Proceeds despite checker errors, treating them as warnings. Use with caution — the generated SQL may need manual review.

## SQL Generation Pattern

Merge executors generate raw SQL (not ActiveRecord operations):

```ruby
# UPDATE destination columns:
@sql_log << "UPDATE swimmers SET complete_name = '#{@source.complete_name}' WHERE id = #{@dest.id};"

# Move sub-entities:
@sql_log << "UPDATE badges SET swimmer_id = #{@dest.id} WHERE swimmer_id = #{@source.id};"
@sql_log << "UPDATE meeting_individual_results SET swimmer_id = #{@dest.id} WHERE swimmer_id = #{@source.id};"

# Delete duplicates found by checker:
@checker.shared_badges.each do |dup_badge|
  @sql_log << "DELETE FROM badges WHERE id = #{dup_badge.id};"
end

# Delete source:
@sql_log << "DELETE FROM swimmers WHERE id = #{@source.id};"
```

The SQL is wrapped in a transaction (`SET AUTOCOMMIT = 0; START TRANSACTION; ... COMMIT;`).

## Creating a New Merge Strategy

### 1. Create the Checker

Create `app/strategies/merge/<entity>_checker.rb`:

- Collect all sub-entities linked to source and dest
- Partition into source-only, dest-only, and shared
- Check shared entities for conflicts
- Populate `@errors` (blockers) and `@warnings` (non-fatal)
- Expose collected entity lists via `attr_reader` for the executor

### 2. Create the Executor

Create `app/strategies/merge/<entity>.rb`:

- Initialize with `source:`, `dest:`, `skip_columns:`, `force:`
- Call `@checker.run` in `prepare`
- Generate SQL statements in dependency order (children before parents for deletes, parents before children for updates)

### 3. Write Specs

```bash
cd /home/steve/Projects/goggles_admin2
bundle exec rspec spec/strategies/merge/<entity>_checker_spec.rb
bundle exec rspec spec/strategies/merge/<entity>_spec.rb
```

## Debugging Tips

- **Inspect the checker report**: `checker.display_report` outputs the full analysis log
- **Check collected entities**: `checker.src_only_badges`, `checker.shared_badges`, etc.
- **Review generated SQL**: `executor.sql_log.join("\n")` before sending to API
- **Test on localhost first**: The merge modifies the local DB — verify before pushing SQL to remote
