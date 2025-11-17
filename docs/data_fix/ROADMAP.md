# Data-Fix: Development Roadmap

**Last Updated**: 2025-11-17  
**Version**: 2.3  
**Status**: ✅ All Phases Complete | 🟡 Testing & Polish Ongoing

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
| **Phase 5 Relay** | ✅ Complete | 100% | Populator + UI + string keys |
| **Phase 5 Polish** | ✅ Complete | 100% | Pagination & filtering working |
| **Phase 6 Individual** | ✅ Complete | 100% | Full commit working |
| **Phase 6 Relay** | ✅ Complete | 100% | MRR/MRS/RelayLap commit implemented |
| **Testing** | 🟡 In Progress | 60% | Need Phase 5 relay specs |
| **Documentation** | 🟡 In Progress | 90% | Cleanup needed |

---

## 🎯 Current Sprint (2025-11-17)

### ✅ Recently Completed

- **Phase 6 Relay Commit** (2025-11-17) ✨ NEW
  - Full relay results commit to production tables
  - MRR → MeetingRelayResult
  - MRS → MeetingRelaySwimmer
  - RelayLap → RelayLap
  - UPDATE support for existing relays
  - INSERT for new relays
  - Complete SQL batch file generation
  - Cleanup of data_import relay tables after commit
  
- **Phase 5 Polish: Pagination & Filtering** (2025-11-17) ✨ NEW
  - Server-side filtering for programs with issues
  - Client-side row filtering within cards
  - Pagination (max 2500 rows per page)
  - Helper method refactoring (explicit parameters)
  - Phase 3 enrichment fix (only update existing swimmers)
  
- **Phase 5 Relay Populator** (2025-11-17)
  - Full relay results, swimmers, and laps population
  - String keys integration for unmatched entity referencing
  - MRR/MRS/RelayLap tables populated from source JSON
  - Import keys generated correctly
  
- **Phase 5 Relay UI** (2025-11-17)
  - Relay program cards with collapsible details
  - Auto-expand for results with missing data
  - Red border highlighting for problematic results
  - N+1 query fixes with eager loading
  - Swimmer keys displayed even when unmatched

### 🎯 Next Steps

#### 1. Testing (Priority)
**Goal**: Comprehensive RSpec coverage for Phase 5 relay workflow
- Make page limit configurable via constant

**Acceptance Criteria**:
- ✅ No page renders more than 500 result/lap rows
- ✅ Pagination controls work smoothly
- ✅ Page limit easily tweakable

#### 2. Phase 5 Filtering (NEXT UP)
**Goal**: Implement "Show only results with issues" filter toggle

**Requirements**:
- JavaScript toggle for checkbox
- Hide/show program cards based on has_issues flag
- Hide/show individual results based on missing data
- Smooth animations

**Acceptance Criteria**:
- ✅ Toggle works for both individual and relay results
- ✅ Only problematic results visible when checked
- ✅ All results visible when unchecked

#### 3. Documentation Consolidation (IN PROGRESS)
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

#### 4. Phase 6 Relay Commit (PLANNED)
**Goal**: Commit MRR/MRS/RelayLap from data_import_* tables to production

**Requirements**:
- `commit_meeting_relay_result` method
- `commit_relay_swimmers` method  
- `commit_relay_laps` method
- Transaction safety
- SQL log generation
- Error handling and rollback

**Acceptance Criteria**:
- ✅ All relay entities commit correctly
- ✅ SQL log generates properly
- ✅ Transaction rollback on any error
- ✅ No flash messages (use dedicated results page)

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

### Milestone 4: Phase 5 Relay Populator ✅ COMPLETE
**Duration**: 6 hours  
**Completed**: 2025-11-17

**Delivered**:
- ✅ Extract relay data from source JSON
- ✅ Populate `DataImportMeetingRelayResult` records
- ✅ Populate `DataImportRelaySwimmer` records (4 per result)
- ✅ Populate `DataImportRelayLap` records
- ✅ String keys for all data_import_* tables
- ✅ Import keys generate correctly
- ✅ Swimmer links resolve from phase3
- ✅ Timing data accurate (delta + cumulative)

**Result**: All relay data now flows from source → Phase 5 UI

### Milestone 5: Phase 5 Relay UI ✅ COMPLETE
**Duration**: 4 hours  
**Completed**: 2025-11-17

**Delivered**:
- ✅ `_relay_program_card.html.haml` partial
- ✅ Display team, timing, rank
- ✅ Show 4 swimmers with match status
- ✅ Expandable lap details with cumulative timing
- ✅ Auto-expand for problematic results
- ✅ Red border highlighting for missing data
- ✅ N+1 query fixes with eager loading
- ✅ Controller queries optimized

**Result**: Full relay UI with issue detection and highlighting

### Milestone 6: Phase 5 Polish 🎯 NEXT UP
**Estimate**: 3-4 hours  
**Dependencies**: Milestone 4 & 5 complete

**Tasks**:
1. **Pagination** (2 hours)
   - Add page parameter and calculation
   - Split programs when >500 rows
   - Add pagination UI
   - Make limit configurable
   
2. **Filter Toggle** (1 hour)
   - JavaScript show/hide logic
   - Filter by has_issues flag
   - Smooth animations
   
3. **Testing** (1 hour)
   - Test with large meetings
   - Verify filter works
   - Edge cases

**Acceptance Criteria**:
- ✅ Pages never exceed 500 rows
- ✅ Filter toggle works smoothly
- ✅ Performance acceptable

### Milestone 7: Phase 6 Relay Commit 🎯 PLANNED
**Estimate**: 8-10 hours  
**Dependencies**: Phase 5 complete

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
- ⚠️ **Pagination missing** - Large meetings may slow UI (needs 500-row limit)
- ⚠️ **Filter toggle incomplete** - UI skeleton present but JS not implemented
- ℹ️ **LT2 format support** - Only LT4 fully tested

### UI
- ℹ️ **Progress broadcasting** - Needs optimization for large datasets
- ℹ️ **Pagination** - Could be improved for phase 3 (1000+ swimmers)

### Documentation
- ⚠️ **Plan files scattered** - Being consolidated into ROADMAP.md
- ℹ️ **Code comments** - Some methods need better documentation

---

## 📝 Future Enhancements

### Short Term (Next 1-2 weeks)
- [ ] Phase 5 pagination and filtering (Milestone 6)
- [ ] Phase 6 relay commit support (Milestone 7)
- [ ] RSpec tests for Phase 5 relay populator
- [ ] Documentation cleanup and archiving
- [ ] LT2 format full support

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
