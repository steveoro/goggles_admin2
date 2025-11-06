# Data-Fix Phased Import Documentation

**Quick Start**: Read this first, then dive into specific topics as needed.

---

## 📚 Start Here

**New to the project?** → [Master Index](./data_fix_phases_master_index.md)  
**Need integration plan?** → [Phase 6 Integration](./phase6_integration_with_prematching.md)  
**Want to understand pre-matching?** → [Pre-Matching Pattern](./pre_matching_pattern_complete.md)

---

## 🎯 What is Phased Data-Fix?

A 6-phase import workflow that processes meeting results from PDF/JSON to production database:

1. **Phase 1**: Meeting metadata, sessions, pools, cities
2. **Phase 2**: Teams and affiliations (with pre-matching)
3. **Phase 3**: Swimmers and badges (with pre-matching + category calculation)
4. **Phase 4**: Meeting events (with pre-matching)
5. **Phase 5**: Individual results and laps (DB tables)
6. **Phase 6**: Commit to production + SQL generation

**Key Innovation (v2.0)**: Pre-matching pattern moves entity matching from commit time to phase building time, resulting in:
- 77% less code in commit layer
- 93% fewer database queries
- Early error detection
- Self-contained phase files

---

## 📖 Documentation Structure

### By Phase

| Phase | Overview | Details | Matching |
|-------|----------|---------|----------|
| 1 | [Master Index §Phase1](./data_fix_phases_master_index.md#phase-1-meeting--sessions) | [Status (Oct 6)](./phase1_status_20251006.md) | - |
| 2 | [Master Index §Phase2](./data_fix_phases_master_index.md#phase-2-teams--affiliations) | [Status](./phase2_status_20251006.md) | [Matching](./phase2_affiliation_matching.md) |
| 3 | [Master Index §Phase3](./data_fix_phases_master_index.md#phase-3-swimmers--badges) | - | [Matching](./phase3_badge_matching.md) |
| 4 | [Master Index §Phase4](./data_fix_phases_master_index.md#phase-4-meeting-events) | - | [Matching](./phase4_event_matching.md) |
| 5 | [Master Index §Phase5](./data_fix_phases_master_index.md#phase-5-results--laps) | [Completion Plan](./phase5_and_6_completion_plan.md) | - |
| 6 | [Master Index §Phase6](./data_fix_phases_master_index.md#phase-6-commit--sql-generation) | [Integration](./phase6_integration_with_prematching.md) | - |

### By Topic

**Architecture & Design**:
- [Master Index](./data_fix_phases_master_index.md) - Complete reference
- [Pre-Matching Pattern](./pre_matching_pattern_complete.md) - v2.0 enhancement
- [Phase 6 Integration](./phase6_integration_with_prematching.md) - Commit & SQL generation

**Implementation Details**:
- [Phase 2 Affiliation Matching](./phase2_affiliation_matching.md) - Simple 2-key matching
- [Phase 3 Badge Matching](./phase3_badge_matching.md) - Complex 3-key + calculation
- [Phase 4 Event Matching](./phase4_event_matching.md) - Standard 2-key with nesting

**Older Documents** (Historical Reference):
- [Phase 6 Implementation Plan (v1.0)](./phase6_implementation_plan.md) - Original design
- [Phase 5 & 6 Completion Plan](./phase5_and_6_completion_plan.md) - Hybrid architecture
- [Data-Fix Redesign (To-Do)](./data_fix_redesign_with_phase_split-to_do.md) - Original spec

**Supporting Documentation**:
- [Data Review and Linking](./legacy_version/data_review_and_linking.md) - User workflow
- [Data Commit and Push](./legacy_version/data_commit_and_push.md) - Deployment
- [PDF Processing](./pdf_processing.md) - Source extraction
- [AutoComplete Analysis](./data_fix_autocomplete_analysis.md) - UI components

---

## 🚀 Quick Reference

### For Developers

**Implementing a new phase?**
1. Read [Master Index](./data_fix_phases_master_index.md) for architecture
2. Study similar phase (e.g., Phase 2 for simple entities)
3. Follow pre-matching pattern if applicable

**Debugging an issue?**
1. Check [Master Index](./data_fix_phases_master_index.md) for data flow
2. Review phase-specific document for details
3. Check logs for matched vs. new status

**Adding a feature?**
1. Understand current architecture in [Master Index](./data_fix_phases_master_index.md)
2. Apply pre-matching pattern if matching entities
3. Update relevant phase documentation

### For Operators

**Using the import workflow?**
1. Follow [Data Review and Linking](./data_review_and_linking.md)
2. Each phase shows matched (green) vs. new (blue) entities
3. Fix issues during review, not at commit

**Something went wrong?**
1. Check which phase failed
2. Review phase-specific document for common issues
3. Look for warnings in logs about missing matches

---

## 📊 Current Status

### Implementation: ✅ Complete

- [x] Phase 1: Meeting/Sessions
- [x] Phase 2: Teams/Affiliations + Pre-matching
- [x] Phase 3: Swimmers/Badges + Pre-matching
- [x] Phase 4: Events + Pre-matching
- [x] Phase 5: Results/Laps (DB tables)
- [x] Phase 6: Committer + SQL generation

### Testing: 🚧 In Progress

- [x] Phase 1: Unit tests
- [ ] Phase 2-4: Unit tests (partial)
- [ ] Phase 5-6: Unit tests (to do)
- [ ] Integration: End-to-end tests (to do)
- [ ] Performance: Large dataset tests (to do)

### Production: 🎯 Ready with Feature Flag

- [x] Architecture complete
- [x] Pre-matching pattern proven
- [x] Documentation complete
- [ ] Feature flag needed for rollout
- [ ] Parallel testing with legacy system

---

## 🎓 Learning Path

### New Team Member

1. **Week 1**: Understand basics
   - Read [Master Index](./data_fix_phases_master_index.md) introduction
   - Review data flow diagram
   - Understand phase purposes

2. **Week 2**: Deep dive
   - Study [Pre-Matching Pattern](./pre_matching_pattern_complete.md)
   - Review implementation of Phase 2 (simplest)
   - Examine code in `/app/strategies/import/solvers/`

3. **Week 3**: Advanced topics
   - Read [Phase 6 Integration](./phase6_integration_with_prematching.md)
   - Understand Phase 5 hybrid storage
   - Review transaction and SQL generation

### Experienced Developer

**Need to**:
- **Add entity matching?** → Follow pattern in [Phase 2 Matching](./phase2_affiliation_matching.md)
- **Optimize performance?** → Review [Pre-Matching Pattern](./pre_matching_pattern_complete.md)
- **Understand commit flow?** → Read [Phase 6 Integration](./phase6_integration_with_prematching.md)
- **Fix a bug?** → Check [Master Index](./data_fix_phases_master_index.md) + phase docs

---

## 📁 File Organization

```
docs/
├── README_PHASES.md                              ← You are here
├── data_fix_phases_master_index.md              ← START HERE (comprehensive)
│
├── Phase-Specific Implementation
│   ├── phase2_affiliation_matching.md           ← Phase 2 matching
│   ├── phase3_badge_matching.md                 ← Phase 3 matching
│   ├── phase4_event_matching.md                 ← Phase 4 matching
│   └── phase5_and_6_completion_plan.md          ← Phase 5 + original 6 plan
│
├── Integration & Architecture
│   ├── phase6_integration_with_prematching.md   ← Phase 6 integration (v2.0)
│   ├── pre_matching_pattern_complete.md         ← Pre-matching deep dive
│   └── phase6_implementation_plan.md            ← Original plan (v1.0)
│
├── Supporting Docs
│   ├── data_review_and_linking.md               ← User workflow
│   ├── data_commit_and_push.md                  ← Deployment
│   ├── pdf_processing.md                        ← Source extraction
│   ├── data_fix_autocomplete_analysis.md        ← UI components
│   └── data_fix_lt4_adapter.md                  ← Format handling
│
└── Legacy (Historical)
    ├── data_fix_redesign_with_phase_split-to_do.md  ← Original spec
    └── data_fix_refactoring_and_enhancement.md  ← Early design
```

---

## 💡 Key Concepts

### Pre-Matching Pattern

**Core Idea**: Match entities during phase **building**, not during **commit**.

**Benefits**:
- Operators see status during review (green = exists, blue = new)
- Commit phase becomes trivial (just INSERT for new)
- No duplicate checks at commit time
- Better performance (queries cached in JSON)

**Where Applied**:
- Phase 2: TeamAffiliations
- Phase 3: Badges (+ category calculation)
- Phase 4: MeetingEvents

### Hybrid Storage

**Phases 1-4**: JSON files (small datasets, ~100s of records)  
**Phase 5**: DB tables (large datasets, ~1000s of records)  
**Phase 6**: Reads both sources

**Why?**
- JSON: Easy to review, version control, manual edit
- DB: Efficient for large datasets, supports pagination, indexed queries

### Guard Clauses

All matching logic uses guard clauses for graceful degradation:

```ruby
# Example from Phase 3
def build_badge_entry(...)
  badge = { 'swimmer_key' => key, ... }
  
  # Guard: skip matching if keys missing
  return badge unless swimmer_id && team_id
  
  # Proceed with matching
  existing = Badge.find_by(...)
  badge['badge_id'] = existing&.id
end
```

**Benefits**:
- No errors on partial data
- Progressive enhancement
- Clear logging of missing data

---

## 🔍 Common Questions

**Q: Why JSON files for phases 1-4?**  
A: Small datasets (~100s), easy to review/edit, human-readable, version-controllable.

**Q: Why DB tables for phase 5?**  
A: Large datasets (~1000s), efficient pagination, indexed lookups, relational queries.

**Q: What's the "pre-matching pattern"?**  
A: Match entities during phase building (early), not during commit (late). See [Pre-Matching Pattern](./pre_matching_pattern_complete.md).

**Q: How do I add matching for a new entity?**  
A: Follow the pattern from Phase 2 (simple) or Phase 3 (complex). See [Master Index §Pre-Matching](./data_fix_phases_master_index.md#pre-matching-pattern-complete-reference).

**Q: Can I update phase files manually?**  
A: Yes (phases 1-4), but use UI when possible. Phase 5 is read-only (DB tables).

**Q: How do I test my changes?**  
A: Unit tests for solvers, integration tests for full workflow. See [Master Index §Testing](./data_fix_phases_master_index.md#testing-status).

---

## 📞 Getting Help

1. **Check documentation**: Start with [Master Index](./data_fix_phases_master_index.md)
2. **Review code**: `/app/strategies/import/solvers/` and `/app/strategies/import/committers/`
3. **Check logs**: Look for `[<Phase>Solver]` and `[Main]` messages
4. **Ask team**: Reference specific documentation section when asking

---

**Last Updated**: 2025-11-03  
**Version**: 2.0 (Pre-Matching Enhancement)  
**Maintained By**: Project Team

---

**Navigation**: [↑ Back to Top](#data-fix-phased-import-documentation) | [Master Index](./data_fix_phases_master_index.md) | [Integration Plan](./phase6_integration_with_prematching.md)
