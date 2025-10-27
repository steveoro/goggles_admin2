# Phase 5 & 6 Completion Plan

**Status**: Phases 1-4 Complete ✅ | Phase 5 DB Models Complete ✅ | Phase 5 UI & Phase 6 In Progress 🚧

**Document Version**: 1.1 (2025-10-27)

---

## Overview

Complete Data-Fix pipeline by finalizing Phase 5 (Result Review) and implementing Phase 6 (Commit & SQL Generation).

### Goals

1. **Phase 5**: Hybrid storage (DB tables for results/laps), read-only review UI, entity matching
2. **Phase 6**: New `PhaseCommitter` strategy reading JSON (phases 1-4) + DB tables (phase 5) to generate SQL

### Key Principles

- **Hybrid Architecture**: JSON for small datasets (phases 1-4), DB tables for large datasets (phase 5)
- Phases 1-4 files contain all entity IDs needed for matching
- Phase 5 stores results/laps in temporary `data_import_*` tables (indexed, efficient)
- Phase 6 reads from both sources respecting referential integrity
- Remove broken "Use Legacy" buttons

### Architecture Update (v0.8.11) ✅

**goggles_db gem changes:**
- Created 5 temporary tables: `data_import_meeting_individual_results`, `data_import_laps`, `data_import_meeting_relay_results`, `data_import_relay_laps`, `data_import_meeting_relay_swimmers`
- All models include `TimingManageable` concern (consistent timing behavior with MIR/Lap)
- Unique `import_key` on each table for O(1) lookups
- 28 specs passing with full coverage

---

## Phase 5: Result Review Finalization

### 5.1 Result Card Styling ✅

**Goal**: Reuse form card styling from phases 1-4.

**Implementation**:
- Collapsible cards (Bootstrap accordion)
- Header: event code + category + gender + ID/NEW badge
- Visual indicators: ✓ green (matched), + orange (new)
- Borders: gray-2 (matched), orange-2 (new)
- Background: bg-light (matched), bg-light-yellow (new)
- Read-only content (no forms)

**Interaction**: 1st click = fetch+expand, 2nd click = collapse

**Tasks**:
- [ ] Update `_results_category_v2.html.haml` with card layout
- [ ] Add visual status indicators
- [ ] Implement AJAX load on first expand
- [ ] Test collapse/expand behavior

### 5.2 Match Existing Database Rows ✅

**Goal**: Find and display existing `MeetingEvent` and `MeetingProgram` IDs.

**Matching Logic**:

```ruby
# MeetingEvent: match by event_type_id + meeting_session_id
meeting_event = GogglesDb::MeetingEvent
  .where(meeting_session_id: session_id, event_type_id: event_type_id)
  .first

# MeetingProgram: match by meeting_event_id + category + gender
# (requires meeting_event_id due to referential integrity)
meeting_program = GogglesDb::MeetingProgram
  .where(
    meeting_event_id: meeting_event_id,
    category_type_id: category_id,
    gender_type_id: gender_id
  )
  .first
```

**When**: During `review_results` action initialization

**Tasks**:
- [ ] Implement MeetingEvent matching
- [ ] Implement MeetingProgram matching
- [ ] Update phase 5 JSON to store matched IDs
- [ ] Display matched IDs in headers
- [ ] Add specs

### 5.3 Result Card Content & Data Structure ✅

**Goal**: Display results efficiently, prepare for phase 6 commit.

**Phase 5 JSON Enhancement**:
```json
{
  "_meta": { "source_path": "...", "season_id": 242 },
  "result_groups": [
    {
      "event_key": "100SL",
      "event_code": "100SL",
      "category_code": "M45",
      "gender_code": "M",
      "meeting_event_id": 12345,      // ← NEW: matched from DB
      "meeting_program_id": 67890,    // ← NEW: matched from DB
      "results": [
        {
          "rank": 1,
          "swimmer_key": "ROSSI|MARIO|1978",
          "swimmer_id": 456,            // ← From phase 3
          "team_key": "CSI OBER FERRARI",
          "team_id": 789,               // ← From phase 2
          "timing": "00:58.45",
          "disqualified": false,
          "meeting_individual_result_id": null,  // ← For phase 6 matching
          "laps": [
            { "length_in_meters": 50, "timing": "00:28.12", "lap_id": null }
          ]
        }
      ]
    }
  ]
}
```

**MIR Matching Requirements** (for Phase 6):
- `meeting_program_id` must exist (requires `meeting_event_id`)
- `swimmer_id` must exist (from phase 3)
- `team_id` must exist (from phase 2)
- If all 3 present → check if MIR exists → UPDATE or INSERT

**Tasks**:
- [ ] Update phase 5 JSON structure
- [ ] Scan phase 1-4 files in `review_results` to populate IDs
- [ ] Match existing MeetingIndividualResult rows
- [ ] Update ResultDetailsCardComponent
- [ ] Add specs

### 5.4 Remove Legacy Buttons ✅

**Goal**: Clean up broken "Use Legacy" functionality.

**Tasks**:
- [ ] Remove all "Use Legacy" buttons from views
- [ ] Remove related controller actions
- [ ] Update documentation

### 5.5 Commit Button ✅

**Goal**: Add "Commit All Changes" button routing to Phase 6.

**Implementation**:
```haml
= form_tag(push_prepare_path, method: :post) do
  = hidden_field_tag(:phase1_path, @phase1_path)
  = hidden_field_tag(:phase2_path, @phase2_path)
  = hidden_field_tag(:phase3_path, @phase3_path)
  = hidden_field_tag(:phase4_path, @phase4_path)
  = hidden_field_tag(:phase5_path, @phase5_path)
  = submit_tag('Commit All Changes', class: 'btn btn-primary btn-lg',
               data: { confirm: 'Generate SQL commit file?' })
```

**Tasks**:
- [ ] Add button to review_results view
- [ ] Update routes
- [ ] Add confirmation dialog
- [ ] Test button enables when all phases complete

---

## Phase 6: Commit & SQL Generation

### 6.1 PhaseCommitter Architecture ✅

**Goal**: Create new committer working with phase files instead of MacroSolver.

**Class Structure**:
```ruby
module Import
  module Strategies
    class PhaseCommitter
      attr_reader :phase_files, :sql_log, :commit_data
      
      def initialize(phase_file_paths:)
        @phase_files = load_phase_files(phase_file_paths)
        @sql_log = []
        @commit_data = {} # Cross-phase ID mappings
      end
      
      def commit_all
        ActiveRecord::Base.transaction do
          commit_phase1_entities  # Meeting, Sessions, Pools, Cities
          commit_phase2_entities  # Teams, TeamAffiliations
          commit_phase3_entities  # Swimmers, Badges
          commit_phase4_entities  # MeetingEvents, MeetingPrograms
          commit_phase5_entities  # MIRs, MRRs, Laps
        end
      end
    end
  end
end
```

**Tasks**:
- [ ] Create `PhaseCommitter` class skeleton
- [ ] Implement phase file loading
- [ ] Add transaction wrapper
- [ ] Implement `commit_entity` core method
- [ ] Add SQL logging via `SqlMaker`
- [ ] Create comprehensive specs

### 6.2 Phase 1 Commits (Meeting, Sessions, Pools, Cities) ✅

**Dependency Order**: City → SwimmingPool → Meeting → MeetingSession

**Tasks**:
- [ ] Implement `commit_phase1_entities`
- [ ] Handle City commits (optional)
- [ ] Handle SwimmingPool commits
- [ ] Handle Meeting commits
- [ ] Handle MeetingSession commits
- [ ] Add change detection for UPDATEs
- [ ] Add specs

### 6.3 Phase 2 Commits (Teams, TeamAffiliations) ✅

**Dependency Order**: City → Team → TeamAffiliation

**Tasks**:
- [ ] Implement `commit_phase2_entities`
- [ ] Handle Team commits
- [ ] Auto-create TeamAffiliation for new teams
- [ ] Store team_id mappings for phase 5
- [ ] Add specs

### 6.4 Phase 3 Commits (Swimmers, Badges) ✅

**Dependency Order**: Swimmer → Badge (requires Swimmer + Team + Season + Category)

**Category Calculation**: Based on swimmer YOB and meeting date

**Tasks**:
- [ ] Implement `commit_phase3_entities`
- [ ] Handle Swimmer commits
- [ ] Handle Badge commits with category calculation
- [ ] Store swimmer_id mappings for phase 5
- [ ] Add specs

### 6.5 Phase 4 Commits (MeetingEvents, MeetingPrograms) ✅

**Dependency Order**: MeetingEvent (requires Session) → MeetingProgram (defer to phase 5)

**Note**: MeetingPrograms created in phase 5 when committing results

**Tasks**:
- [ ] Implement `commit_phase4_entities`
- [ ] Handle MeetingEvent commits
- [ ] Store meeting_event_id mappings for phase 5
- [ ] Add specs

### 6.6 Phase 5 Commits (Results, Laps) ✅

**Dependency Order**:
1. MeetingProgram (requires MeetingEvent + Category + Gender)
2. MeetingIndividualResult (requires Program + Swimmer + Team + Badge)
3. Lap (requires MIR)

**MIR Matching**:
```ruby
existing_mir = GogglesDb::MeetingIndividualResult.find_by(
  meeting_program_id: program_id,
  swimmer_id: swimmer_id,
  team_id: team_id
)
# If found → UPDATE (if changed), else → INSERT
```

**Tasks**:
- [ ] Implement `commit_phase5_entities`
- [ ] Handle MeetingProgram creation/matching
- [ ] Handle MIR commits with full hierarchy
- [ ] Handle Lap commits
- [ ] Add timing parsing helpers
- [ ] Handle MRR, RelayLap, MeetingRelaySwimmer
- [ ] Add specs

### 6.7 Change Detection & SQL Generation ✅

**Goal**: Only generate UPDATEs when attributes changed.

```ruby
def attributes_changed?(model, new_attrs)
  new_attrs.except('id').any? { |key, value| model.send(key) != value }
end

def commit_entity(model_class, attributes)
  id = attributes['id']
  if id.present?
    existing = model_class.find(id)
    if attributes_changed?(existing, attributes)
      existing.update!(attributes.except('id'))
      @sql_log << SqlMaker.new(row: existing).log_update
    end
    existing.id
  else
    new_record = model_class.create!(attributes)
    @sql_log << SqlMaker.new(row: new_record).log_insert
    new_record.id
  end
end
```

**Tasks**:
- [ ] Implement `attributes_changed?` helper
- [ ] Test with various data types
- [ ] Ensure `SqlMaker` generates correct UPDATEs
- [ ] Add specs

### 6.8 PushController Integration ✅

**Goal**: Update `PushController#prepare` to use `PhaseCommitter`.

**Current Flow** (Legacy):
```ruby
@committer = Import::MacroCommitter.new(solver: @solver)
@committer.commit_all
```

**New Flow**:
```ruby
@committer = Import::Strategies::PhaseCommitter.new(
  phase_file_paths: {
    phase1: params[:phase1_path],
    phase2: params[:phase2_path],
    phase3: params[:phase3_path],
    phase4: params[:phase4_path],
    phase5: params[:phase5_path]
  }
)
@committer.commit_all
```

**SQL File Output**: Same as before, stored in `crawler/data/results.new/<season_id>/`

**Backup Files**: Move committed phase files to `crawler/data/results.done/<season_id>/`

**Tasks**:
- [ ] Update `PushController#prepare` to accept phase file paths
- [ ] Instantiate `PhaseCommitter` instead of `MacroCommitter`
- [ ] Keep SQL file generation logic
- [ ] Move files to `results.done` on success
- [ ] Add error handling and rollback
- [ ] Add specs

### 6.9 Error Handling & Validation ✅

**Goal**: Graceful failures with clear error messages.

**Validation Checks**:
- All required phase files present
- Phase file integrity (valid JSON, expected structure)
- Required entity IDs present (no broken references)
- Database constraints satisfied

**Error Recovery**:
- Transaction rollback on any failure
- Clear error messages for operators
- Log error details for debugging

**Tasks**:
- [ ] Add phase file validation
- [ ] Add entity hierarchy validation
- [ ] Add database constraint validation
- [ ] Implement transaction rollback
- [ ] Add error logging
- [ ] Add specs for error cases

---

## Testing Strategy

### Unit Tests
- [ ] PhaseCommitter initialization and phase loading
- [ ] Each `commit_phaseN_entities` method
- [ ] Change detection logic
- [ ] SQL generation via SqlMaker
- [ ] Error handling and validation

### Integration Tests
- [ ] Complete phase 1-6 workflow
- [ ] Phase file reading and ID resolution
- [ ] Database commits with referential integrity
- [ ] SQL file generation
- [ ] File movement to results.done

### Performance Tests
- [ ] Memory usage (streaming vs loading all)
- [ ] Transaction time for large result sets
- [ ] SQL file generation time

---

## Implementation Timeline

### Week 1: Phase 5 Finalization
- Day 1-2: Result card styling and matching logic
- Day 3-4: Phase 5 JSON structure updates
- Day 5: Commit button and testing

### Week 2-3: Phase 6 Implementation
- Day 1-2: PhaseCommitter architecture
- Day 3-4: Phase 1-2 commits
- Day 5-6: Phase 3-4 commits
- Day 7-9: Phase 5 commits (results + laps)
- Day 10: PushController integration

### Week 4: Testing & Refinement
- Day 1-2: Unit tests
- Day 3-4: Integration tests
- Day 5: Performance testing and optimization

---

## Success Criteria

- [ ] Phase 5 displays all results in collapsible cards
- [ ] Phase 5 shows matched entity IDs correctly
- [ ] Phase 6 generates valid SQL for all entities
- [ ] SQL UPDATEs only when attributes changed
- [ ] SQL INSERTs for new entities
- [ ] Transaction commits successfully for full result set
- [ ] Files moved to results.done on success
- [ ] All tests passing (unit + integration)
- [ ] Memory usage acceptable for large files
- [ ] Documentation complete

---

## Files to Create/Update

### New Files
- `app/strategies/import/strategies/phase_committer.rb`
- `spec/strategies/import/strategies/phase_committer_spec.rb`

### Updated Files
- `app/controllers/data_fix_controller.rb` (phase 5 matching)
- `app/controllers/push_controller.rb` (phase 6 integration)
- `app/views/data_fix/review_results.html.haml` (phase 5 view)
- `app/views/data_fix/_results_category_v2.html.haml` (card styling)
- `config/routes.rb` (push_prepare_path)

### Phase File Structure Updates
- Phase 5 JSON: Add `meeting_event_id`, `meeting_program_id`, `meeting_individual_result_id`
- All phases: Ensure consistent ID storage

---

## Notes

- Legacy "Use Legacy" buttons are broken and should be removed
- Phase files can be enhanced as needed (no backward compatibility required)
- PhaseCommitter is completely new (no MacroCommitter compatibility needed)
- SQL generation uses existing `SqlMaker` utility
- Transaction ensures all-or-nothing commit
