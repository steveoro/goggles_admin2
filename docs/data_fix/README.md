# Data-Fix Pipeline Documentation

**Last Updated**: 2025-11-10  
**Version**: 2.0 - Post-Consolidation & Relay Fixes

---

## 🎯 Quick Status

| Component | Status | Notes |
|-----------|--------|-------|
| **Phases 1-4** | ✅ Complete | Meeting, Teams, Swimmers, Events with relay support |
| **Phase 5 Individual** | ✅ Complete | Results display & DB population working |
| **Phase 5 Relay** | 🟡 In Progress | EventSolver ✅, ResultSolver ✅, Populator 🎯 next |
| **Phase 6 Individual** | ✅ Complete | Full commit to production DB |
| **Phase 6 Relay** | 🎯 Next | Needs commit methods (~6-8 hours) |

**Recent Achievements**:
- ✅ **2025-11-10**: Relay event recognition fixed (EventSolver + ResultSolver)
- ✅ **2025-11-10**: Documentation consolidated (22 files → 6 core docs)

---

## 📚 Documentation Structure (NEW\!)

### 🔥 **Core Documentation** (Start Here)
```
docs/data_fix/
├── README.md (this file)           ← Main entry point
├── PHASES.md                       ← Complete guide to all 6 phases
├── TECHNICAL.md                    ← Architecture patterns & technical details
├── RELAY_IMPLEMENTATION.md         ← Active relay work status & roadmap
├── CHANGELOG.md                    ← Version history & major changes
├── plans/                          ← Active implementation plans (3 files)
│   ├── PHASE6_RELAY_COMPLETION_ROADMAP.md
│   ├── phase5_and_6_completion_plan.md
│   └── FIXES_progress_and_relay_events.md
└── legacy_version/                 ← Historical v1.0 docs (reference only)
```

### 📖 What Each File Contains

| File | Purpose | When to Read |
|------|---------|--------------|
| **README.md** | Quick status, navigation, getting started | Always start here |
| **PHASES.md** | Complete guide to all 6 phases with examples | Understanding workflow |
| **TECHNICAL.md** | Architecture, patterns, fuzzy matching, etc. | Deep technical details |
| **RELAY_IMPLEMENTATION.md** | Relay status across all phases + TODO items | Working on relay support |
| **CHANGELOG.md** | What changed and when | Understanding history |
| **plans/** | Active roadmaps (work in progress) | Current implementation work |

---

## 🚀 What is Data-Fix?

A **6-phase pipeline** that transforms meeting results from JSON files into production database records with full SQL logging.

### The 6 Phases

1. **Phase 1: Meeting & Sessions** - Import meeting metadata, sessions, venues
2. **Phase 2: Teams** - Match teams with fuzzy logic, create affiliations
3. **Phase 3: Swimmers & Badges** - Match swimmers, calculate categories, enrich relays
4. **Phase 4: Events** - Match event types, create meeting events (individual + relay)
5. **Phase 5: Results & Laps** - Populate temporary DB tables, display review UI
6. **Phase 6: Commit** - Atomic commit to production with SQL generation

### Key Innovations

**Pre-Matching Pattern** (v2.0):
- Entity matching happens during phase building (not at commit time)
- Each phase file contains all resolved IDs
- 77% less commit code, 93% fewer DB queries
- Early error detection

**Hybrid Storage**:
- Phases 1-4: JSON files (small datasets)
- Phase 5: DB tables (large datasets - results/laps)
- Phase 6: Production commit from both sources

**Relay Support** (v2.1):
- Relay-only file detection
- Gender-based event grouping (F, M, X)
- Italian title parsing: "4x50 m Misti" → EventType
- Full relay swimmer + lap tracking

---

## 🎓 Getting Started

### New to the Project?
1. **Read [PHASES.md](./PHASES.md)** - Understand the 6-phase workflow
2. **Review [TECHNICAL.md](./TECHNICAL.md)** - Learn the architecture patterns
3. **Check [plans/](./plans/)** - See what's actively being developed

### Working on Relay Support?
1. **Read [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md)** - Current status
2. **Follow [plans/PHASE6_RELAY_COMPLETION_ROADMAP.md](./plans/PHASE6_RELAY_COMPLETION_ROADMAP.md)** - Step-by-step plan

### Implementing a Phase?
- See the corresponding section in **[PHASES.md](./PHASES.md)**
- Check **[TECHNICAL.md](./TECHNICAL.md)** for patterns to follow
- Review specs in `spec/strategies/import/` and `spec/requests/data_fix_controller_*`

### Understanding Recent Changes?
- Read **[CHANGELOG.md](./CHANGELOG.md)** - Version history
- Check **[plans/FIXES_progress_and_relay_events.md](./plans/FIXES_progress_and_relay_events.md)** - Latest fixes

---

## 🔍 Quick Reference

### File Locations

**Controllers**: `app/controllers/data_fix_controller.rb`  
**Solvers**: `app/strategies/import/solvers/`
- `event_solver.rb` - Phase 4 events (relay support ✅)
- `result_solver.rb` - Phase 5 results (relay support ✅)
- `team_solver.rb` - Phase 2 teams
- `swimmer_solver.rb` - Phase 3 swimmers

**Committers**: `app/strategies/import/committers/main.rb`  
**Populators**: `app/strategies/import/phase5_populator.rb`  
**Views**: `app/views/data_fix/`  
**Specs**: `spec/requests/data_fix_controller_*.rb`

### Key Concepts

**Phase Files**: JSON files stored in `crawler/data/results.new/<season_id>/`
- `<filename>-phase1.json` - Meeting data
- `<filename>-phase2.json` - Teams
- `<filename>-phase3.json` - Swimmers & badges
- `<filename>-phase4.json` - Events
- Phase 5 uses DB tables (`data_import_*`)

**Import Keys**: Unique identifiers for matching
- Format: `"MEETING-SESSION-EVENT-SWIMMER"` or similar
- Used for O(1) lookups in temporary tables

**Fuzzy Matching**: Levenshtein-based string similarity
- Teams: 60% threshold for auto-assignment
- Swimmers: Similar threshold with year-of-birth weighting

---

## �� Current Architecture

```
Source JSON (LT4 Microplus format)
    ↓
┌─────────────────────────────────────┐
│ Phase 1: Meeting/Sessions           │
│ → phase1.json (with IDs)            │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 2: Teams                      │
│ → phase2.json (team_id, affil_id)  │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 3: Swimmers & Badges          │
│ → phase3.json (swimmer_id, badge)   │
│   ↑ loads phase1 (meeting date)    │
│   ↑ loads phase2 (team_id)          │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 4: Events (✅ Relay Support)  │
│ → phase4.json (event_type_id)       │
│   ↑ loads phase1 (session_id)       │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 5: Results (🟡 Relay Pending) │
│ → data_import_* DB tables           │
│   ↑ loads phases 1-4 for all IDs    │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 6: Commit to Production       │
│ → Production DB + SQL log           │
│   ↑ reads JSON (1-4) + DB (5)       │
└─────────────────────────────────────┘
```

---

## 🎯 Next Immediate Actions

**⚠️ BLOCKER FOUND (2025-11-10)**: Phase5Populator only handles LT4 format. Test relay file is LT2!

**To complete relay support** (~19-26 hours total):

### Priority 1: Phase5Populator LT2+LT4 Support (10-14 hrs) 🔥
**Start Here**: Remove "Use Legacy" buttons (30 min quick win)

**Then implement**:
1. Format detection (LT2 vs LT4)
2. LT2 individual result population
3. LT2 relay result population
4. LT4 relay result population (remove skip)

👉 **Detailed Plan**: [plans/PHASE5_LT2_LT4_SUPPORT_PLAN.md](./plans/PHASE5_LT2_LT4_SUPPORT_PLAN.md)  
👉 **Daily Tracker**: [plans/DAILY_PROGRESS.md](./plans/DAILY_PROGRESS.md)

### Priority 2: Phase 5 Relay UI (3-4 hrs)
- Create relay result card partials
- Add controller queries
- Test display with populated data

### Priority 3: Phase 6 Relay Commits (6-8 hrs)
- Implement `commit_meeting_relay_result`
- Implement `commit_relay_swimmers`
- Implement `commit_relay_laps`
- Add specs

See **[plans/PHASE6_RELAY_COMPLETION_ROADMAP.md](./plans/PHASE6_RELAY_COMPLETION_ROADMAP.md)** for Phase 6 details.

---

## 🧪 Testing

### Run All Specs
```bash
# Solver specs
bundle exec rspec spec/strategies/import/solvers/

# Controller specs (phases 1-3)
bundle exec rspec spec/requests/data_fix_controller_phase*.rb

# Committer specs
bundle exec rspec spec/strategies/import/committers/
```

### Test with Real Data
```bash
# Use the browser UI
rails server
# Navigate to /data_fix/add_session
# Upload a JSON file and step through phases

# Or use rails console
season = GogglesDb::Season.find(242)
solver = Import::Solvers::EventSolver.new(season: season)
solver.build\!(source_path: 'path/to/file.json', lt_format: 4)
```

### Relay Test File
**Location**: `crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json`

**Expected Results**:
- Phase 4: 1 session, 3 events (F, M, X)
- All events matched to EventType with `relay: true`
- Event codes: `S4X50MI` (same-gender), `M4X50MI` (mixed)

---

## 📞 Need Help?

- **Understanding a phase?** → See [PHASES.md](./PHASES.md)
- **Architecture questions?** → See [TECHNICAL.md](./TECHNICAL.md)
- **Relay implementation?** → See [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md)
- **Current work status?** → Check [plans/](./plans/)
- **Historical context?** → See [legacy_version/](./legacy_version/)
- **What changed when?** → See [CHANGELOG.md](./CHANGELOG.md)

---

## 📝 Documentation Consolidation (2025-11-10)

**Before**: 22 markdown files scattered across `docs/data_fix/`  
**After**: 6 core documentation files + 3 active plans

**Deleted** (merged into core docs):
- README_PHASES.md, README_CURRENT_STATUS.md → README.md
- data_fix_phases_master_index.md → PHASES.md  
- phase2_affiliation_matching.md → PHASES.md (Phase 2 section)
- phase3_badge_matching.md → PHASES.md (Phase 3 section)
- phase4_event_matching.md → PHASES.md (Phase 4 section)
- phase6_integration_with_prematching.md, pre_matching_pattern_complete.md → TECHNICAL.md
- phase3_relay_enrichment_task_list.md, phase5_relay_display_task_list.md, phase6_relay_commit_task_list.md → RELAY_IMPLEMENTATION.md
- phase6_implementation_complete.md, phase6_implementation_plan.md, HOWTO_phase6_commit.md → PHASES.md + CHANGELOG.md
- data_fix_redesign_with_phase_split-to_do.md, data_fix_refactoring_and_enhancement.md → Obsolete
- data_fix_autocomplete_analysis.md, data_fix_lt4_adapter.md → TECHNICAL.md (if relevant)

**Result**: Clearer navigation, less redundancy, easier maintenance\!

---

**Last Major Update**: 2025-11-10 - Documentation consolidation + relay recognition fixes  
**Contributors**: Steve A. (Leega)  
**Status**: Active development - Phase 6 relay support in progress
