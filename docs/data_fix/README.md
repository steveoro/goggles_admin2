# Data-Fix Pipeline Documentation

## 📚 Documentation Structure

### 🔥 **Core Documentation** (Start Here)
```
docs/data_fix/
├── README.md (this file)           ← Main entry point & quick status
├── PHASES.md                       ← Complete guide to all 6 phases
├── DATA_STRUCTURES.md              ← Data format reference (source → DB)
├── TECHNICAL.md                    ← Architecture patterns & technical details
└── legacy_version/                 ← Historical v1.0 docs (reference only)
```

### 📖 What Each File Contains

| File | Purpose | When to Read |
|------|---------|--------------|
| **README.md** | Quick status, navigation, getting started | Always start here |
| **PHASES.md** | Complete guide to all 6 phases with examples | Understanding workflow |
| **DATA_STRUCTURES.md** | Data format reference (JSON, DB tables) | Working with data |
| **TECHNICAL.md** | Architecture, patterns, fuzzy matching, etc. | Deep technical details |

---

## 🚀 What is Data-Fix?

A **6-phase pipeline** that transforms meeting results from JSON files into production database records with full SQL logging.

The phase is needed to fix data inconsistencies and missing records from the imported data (both manually and semi-automatically).

The pipeline is divided in stages so that each phase consolidates the data needed by the next phase and so that each phase can be validated independently.

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

## 🔍 Quick Reference

### Key Concepts

**Phase Files**: JSON files stored in `crawler/data/results.new/<season_id>/`
- `<filename>-phase1.json` - Meeting data
- `<filename>-phase2.json` - Teams
- `<filename>-phase3.json` - Swimmers & badges
- `<filename>-phase4.json` - Events
- Phase 5 uses DB tables (`data_import_*`)

**Import Keys**: Unique identifiers for matching
- Format: `"PARENT_ENTITY_KEY-CHILD_ENTITY_KEY"` or similar, depending on hierarchy level (each child entity should have a unique key in any case)
- Used for O(1) lookups in temporary tables

**Fuzzy Matching**: Levenshtein-based string similarity
- Teams: 60% threshold for auto-assignment
- Swimmers: Similar threshold with year-of-birth weighting

---

## Current Architecture

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
│ → phase2.json (team_id, affil_id)   │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 3: Swimmers & Badges          │
│ → phase3.json (swimmer_id, badge)   │
│   ↑ loads phase1 (meeting date)     │
│   ↑ loads phase2 (team_id)          │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 4: Events                     │
│ → phase4.json (event_type_id)       │
│   ↑ loads phase1 (session_id)       │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 5: Results                    │
│ → data_import_* DB tables           │
│   ↑ loads phases 1-4 for all IDs    │
└───────────┬─────────────────────────┘
            ↓
┌─────────────────────────────────────┐
│ Phase 6: Commit to database         │
│ → creates an uploadable SQL log     │
│   ↑ reads JSON (1-4) + DB (5)       │
└─────────────────────────────────────┘
```

Data is imported on remote production server by sending the generated SQL log using the dedicated Goggles API endpoint (through the "PUSH" action on the Admin2 UI)

---
