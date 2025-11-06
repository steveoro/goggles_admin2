# Test Fixtures for Phase Import

This directory contains real, reviewed phase files from a small event (200RA) **synchronized with the anonymized test database**.

## Files

- **sample-200RA-l4.json** - Source L4 format file (294KB)
- **sample-200RA-l4-phase1.json** - Meeting & sessions (6.4KB)  
- **sample-200RA-l4-phase2.json** - Teams & affiliations (190KB) ✨ optimized
- **sample-200RA-l4-phase3.json** - Swimmers & badges (160KB) ✨ optimized
- **sample-200RA-l4-phase4.json** - Meeting events (971 bytes)
- **sample-200RA-l4-phase5.json** - Individual results (4.1KB)

### Optimization Results
- **Phase 2**: Reduced from 640KB → 190KB (~70% smaller) 🎉
- **Phase 3**: Reduced from 286KB → 160KB (~44% smaller) 🎉
- **Total**: Reduced from 926KB → 350KB (~62% smaller) 🎉

**Optimization Methods:**
1. Cleared `fuzzy_matches` for matched entities (already in DB)
2. Cleared `fuzzy_matches` for unmatched entities (production IDs meaningless in test context)
3. Updated `complete_name` for unmatched swimmers to match anonymized values

## ⚠️ Critical: Database Synchronization

These fixtures **MUST** be synchronized with the test database before use.

### Complete Workflow (REQUIRED)

**Step 1: Sync with Test DB**
```bash
# MUST run in test environment!
RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb
```
- Replaces entity attributes (names, etc.) with test DB anonymized values
- Clears IDs that don't exist in test DB
- Clears/optimizes fuzzy_matches arrays

**Step 2: Anonymize Keys (Privacy Compliance)**
```bash
# MUST run AFTER sync, in test environment!
RAILS_ENV=test bundle exec rake fixtures:anonymize_keys
```
- Updates swimmer keys to match anonymized names
- Ensures NO real personal names in public fixtures
- Updates all key references in badges

### Last Sync Results
```
Total entities: 874
Found in DB:    306 (updated with anonymized data)
Not found:      568 (IDs cleared - will be created as new)
```

This ensures:
- ✅ All entity names are **anonymized** (FFaker-generated) 
- ✅ No ID mismatches or conflicts
- ✅ Tests work reliably with test DB dump

## Purpose

These fixtures provide **real, production-like data** for testing:
- Main integration tests
- Solver unit tests  
- End-to-end workflow tests

## Data Characteristics

**Meeting**: Campionati Italiani di Nuoto Master Herbalife 2025  
**Season**: 242  
**Event**: 200m Backstroke (200RA)  
**Size**: Small (single event, ~70 results)

### Pre-Matched IDs

Phase 2, 3 files contain pre-matched database IDs:
- **Phase 2**: `team_id`, `team_affiliation_id`
- **Phase 3**: `swimmer_id`, `badge_id`, `category_type_id` (some)
- **Phase 4**: Event structure (meeting_event_id not always present in these fixtures)

## Usage in Tests

```ruby
let(:fixture_base) { 'sample-200RA-l4' }
let(:source_path) { Rails.root.join('spec', 'fixtures', 'import', "#{fixture_base}.json").to_s }
let(:phase1_path) { Rails.root.join('spec', 'fixtures', 'import', "#{fixture_base}-phase1.json").to_s }
# ... etc
```

## ⚠️ Important: No Symlinks!

**Do NOT use symlinks** in this directory. The sync task will skip them, and they will become stale when source files are moved/processed.

Always use **direct copies** of the actual phase files.

## Source

Copied from `/home/steve/Projects/goggles_admin2/crawler/data/results.new/242/`  
**Date**: 2025-11-03  
**Last synced**: 2025-11-03 15:14 (test environment)

## Maintenance

These are **static fixtures** - they won't change with code updates.  
If the phase JSON structure changes significantly, these files should be regenerated using the latest solvers.

---

**Created**: 2025-11-03  
**Purpose**: Testing pre-matching pattern and Main integration
