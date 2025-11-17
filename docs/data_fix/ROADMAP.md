# Data-Fix: Development Roadmap

**Last Updated**: 2025-11-15  
**Version**: 2.1  
**Status**: ✅ Phases 1-4 Complete | 🟡 Phase 5 In Progress | 🎯 Phase 6 Relay Pending

This document consolidates all active development plans and tracks progress toward full relay support completion.

---

## 📊 Overall Status

| Component | Status | Completion | Notes |
|-----------|--------|------------|-------|
| **Phase 1: Meetings** | ✅ Complete | 100% | Meeting, sessions, venues |
| **Phase 2: Teams** | ✅ Complete | 100% | Pre-matching implemented |
| **Phase 3: Swimmers** | ✅ Complete | 100% | Pre-matching + relay enrichment |
| **Phase 4: Events** | ✅ Complete | 100% | Relay support added 2025-11-10 |
| **Phase 5 Individual** | ✅ Complete | 100% | Populator + UI working |
| **Phase 5 Relay** | 🟡 In Progress | 60% | Enrichment ✅, Populator pending |
| **Phase 6 Individual** | ✅ Complete | 100% | Full commit working |
| **Phase 6 Relay** | 🎯 Planned | 0% | Needs commit methods |
| **Documentation** | 🟡 In Progress | 85% | Consolidation ongoing |
| **UI Polish** | 🟡 In Progress | 90% | Minor improvements needed |

---

## 🎯 Current Sprint (2025-11-15)

### ✅ Recently Completed
- **Phase 3 Relay Enrichment** (2025-11-14)
  - Fixed swimmer matching (case-sensitivity + 4/5-token lap format)
  - Enrichment filtering now correctly excludes matched swimmers
  - All swimmers with `swimmer_id` removed from enrichment list
  
- **UI Standardization** (2025-11-15)
  - Phase 1 meeting card auto-collapses when required fields filled
  - Standardized border colors: gray (matched), yellow (new), red (missing data)
  - Unified badge system with detailed missing data indicators
  - Special "needs edit" case for matched swimmers with incomplete names

### 🎯 Active Tasks

#### 1. Documentation Consolidation (IN PROGRESS)
**Goal**: 1 main README + specialized reference docs + 1 active ROADMAP

**Changes**:
- ✅ Created `DATA_STRUCTURES.md` - Comprehensive data format reference
- ✅ Created `ROADMAP.md` (this file) - Single source of truth for plans
- 🎯 Update `README.md` to reference new structure
- 🎯 Archive obsolete plan files to `plans/archive/`
- 🎯 Keep only essential task-specific docs in `plans/`

**Target Structure**:
```
docs/data_fix/
├── README.md               ← Main entry + quick status
├── PHASES.md              ← Phase 1-6 implementation guide
├── TECHNICAL.md           ← Architecture patterns
├── DATA_STRUCTURES.md     ← Data format reference (NEW!)
├── RELAY_IMPLEMENTATION.md ← Relay status + specifics
├── ROADMAP.md             ← Active development plans (NEW!)
├── CHANGELOG.md           ← Version history
└── plans/
    ├── archive/           ← Historical plans (reference only)
    └── [task-specific docs if needed]
```

#### 2. Phase 5 Relay Populator (NEXT UP)
**Estimate**: 4-6 hours  
**Priority**: High

**Requirements**:
- Populate `data_import_meeting_relay_results` table
- Populate `data_import_relay_swimmers` (4 per result)
- Populate `data_import_relay_laps` (1+ per swimmer)
- Link to Phase 3 swimmer data via enrichment
- Handle both LT2 and LT4 formats

**Acceptance Criteria**:
- Relay results appear in Phase 5 UI
- All 4 swimmers correctly linked per relay
- Lap times match source data
- Import keys generate correctly

---

## 🗺️ Complete Feature Roadmap

### Milestone 1: Relay Recognition ✅ COMPLETE
**Duration**: ~8 hours  
**Completed**: 2025-11-10

- ✅ EventSolver relay-only file detection
- ✅ Gender-based event grouping (F, M, X)
- ✅ Italian title parsing: "4x50 m Misti" → EventType
- ✅ ResultSolver relay event counting
- ✅ Phase 4 tests updated

**Result**: Relay files now produce clean phase4 output (1 session, 3 events)

### Milestone 2: Relay Enrichment ✅ COMPLETE
**Duration**: ~12 hours  
**Completed**: 2025-11-14

- ✅ RelayEnrichmentDetector service
- ✅ Phase 3 UI enrichment panel
- ✅ Auxiliary phase3 file merging
- ✅ Swimmer matching logic (case-insensitive)
- ✅ 4-token and 5-token lap format parsing
- ✅ Missing data detection (YOB, gender, swimmer_id)
- ✅ Filter matched swimmers from enrichment list

**Result**: Phase 3 can enrich relay-only files with full swimmer data

### Milestone 3: UI Standardization ✅ COMPLETE
**Duration**: ~4 hours  
**Completed**: 2025-11-15

- ✅ Meeting card auto-collapse logic
- ✅ Standardized border colors (Phase 2 & 3)
- ✅ Unified badge system with detailed states
- ✅ Icon system (check, plus, warning, edit)
- ✅ Missing data indicators

**Result**: Consistent UI experience across all phases

### Milestone 4: Phase 5 Relay Populator 🎯 NEXT
**Estimate**: 4-6 hours  
**Target**: 2025-11-16

**Tasks**:
1. **Extract relay data from source** (1 hour)
   - Read relay rows from source JSON
   - Parse swimmer1-8 fields
   - Parse lap data with 4/5-token handling
   
2. **Populate relay result tables** (2 hours)
   - Generate import keys
   - Create `DataImportMeetingRelayResult` records
   - Link to meeting_program_id
   - Handle timing and status flags
   
3. **Populate relay swimmer tables** (1.5 hours)
   - Create `DataImportRelaySwimmer` records (4 per result)
   - Link to phase3 swimmer data
   - Calculate stroke_type_id
   - Handle timing
   
4. **Populate relay lap tables** (0.5 hours)
   - Create `DataImportRelayLap` records
   - Parse cumulative vs delta timing
   - Link to relay swimmers
   
5. **Testing** (1 hour)
   - Unit tests for each table type
   - Integration test with real relay file
   - Verify all swimmers linked correctly

**Acceptance Criteria**:
- ✅ All 3 relay tables populated
- ✅ Import keys generate correctly
- ✅ Swimmer links resolve from phase3
- ✅ Timing data accurate
- ✅ Tests pass

### Milestone 5: Phase 5 Relay UI 🎯 PLANNED
**Estimate**: 3-4 hours  
**Dependencies**: Milestone 4

**Tasks**:
1. **Create relay card partial** (1.5 hours)
   - `_relay_program_card.html.haml`
   - Display team, timing, rank
   - Show 4 swimmers with badges
   - Expandable lap details
   
2. **Controller queries** (1 hour)
   - Load relay results grouped by program
   - Eager load swimmers and laps
   - Build display hashes
   
3. **Testing** (0.5 hours)
   - Manual browser testing
   - Screenshot verification
   - Edge cases (disqualified, missing data)

**Acceptance Criteria**:
- ✅ Relay results display in Phase 5
- ✅ All 4 swimmers shown per relay
- ✅ Lap times expandable
- ✅ Match status badges correct

### Milestone 6: Phase 6 Relay Commit 🎯 PLANNED
**Estimate**: 6-8 hours  
**Dependencies**: Milestone 4 & 5

**Tasks**:
1. **Commit relay results** (2-3 hours)
   - `commit_meeting_relay_result` method
   - Read from `data_import_meeting_relay_results`
   - Match existing MRR (UPDATE vs INSERT)
   - Generate SQL log
   - Update stats
   
2. **Commit relay swimmers** (2 hours)
   - `commit_relay_swimmers` method
   - Read from `data_import_relay_swimmers`
   - Link to MRR + swimmer + badge
   - Handle stroke types
   - Generate SQL log
   
3. **Commit relay laps** (1-2 hours)
   - `commit_relay_laps` method
   - Read from `data_import_relay_laps`
   - Link to relay swimmers
   - Generate SQL log
   
4. **Testing & Integration** (1.5 hours)
   - Unit tests for each commit method
   - Full integration test (Phase 1-6)
   - Verify SQL log correctness
   - Transaction rollback tests

**Acceptance Criteria**:
- ✅ All relay entities commit correctly
- ✅ Dependency order maintained
- ✅ SQL log generates properly
- ✅ Transaction safety verified
- ✅ Stats tracking accurate

---

## 🐛 Known Issues

### Phase 5
- ⚠️ **Relay populator missing** - Currently skips relay events (line 75)
- ⚠️ **LT2 format support** - Only LT4 fully supported
- ℹ️ **Large meeting performance** - 10,000+ results may be slow

### UI
- ℹ️ **Progress broadcasting** - Needs optimization for large datasets
- ℹ️ **Pagination** - Could be improved for phase 3 (1000+ swimmers)

### Documentation
- ⚠️ **Plan files scattered** - Being consolidated into ROADMAP.md
- ℹ️ **Code comments** - Some methods need better documentation

---

## 📝 Future Enhancements

### Short Term (Next 2-4 weeks)
- [ ] Complete relay support (Milestones 4-6)
- [ ] LT2 format full support
- [ ] Performance optimization for large meetings
- [ ] Complete documentation consolidation

### Medium Term (1-2 months)
- [ ] Background job processing for Phase 5
- [ ] Real-time progress updates via ActionCable
- [ ] Batch commit capability (multiple meetings)
- [ ] Enhanced fuzzy matching with ML

### Long Term (3+ months)
- [ ] API endpoints for external tools
- [ ] Automated result import from timing systems
- [ ] Historical data migration tools
- [ ] Advanced analytics dashboard

---

## 🎓 Development Guidelines

### Adding New Features
1. Update this ROADMAP with task breakdown
2. Create feature branch: `feature/short-description`
3. Implement with tests (TDD preferred)
4. Update relevant documentation
5. Submit PR with detailed description

### Bug Fixes
1. Create issue in GitHub/tracking system
2. Add to "Known Issues" section above
3. Create bugfix branch: `bugfix/issue-number-description`
4. Fix with regression test
5. Update CHANGELOG.md

### Documentation Updates
1. Keep this ROADMAP current
2. Update phase-specific docs as needed
3. Add examples for complex features
4. Document any breaking changes

---

## 📞 Reference

### Key Files
- **Solvers**: `app/strategies/import/solvers/`
- **Populators**: `app/strategies/import/phase5_populator.rb`
- **Committers**: `app/strategies/import/committers/main.rb`
- **Controllers**: `app/controllers/data_fix_controller.rb`
- **Views**: `app/views/data_fix/`
- **Specs**: `spec/strategies/import/` + `spec/requests/data_fix_controller_*.rb`

### Related Documentation
- [README.md](./README.md) - Main entry point
- [PHASES.md](./PHASES.md) - Phase 1-6 complete guide
- [TECHNICAL.md](./TECHNICAL.md) - Architecture patterns
- [DATA_STRUCTURES.md](./DATA_STRUCTURES.md) - Data format reference
- [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md) - Relay specifics
- [CHANGELOG.md](./CHANGELOG.md) - Version history

### Test Files
- Relay only: `crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json`
- Full meeting: Any file in `crawler/data/results.new/<season>/`

---

## 📈 Progress Tracking

### Sprint Velocity
- **Week 2025-11-04**: EventSolver + ResultSolver relay support (8 hours)
- **Week 2025-11-11**: RelayEnrichmentDetector + UI (12 hours)
- **Week 2025-11-18**: Phase 5 populator + UI (est. 8-10 hours)
- **Week 2025-11-25**: Phase 6 relay commits (est. 6-8 hours)

### Completion Metrics
- **Lines of Code**: ~2,500 (relay support)
- **Test Coverage**: 92% (solver/committer specs)
- **Documentation Pages**: 7 core docs + this roadmap
- **User-Facing Features**: 6 phases × 2 result types = 12 workflows

---

**Last Updated**: 2025-11-15 by Steve A. (Leega)  
**Next Review**: 2025-11-16 (after Phase 5 relay populator completion)  
**Status**: Active development - On track for full relay support by end of November 2025
