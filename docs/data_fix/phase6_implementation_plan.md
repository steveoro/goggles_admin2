# Phase 6 Implementation Plan

**Status**: Skeleton Complete ✅ | Ready for Incremental Implementation 🚀

**Created**: 2025-11-03

---

## Overview

Phase 6 (Commit & SQL Generation) is the final step that commits all reviewed entities to the production database and generates SQL logs for remote sync.

### Key Architecture Decisions

1. **Hybrid Data Sources**:
   - **Phases 1-4**: Read from JSON files (small datasets)
   - **Phase 5**: Read from `data_import_*` DB tables (large datasets)

2. **Dependency-Aware Commit Order**:
   ```
   City → SwimmingPool → Meeting → MeetingSession
   City → Team → TeamAffiliation
   Swimmer → Badge
   MeetingEvent → MeetingProgram
   MeetingProgram → MIR → Lap
   ```

3. **Transaction Safety**:
   - All commits in single transaction
   - Rollback on any error
   - All-or-nothing guarantee

4. **SQL Logging**:
   - Uses existing `SqlMaker` utility
   - One SQL statement per INSERT/UPDATE
   - Stored in `crawler/data/results.new/<season_id>/`

---

## Current Status

### ✅ Completed

- `PhaseCommitter` class skeleton created
- Architecture defined with clear separation of concerns
- Generic `commit_entity` helper implemented
- Change detection logic (`attributes_changed?`)
- Attribute sanitization for model compatibility
- Stats tracking structure
- SQL log accumulation

### 🚧 To Implement

Each section below is a self-contained unit that can be implemented independently:

#### 1. Phase 1 Commits (Meeting & Sessions)
- [ ] `commit_meeting` - Handle meeting CREATE/UPDATE
- [ ] `commit_meeting_session` - Handle session CREATE/UPDATE
- [ ] Nested city/pool handling
- [ ] Tests

#### 2. Phase 2 Commits (Teams)
- [ ] `commit_team` - Handle team CREATE/UPDATE
- [ ] `commit_team_affiliation` - Auto-create affiliations
- [ ] Tests

#### 3. Phase 3 Commits (Swimmers & Badges)
- [ ] `commit_swimmer` - Handle swimmer CREATE/UPDATE
- [ ] `commit_badge` - Create badges with category calculation
- [ ] Category inference from YOB + meeting date
- [ ] Tests

#### 4. Phase 4 Commits (Events)
- [ ] `commit_meeting_event` - Handle event CREATE/UPDATE
- [ ] Tests

#### 5. Phase 5 Commits (Results & Laps)
- [ ] `ensure_meeting_program` - Find or create programs
- [ ] `commit_meeting_individual_result` - Handle MIR CREATE/UPDATE
- [ ] `commit_lap` - Handle lap CREATE/UPDATE
- [ ] Tests

#### 6. PushController Integration
- [ ] Update `PushController#prepare` to use `PhaseCommitter`
- [ ] SQL file generation
- [ ] File movement to `results.done`
- [ ] Tests

---

## Implementation Guidelines

### Generic Commit Pattern

All entity commits follow this pattern:

```ruby
def commit_<entity>(entity_hash)
  attributes = prepare_<entity>_attributes(entity_hash)
  
  commit_entity(
    GogglesDb::<EntityClass>,
    attributes,
    '<stat_prefix>'  # e.g., 'meetings', 'swimmers'
  )
end
```

### Change Detection

Only UPDATEs are generated when attributes differ:

```ruby
def attributes_changed?(model, new_attributes)
  new_attributes.except('id', :id).any? do |key, value|
    model.send(key.to_sym) != value
  end
end
```

### Error Handling

All commits wrapped in try/rescue with error accumulation:

```ruby
rescue ActiveRecord::RecordInvalid => e
  @stats[:errors] << "#{model_class.name} error: #{e.message}"
  Rails.logger.error("[PhaseCommitter] ERROR: #{e.message}")
  nil
end
```

---

## Implementation Order (Recommended)

### Week 1: Core Infrastructure
1. **Phase 2 (Teams)** - Simplest entity, good starting point
2. **Phase 3 (Swimmers)** - Similar pattern to teams
3. **Phase 1 (Meeting/Sessions)** - More complex due to nested entities

### Week 2: Events & Results
4. **Phase 4 (Events)** - Straightforward after Phase 1 experience
5. **Phase 5 (Results)** - Most complex, requires all previous work

### Week 3: Integration & Testing
6. **PushController Integration** - Wire everything together
7. **End-to-End Testing** - Full workflow validation
8. **Performance Testing** - Large dataset validation

---

## Testing Strategy

### Unit Tests

For each `commit_<entity>` method:
- ✅ CREATE new entity (no ID)
- ✅ UPDATE existing entity (with ID, attributes changed)
- ✅ SKIP existing entity (with ID, no changes)
- ✅ Handle validation errors gracefully
- ✅ Verify SQL log generation
- ✅ Verify stats tracking

### Integration Tests

- ✅ Complete phase 1-6 workflow
- ✅ Transaction rollback on error
- ✅ SQL file generation
- ✅ File movement to results.done
- ✅ Referential integrity maintained

### Performance Tests

- ✅ Memory usage (large result sets)
- ✅ Transaction time (500+ results)
- ✅ SQL file size (realistic datasets)

---

## Example Implementation: Phase 2 (Teams)

```ruby
def commit_phase2_entities
  Rails.logger.info('[PhaseCommitter] Committing Phase 2: Teams')
  return unless phase2_data

  teams_data = Array(phase2_data.dig('data', 'teams'))
  season_id = phase1_data&.dig('data', 'season_id')

  teams_data.each do |team_hash|
    team_id = commit_team(team_hash)
    commit_team_affiliation(team_id: team_id, season_id: season_id) if team_id && season_id
  end
end

def commit_team(team_hash)
  team_id = team_hash['team_id']
  return team_id unless team_id.nil? || team_id.zero?

  attributes = {
    'name' => team_hash['name'],
    'editable_name' => team_hash['editable_name'],
    'name_variations' => team_hash['name_variations'],
    'city_id' => team_hash['city_id']
  }

  commit_entity(GogglesDb::Team, attributes, 'teams')
end

def commit_team_affiliation(team_id:, season_id:)
  return if GogglesDb::TeamAffiliation.exists?(team_id: team_id, season_id: season_id)

  attributes = { 'team_id' => team_id, 'season_id' => season_id, 'name' => '' }
  commit_entity(GogglesDb::TeamAffiliation, attributes, 'affiliations')
end
```

---

## Next Steps

1. **Start with Phase 2 (Teams)**:
   - Implement `commit_team` method
   - Implement `commit_team_affiliation` method
   - Write unit tests
   - Test with real phase2.json file

2. **Progress to Phase 3 (Swimmers)**:
   - Similar pattern to teams
   - Add badge creation logic
   - Category calculation from YOB + meeting date

3. **Tackle Phase 1 (Meeting/Sessions)**:
   - More complex due to nested entities
   - Handle city/pool commits
   - Test cascade creation

4. **Implement Phase 4 & 5**:
   - Events are straightforward
   - Results require reading from DB tables

5. **Wire PushController**:
   - Replace `MacroCommitter` with `PhaseCommitter`
   - Keep SQL file generation
   - Test end-to-end workflow

---

## Success Criteria

- [ ] All entity types successfully committed
- [ ] SQL log generated correctly
- [ ] Transaction rollback works on errors
- [ ] No duplicate records created
- [ ] All tests passing (unit + integration)
- [ ] Performance acceptable for large files (500+ results)
- [ ] Documentation complete

---

## Files Created

- ✅ `/app/strategies/import/strategies/phase_committer.rb` - Main committer class

## Files To Create

- [ ] `/spec/strategies/import/strategies/phase_committer_spec.rb` - Unit tests
- [ ] `/spec/integration/phase6_commit_workflow_spec.rb` - Integration tests

## Files To Update

- [ ] `/app/controllers/push_controller.rb` - Switch to PhaseCommitter
- [ ] `/config/routes.rb` - Ensure push routes work with phase files

---

## Notes

- **Unused method argument lints**: Intentional in TODO stub methods, will be used in full implementation
- **SqlMaker utility**: Already exists and tested, handles INSERT/UPDATE SQL generation
- **Transaction safety**: All commits in single transaction ensures consistency
- **Phase 5 reads from DB**: Unlike phases 1-4, phase 5 results stored in temp tables
- **File movement**: Only move to `results.done` after successful commit + SQL generation
