# Data-Fix Pipeline Documentation

**Last Updated**: 2025-11-15  
**Version**: 2.1 - Documentation Consolidation + UI Improvements

---

## 🎯 Quick Status

| Component | Status | Notes |
|-----------|--------|-------|
| **Phases 1-4** | ✅ Complete | Meeting, Teams, Swimmers, Events with relay support |
| **Phase 5 Individual** | ✅ Complete | Results display & DB population working |
| **Phase 5 Relay** | 🟡 In Progress | Enrichment ✅, Populator 🎯 next |
| **Phase 6 Individual** | ✅ Complete | Full commit to production DB |
| **Phase 6 Relay** | 🎯 Next | Needs commit methods (~6-8 hours) |

**Recent Achievements**:
- ✅ **2025-11-15**: Documentation reorganized (DATA_STRUCTURES + ROADMAP added)
- ✅ **2025-11-14**: Phase 3 relay enrichment fully working
- ✅ **2025-11-15**: UI standardization complete (borders, badges, icons)
- ✅ **2025-11-10**: Relay event recognition fixed (EventSolver + ResultSolver)

---

## 📚 Documentation Structure (NEW\!)

### 🔥 **Core Documentation** (Start Here)
```
docs/data_fix/
├── README.md (this file)           ← Main entry point & quick status
├── ROADMAP.md                      ← Active development plans & progress
├── PHASES.md                       ← Complete guide to all 6 phases
├── DATA_STRUCTURES.md              ← Data format reference (source → DB)
├── TECHNICAL.md                    ← Architecture patterns & technical details
├── RELAY_IMPLEMENTATION.md         ← Relay-specific implementation details
├── CHANGELOG.md                    ← Version history & major changes
├── plans/                          ← Archived plans (reference only)
│   └── archive/                    ← Historical plans
└── legacy_version/                 ← Historical v1.0 docs (reference only)
```

### 📖 What Each File Contains

| File | Purpose | When to Read |
|------|---------|--------------|
| **README.md** | Quick status, navigation, getting started | Always start here |
| **ROADMAP.md** | Active development plans & progress tracking | Current work status |
| **PHASES.md** | Complete guide to all 6 phases with examples | Understanding workflow |
| **DATA_STRUCTURES.md** | Data format reference (JSON, DB tables) | Working with data |
| **TECHNICAL.md** | Architecture, patterns, fuzzy matching, etc. | Deep technical details |
| **RELAY_IMPLEMENTATION.md** | Relay status across all phases + specifics | Working on relay support |
| **CHANGELOG.md** | What changed and when | Understanding history |

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
1. **Check [ROADMAP.md](./ROADMAP.md)** - Current milestone & tasks
2. **Read [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md)** - Technical details
3. **Reference [DATA_STRUCTURES.md](./DATA_STRUCTURES.md)** - Relay data formats

### Implementing a Phase?
- See the corresponding section in **[PHASES.md](./PHASES.md)**
- Check **[TECHNICAL.md](./TECHNICAL.md)** for patterns to follow
- Review specs in `spec/strategies/import/` and `spec/requests/data_fix_controller_*`

### Understanding Recent Changes?
- Read **[CHANGELOG.md](./CHANGELOG.md)** - Version history
- Check **[ROADMAP.md](./ROADMAP.md)** - Active sprint status

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

**Current Sprint**: Phase 5 Relay Populator (4-6 hours)

**To complete relay support** (~13-18 hours remaining):

### Priority 1: Phase 5 Relay Populator (4-6 hrs) 🔥
- Populate `data_import_meeting_relay_results` table
- Populate `data_import_relay_swimmers` (4 per result)
- Populate `data_import_relay_laps` (1+ per swimmer)
- Link to Phase 3 enriched swimmer data
- Handle LT4 format (LT2 support later)

### Priority 2: Phase 5 Relay UI (3-4 hrs)
- Create relay result card partials
- Add controller queries
- Test display with populated data

### Priority 3: Phase 6 Relay Commits (6-8 hrs)
- Implement `commit_meeting_relay_result`
- Implement `commit_relay_swimmers`
- Implement `commit_relay_laps`
- Add specs

👉 **See [ROADMAP.md](./ROADMAP.md)** for detailed breakdown and progress tracking.

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
- **Data formats?** → See [DATA_STRUCTURES.md](./DATA_STRUCTURES.md)
- **Architecture questions?** → See [TECHNICAL.md](./TECHNICAL.md)
- **Relay implementation?** → See [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md)
- **Current work status?** → Check [ROADMAP.md](./ROADMAP.md)
- **Historical context?** → See [legacy_version/](./legacy_version/) or [plans/archive/](./plans/archive/)
- **What changed when?** → See [CHANGELOG.md](./CHANGELOG.md)

---

## 📝 Documentation Evolution

### Phase 1: Initial Consolidation (2025-11-10)
**Before**: 22 markdown files scattered across `docs/data_fix/`  
**After**: 6 core documentation files + 3 active plans  
**Result**: Clearer navigation, less redundancy

### Phase 2: Structure Refinement (2025-11-15)
**Added**:
- `DATA_STRUCTURES.md` - Comprehensive data format reference
- `ROADMAP.md` - Single source of truth for active development

**Archived**:
- All completed/historical plan files → `plans/archive/`
- Kept only task-specific docs that are actively referenced

**Result**: Easy browsing for quick overview AND in-depth dive!\!

---

**Last Major Update**: 2025-11-15 - Documentation refinement + UI standardization  
**Contributors**: Steve A. (Leega)  
**Status**: Active development - Phase 5 relay populator next
