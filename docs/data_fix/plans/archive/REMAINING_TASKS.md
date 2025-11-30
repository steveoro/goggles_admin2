# Data-Fix: Remaining Tasks

**Date**: 2025-11-25  
**Status**: ✅ All Core Features Complete | 🎯 Polish & Testing Phase

---

## ✅ Completed (2025-11-25)

### LT4 Structure Review ✅
- EventSolver: LT4 (events[]) primary, LT2 (sections[]) fallback
- ResultSolver: LT4 (events[]) primary, LT2 (sections[]) fallback
- Phase5Populator: Already correct (LT2→LT4 normalization)
- SwimmerSolver & TeamSolver: Already correct
- All specs passing

### Phase 6 Relay Commit ✅
- Full commit implementation for MRR/MRS/RelayLap
- UPDATE support for existing relay results
- INSERT for new relay results
- SQL batch file generation
- Data cleanup after commit

### Phase 5 Polish ✅
- Pagination (max 2500 rows per page)
- Server-side filtering for programs with issues
- Client-side row filtering
- Helper method refactoring (explicit parameters)
- Phase 3 enrichment fix

---

## 🎯 Remaining Tasks (Optional Polish)

### 1. RSpec Tests ⏱️ 4-6 hours
**Goal**: Comprehensive test coverage for Phase 5 relay workflow

**Implementation**:
```ruby
# Add to DataFixController
PHASE5_MAX_ROWS_PER_PAGE = 500  # Make configurable

def calculate_pagination
  page = params[:page].to_i.positive? ? params[:page].to_i : 1
  
  # Group programs and calculate row counts
  programs_with_counts = @phase5_programs.map do |prog|
    results_count = prog['results'].size
    laps_count = prog['results'].sum { |r| (r['laps'] || []).size }
    { program: prog, total_rows: results_count + laps_count }
  end
  
  # Split into pages
  @paginated_programs, @total_pages = paginate_programs(programs_with_counts, page)
end
```

**UI Updates**:
- Add pagination controls to `review_results_v2.html.haml`
- Show "Page X of Y" indicator
- Previous/Next buttons

**Files**:
- `app/controllers/data_fix_controller.rb`
- `app/views/data_fix/review_results_v2.html.haml`

---

### 2. Phase 5 Filter Toggle ⏱️ 1-2 hours
**Goal**: Implement "Show only results with issues" filter

**Implementation**:
```javascript
// Add to review_results_v2.html.haml
document.getElementById('filter-issues').addEventListener('change', function() {
  const showOnlyIssues = this.checked;
  
  // Filter program cards
  document.querySelectorAll('.program-card').forEach(card => {
    const hasIssues = card.dataset.hasIssues === 'true';
    card.style.display = (showOnlyIssues && !hasIssues) ? 'none' : 'block';
  });
  
  // Update counts
  updateVisibleCounts();
});
```

**Requirements**:
- Add `data-has-issues` attribute to program cards
- Show/hide based on checkbox state
- Smooth CSS transitions
- Works for both individual and relay results

**Files**:
- `app/views/data_fix/review_results_v2.html.haml`
- `app/views/data_fix/_result_program_card.html.haml`
- `app/views/data_fix/_relay_program_card.html.haml`

---

### 3. Phase 6 Relay Commit ⏱️ 8-10 hours
**Goal**: Commit MRR/MRS/RelayLap from data_import_* to production tables

**Architecture**:
```
Phase 6 Relay Commit Flow:
1. Read data_import_meeting_relay_results
2. For each MRR:
   a. Find/create MeetingRelayResult
   b. Generate SQL INSERT/UPDATE
   c. Commit relay swimmers (4 per result)
   d. Commit relay laps (1+ per swimmer)
3. Wrap in transaction
4. Generate SQL log
5. Return stats
```

**Implementation**:

#### A. commit_meeting_relay_result (2-3 hours)
```ruby
# app/strategies/import/committers/main.rb
def commit_meeting_relay_result(mrr_import)
  # Find existing or create new
  mrr = GogglesDb::MeetingRelayResult.find_by(
    meeting_program_id: mrr_import.meeting_program_id,
    team_id: mrr_import.team_id
  ) || GogglesDb::MeetingRelayResult.new
  
  # Set attributes
  mrr.assign_attributes(
    meeting_program_id: mrr_import.meeting_program_id,
    team_id: mrr_import.team_id,
    rank: mrr_import.rank,
    minutes: mrr_import.minutes,
    # ... all timing fields
    disqualified: mrr_import.disqualified
  )
  
  # Save and log
  if mrr.save
    sql_log << SqlMaker.new(row: mrr).log_insert_or_update
    logger.log_success(entity_type: 'MeetingRelayResult', entity_id: mrr.id)
    @stats[:mrr_created] += mrr.previously_new_record? ? 1 : 0
    @stats[:mrr_updated] += mrr.previously_new_record? ? 0 : 1
  else
    logger.log_validation_error(entity_type: 'MeetingRelayResult', model_row: mrr)
  end
  
  mrr
end
```

#### B. commit_relay_swimmers (2-3 hours)
```ruby
def commit_relay_swimmers(mrs_imports, parent_mrr)
  mrs_imports.each do |mrs_import|
    mrs = GogglesDb::MeetingRelaySwimmer.new(
      meeting_relay_result_id: parent_mrr.id,
      swimmer_id: mrs_import.swimmer_id,
      badge_id: mrs_import.badge_id,  # Find from swimmer + team + season
      relay_order: mrs_import.relay_order,
      length_in_meters: mrs_import.length_in_meters,
      # ... timing fields
      stroke_type_id: infer_stroke_type(mrs_import)
    )
    
    if mrs.save
      sql_log << SqlMaker.new(row: mrs).log_insert
      logger.log_success(entity_type: 'MeetingRelaySwimmer', entity_id: mrs.id)
      @stats[:mrs_created] += 1
    else
      logger.log_validation_error(entity_type: 'MeetingRelaySwimmer', model_row: mrs)
    end
  end
end
```

#### C. commit_relay_laps (2 hours)
```ruby
def commit_relay_laps(rlap_imports, mrs_lookup)
  rlap_imports.each do |rlap_import|
    # Find parent MRS by import key
    mrs = mrs_lookup[rlap_import.parent_import_key]
    next unless mrs
    
    rlap = GogglesDb::RelayLap.new(
      meeting_relay_swimmer_id: mrs.id,
      meeting_relay_result_id: mrs.meeting_relay_result_id,
      length_in_meters: rlap_import.length_in_meters,
      # ... timing fields
    )
    
    if rlap.save
      sql_log << SqlMaker.new(row: rlap).log_insert
      @stats[:relay_laps_created] += 1
    else
      logger.log_validation_error(entity_type: 'RelayLap', model_row: rlap)
    end
  end
end
```

#### D. Integration (2 hours)
```ruby
def commit_phase5_relay_entities
  # Read all relay imports for this meeting
  relay_results = GogglesDb::DataImportMeetingRelayResult
                  .where(phase_file_path: source_path)
                  .order(:import_key)
  
  relay_results.each do |mrr_import|
    # Commit relay result
    mrr = commit_meeting_relay_result(mrr_import)
    next unless mrr
    
    # Find and commit relay swimmers
    mrs_imports = GogglesDb::DataImportMeetingRelaySwimmer
                  .where(parent_import_key: mrr_import.import_key)
                  .order(:relay_order)
    commit_relay_swimmers(mrs_imports, mrr)
    
    # Find and commit relay laps
    rlap_imports = GogglesDb::DataImportRelayLap
                   .where(parent_import_key: mrr_import.import_key)
                   .order(:length_in_meters)
    mrs_lookup = build_mrs_lookup(mrr)  # Map import_key -> MRS
    commit_relay_laps(rlap_imports, mrs_lookup)
  end
end
```

#### E. Update commit_all (1 hour)
```ruby
def commit_all
  # ... existing code ...
  
  # Add after individual results
  commit_phase5_relay_entities  # NEW
  
  # ... rest of code ...
end
```

**Files**:
- `app/strategies/import/committers/main.rb`
- `app/strategies/import/phase_commit_logger.rb` (already exists)

**Testing**:
- Test with relay-only file
- Test with mixed individual + relay file
- Verify transaction rollback on error
- Check SQL log generation
- Verify all associations correct

---

### 4. RSpec Tests ⏱️ 4-6 hours
**Goal**: Add comprehensive tests for Phase 5 relay populator

**Test Files to Create**:

#### `spec/strategies/import/phase5_populator_relay_spec.rb`
```ruby
RSpec.describe Import::Phase5Populator, type: :strategy do
  describe 'relay result population' do
    let(:source_path) { 'spec/fixtures/relay_only.json' }
    let(:populator) { described_class.new(source_path: source_path, ...) }
    
    describe '#populate_lt4_relay_results!' do
      it 'creates MRR records' do
        expect { populator.populate! }
          .to change(GogglesDb::DataImportMeetingRelayResult, :count).by(30)
      end
      
      it 'creates 4 MRS per result' do
        expect { populator.populate! }
          .to change(GogglesDb::DataImportMeetingRelaySwimmer, :count).by(120)
      end
      
      it 'creates relay lap records' do
        expect { populator.populate! }
          .to change(GogglesDb::DataImportRelayLap, :count).by_at_least(120)
      end
      
      it 'populates string keys' do
        populator.populate!
        mrr = GogglesDb::DataImportMeetingRelayResult.last
        expect(mrr.team_key).to be_present
        expect(mrr.meeting_program_key).to be_present
      end
      
      it 'links swimmers to phase3 data' do
        populator.populate!
        mrs = GogglesDb::DataImportMeetingRelaySwimmer.first
        expect(mrs.swimmer_id).to be_present
        expect(mrs.swimmer_key).to match(/\w+\|\w+\|\d{4}/)
      end
    end
  end
end
```

**Test Coverage Goals**:
- ✅ MRR creation and attributes
- ✅ MRS creation (4 per result)
- ✅ RelayLap creation
- ✅ String key population
- ✅ Swimmer linking
- ✅ Timing calculation (delta + cumulative)
- ✅ Import key generation
- ✅ Error handling

---

### 5. Documentation Cleanup ⏱️ 1-2 hours
**Goal**: Archive obsolete plans, update main docs

**Tasks**:
- ✅ Move `PHASE5_IMPROVEMENTS_PLAN.md` to archive (DONE)
- Update `README.md` to reflect Phase 5 completion
- Update `PHASES.md` with string keys info
- Update `RELAY_IMPLEMENTATION.md` with current state
- Remove outdated codemaps if superseded

---

## 📋 Summary

| Task | Priority | Estimate | Status |
|------|----------|----------|--------|
| Pagination | High | 2-3 hrs | 🎯 Next |
| Filter Toggle | High | 1-2 hrs | 🎯 Next |
| Phase 6 Relay Commit | Critical | 8-10 hrs | Planned |
| RSpec Tests | Medium | 4-6 hrs | Planned |
| Documentation | Low | 1-2 hrs | In Progress |

**Total Estimate**: 16-23 hours  
**Target Completion**: End of Week (2025-11-22)

---

## 🚀 Getting Started

### Today (2025-11-17):
1. ✅ Update ROADMAP (DONE)
2. ✅ Archive obsolete plans (DONE)
3. 🎯 Implement Phase 5 pagination (NEXT)

### Tomorrow (2025-11-18):
1. Implement filter toggle
2. Start Phase 6 relay commit

### This Week:
1. Complete Phase 6 relay commit
2. Add RSpec tests
3. Final documentation polish

---

**Last Updated**: 2025-11-17  
**Next Review**: 2025-11-18
