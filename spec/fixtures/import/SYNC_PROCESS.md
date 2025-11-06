# Test Fixture Synchronization Process

## Why Synchronization is Needed

The test database uses **anonymized data** (FFaker-generated names) while production phase files contain real entity names. This mismatch causes test failures.

## The Problem

```ruby
# Production fixture (before sync):
"last_name": "ROSSI",
"first_name": "Paolo",
"swimmer_id": 32608

# Test database:
Swimmer(32608) => "Rowe Jennifer 4643"

# Result: Mismatch → Test failures ❌
```

## The Solution

The sync task replaces fixture data with test DB values:

```ruby
# After sync:
"last_name": "Rowe",
"first_name": "Jennifer",  
"swimmer_id": 32608
"complete_name": "Rowe Jennifer 4643"

# Now matches test DB → Tests pass ✅
```

---

## How to Sync Fixtures

### ⚠️ CRITICAL Requirements

1. **Must run in test environment** - `RAILS_ENV=test`
2. **Must use actual files** - No symlinks!
3. **Must run BOTH tasks** - sync AND anonymize
4. **Must be re-run** if test DB dump updates

### Complete Workflow

```bash
# Step 1: Sync with test database (updates names, IDs, fuzzy_matches)
RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb

# Step 2: Anonymize keys for privacy compliance (updates swimmer keys)
RAILS_ENV=test bundle exec rake fixtures:anonymize_keys
```

**Why two tasks?**
- **sync_with_testdb**: Updates entity attributes (names, birth years, etc.) to match anonymized DB values
- **anonymize_keys**: Updates the keys that reference those entities, ensuring NO real names appear anywhere

This two-step process ensures complete anonymization for public GitHub publication.

### Options

```bash
# Pattern matching (default: 200RA)
RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb fixture_pattern=100SL

# Dry run (see changes without writing)
RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb dry_run=true

# Custom directory
RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb fixture_dir=spec/fixtures/custom
```

---

## What the Sync Does

### For Each Entity with an ID

**1. ID Exists in Test DB** → Update attributes + Clear fuzzy_matches
```json
// Before:
{
  "swimmer_id": 32608,
  "last_name": "ROSSI",
  "first_name": "Paolo",
  "fuzzy_matches": [
    { "id": 32608, "complete_name": "ROSSI PAOLO", ... },
    { "id": 12345, "complete_name": "ROSSI MARIO", ... }
  ]
}

// After:
{
  "swimmer_id": 32608,
  "last_name": "Rowe",
  "first_name": "Jennifer",
  "fuzzy_matches": []  ← Cleared (already matched)
}
```

**2. ID NOT in Test DB** → Clear ID + Remove fuzzy_matches
```json
// Before:
{
  "badge_id": 999999,
  "swimmer_id": 123,
  "team_id": 456,
  "fuzzy_matches": [
    { "id": 111, "name": "Match A", "percentage": 95.5 },
    { "id": 222, "name": "Match B", "percentage": 89.2 },
    { "id": 333, "name": "Match C", "percentage": 82.1 }
  ]
}

// After:
{
  "badge_id": null,  ← Cleared
  "swimmer_id": 123,
  "team_id": 456,
  "fuzzy_matches": []  ← Cleared (production IDs meaningless in test context)
}
```

**Why remove all fuzzy_matches?**
- Production DB IDs in fuzzy_matches are meaningless in test database context
- Keeps fixtures clean and focused on test data only
- Further reduces file size for faster git operations

### Entities Processed

**sync_with_testdb:**
- **Phase 1**: Meeting, MeetingSessions
- **Phase 2**: Teams, TeamAffiliations  
- **Phase 3**: Swimmers, Badges
- **Phase 4**: MeetingEvents
- **Phase 5**: Skipped (uses DataImport models)

**anonymize_keys:**
- **Phase 3 only**: Swimmer keys and badge swimmer_key references
- **Matched swimmers**: Keys built from DB values
  - Example: `ROSSI|Paolo|1984` → `ROWE|Jennifer|1951`
- **Unmatched swimmers**: Keys and complete_name built with FFaker last_name
  - Example key: `MAZZANTI VIENDALMARE|Lacontessa|1975` → `SAWAYN|Roberta|1975`
  - Example complete_name: `MAZZANTI VIENDALMARE LACONTESSA` → `Sawayn Roberta`
  - Ensures full anonymization (no real names in keys or complete_name)

---

## Last Sync Results

**Date**: 2025-11-03 15:14  
**Environment**: test  
**Database**: goggles_test

```
Total entities: 874
Found in DB:    306 (35%) - Updated with anonymized data
Not found:      568 (65%) - IDs cleared for creation
```

### Why So Many Cleared?

The test database dump is older and smaller than production. Many entities from recent seasons don't exist in the test DB, so their IDs are cleared. This is **expected and correct**.

---

## Troubleshooting

### Files Not Updated

**Problem**: Ran sync but files unchanged

**Solution**: 
```bash
# Check you used RAILS_ENV=test
echo $RAILS_ENV  # Should be "test"

# Run with explicit env
RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb
```

### Symlinks Keep Appearing

**Problem**: Finding symlinks in fixtures directory

**Solution**:
```bash
# Remove all symlinks
find spec/fixtures/import -type l -delete

# Copy actual files (not symlinks)
cp crawler/data/results.new/242/*200RA*.json spec/fixtures/import/

# Clean up duplicates
rm -f spec/fixtures/import/*'(copy)'*.json
rm -f spec/fixtures/import/*-old.json
rm -f spec/fixtures/import/*-edited.json
```

### Tests Still Failing

**Problem**: Tests fail after sync

**Causes**:
1. Not running tests in development env (they need production/development DB)
2. Fixtures not synced recently
3. Test DB dump updated (re-sync needed)

**Solution**:
```bash
# 1. Re-sync fixtures
RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb

# 2. Run tests normally (development env)
bundle exec rspec spec/strategies/import/committers/phase_committer_integration_spec.rb
```

---

## For CI/CD

Add to your test setup:

```yaml
# .github/workflows/test.yml
- name: Sync test fixtures
  run: RAILS_ENV=test bundle exec rake fixtures:sync_with_testdb
  
- name: Run tests
  run: bundle exec rspec
```

---

## Important Notes

⚠️ **The sync modifies fixture files** - Commit the synced versions to git

⚠️ **Re-sync after test DB updates** - When the test dump is regenerated

⚠️ **Cleared IDs are normal** - They will be created as new entities in tests

✅ **Anonymization is intentional** - Protects real user data

✅ **Works with any phase files** - Not limited to 200RA

---

**Created**: 2025-11-03  
**Purpose**: Document fixture synchronization for test database compatibility
