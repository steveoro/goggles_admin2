# Phase 3 Relay Enrichment - Task List & Status

**Date Created**: 2025-11-08  
**Feature**: Phase 3 relay swimmer enrichment workflow for incomplete Microplus relay data

---

## Overview

This feature detects incomplete relay swimmer data (missing `year_of_birth`, `gender_type_code`, or unmatched `swimmer_id`) from Microplus layout-4 relay results and provides an inline UI to merge data from auxiliary Phase 3 files to fill in missing attributes.

---

## Implementation Status

### ✅ Completed Components

#### 1. Services Layer
- [x] **Phase3::RelayEnrichmentDetector** (`app/services/phase3/relay_enrichment_detector.rb`)
  - Scans raw Microplus relay JSON and Phase 3 swimmers
  - Identifies incomplete relay legs (missing year, gender, or swimmer_id)
  - Returns summary with issue counts per relay
  - Matches relay swimmers to Phase 3 swimmer keys

- [x] **Phase3::RelayMergeService** (`app/services/phase3/relay_merge_service.rb`)
  - Merges swimmers from auxiliary Phase 3 files
  - Merges badges from auxiliary Phase 3 files
  - Tracks stats: swimmers_added, swimmers_updated, badges_added
  - Maintains unique badge signatures

#### 2. Controller Layer
- [x] **DataFixController#review_swimmers** (lines 134-220)
  - Integrated RelayEnrichmentDetector
  - Exposes `@relay_enrichment_summary` for view
  - Exposes `@auxiliary_phase3_files` (glob for `*-phase3*.json`)
  - Exposes `@selected_auxiliary_phase3_files` from metadata

- [x] **DataFixController#merge_phase3_swimmers** (lines 801-888)
  - POST action to merge auxiliary Phase 3 files
  - Validates file existence and paths
  - Uses RelayMergeService for merge
  - Clears downstream phase data (Phase 4+)
  - Persists auxiliary paths to metadata
  - Flash stats and warnings

- [x] **Controller param updates**
  - Changed from `swimmer_index` to `swimmer_key` for update/delete actions
  - Maintains pagination and filter params on redirects

#### 3. View Layer
- [x] **Review Swimmers V2** (`app/views/data_fix/review_swimmers_v2.html.haml` lines 18-23)
  - Conditionally renders relay enrichment accordion when summary present

- [x] **Relay Enrichment Panel Partial** (`app/views/data_fix/_relay_enrichment_panel.html.haml`)
  - Accordion UI with collapse/expand
  - Missing totals summary with badges
  - Auxiliary file multi-select dropdown
  - Scan & merge button with confirmation
  - Table showing relays with incomplete swimmers
  - Per-leg issue breakdown with color-coded badges

- [x] **Swimmer Form Card** (`app/views/data_fix/_swimmer_form_card.html.haml`)
  - Fixed badge color logic to handle missing `color_class`

#### 4. Localization
- [x] **English** (`config/locales/data_import.en.yml` lines 83-123)
- [x] **Italian** (`config/locales/data_import.it.yml` lines 83-123)
- Translation keys for:
  - UI labels and descriptions
  - Table headers
  - Field labels and hints
  - Status messages
  - Error messages
  - Success messages

#### 5. Documentation
- [x] **Phase 6 Implementation Doc** (`docs/data_fix/phase6_implementation_complete.md`)
  - Added relay enrichment workflow summary (line 165)
  - Referenced new files and specs

#### 6. Routes
- [x] **POST route** for `merge_phase3_swimmers` (via `match` directive)

---

### ❌ Known Issues & Failures

#### Issue #1: RelayMergeService Not Merging Gender Correctly
**Status**: 🔴 BROKEN  
**Failing Specs**:
- `spec/requests/data_fix_controller_phase3_spec.rb:406` - renders relay enrichment panel
- `spec/requests/data_fix_controller_phase3_spec.rb:445` - merges swimmers and badges

**Problem**:
```ruby
# Expected: merged_swimmer['gender_type_code'] == 'M'
# Actual: merged_swimmer['gender_type_code'] == nil
```

**Root Cause Analysis**:
The `copy_gender_if_missing` method in `RelayMergeService` (line 94-98) checks:
```ruby
def copy_gender_if_missing(target, source)
  return false unless target['gender_type_code'].to_s.strip.empty? && source['gender_type_code'].present?
  
  target['gender_type_code'] = source['gender_type_code']
  true
end
```

**Investigation**:
- Rails runner test shows year_of_birth IS merged (1980) but gender_type_code is NOT
- The conditional `target['gender_type_code'].to_s.strip.empty?` should work for nil values
- Need to verify source data in test setup has gender_type_code set

**Likely Fix**:
Check test setup in spec - ensure auxiliary swimmer hash actually contains `'gender_type_code' => 'M'` not just in the merge call but also in the PhaseFileManager write.

#### Issue #2: Relay Enrichment Panel Not Rendering in Spec
**Status**: 🔴 BROKEN  
**Failing Spec**: `spec/requests/data_fix_controller_phase3_spec.rb:406`

**Problem**:
```ruby
expect(response.body).to include(I18n.t('data_import.relay_enrichment.title'))
# Expected Italian: "Arricchimento staffette (Phase 3)"
# Body contains: Phase 3 metadata, swimmers, but no relay panel
```

**Investigation**:
- Debug HTML saved to `/tmp/relay_panel.html` shows relay panel IS rendered
- Panel shows 1 relay with incomplete swimmer
- Panel shows "Arricchimento staffette (Phase 3)" title

**Likely Fix**:
Spec expectation might be using wrong locale or there's a timing issue. The HTML output shows the panel exists, so this might be a false negative or locale mismatch.

---

### 🟡 Incomplete/Missing Components

#### 1. Request Specs Coverage Gaps
- [ ] Add spec for multiple relays with different issue types
- [ ] Add spec for no auxiliary files found (warning message)
- [ ] Add spec for invalid auxiliary file paths
- [ ] Add spec for JSON parse errors in auxiliary files
- [ ] Add spec for merge with no matching swimmers (no changes)
- [ ] Add spec for auxiliary path persistence and reload

#### 2. Service Specs
- [ ] **RelayEnrichmentDetector** unit specs
  - Parsing lap references with pipe-delimited swimmer data
  - Matching by name only when year missing
  - Issue detection logic (missing year, gender, swimmer_id)
  - Edge cases: empty sections, no relay rows, malformed data

- [ ] **RelayMergeService** unit specs
  - Swimmer merge with various missing attributes
  - Badge deduplication logic
  - Fuzzy match merging
  - Stats tracking accuracy
  - Deep dup behavior

#### 3. Integration Testing
- [ ] End-to-end workflow test with real Microplus JSON sample
- [ ] Test with multiple auxiliary files
- [ ] Test downstream clearing on merge
- [ ] Verify metadata persistence across page reloads

#### 4. Error Handling
- [ ] Handle corrupt JSON in auxiliary files gracefully
- [ ] Handle missing source file during merge
- [ ] Handle race conditions (file deleted between scan and merge)
- [ ] Validate auxiliary file schema matches Phase 3 structure

#### 5. UI Polish
- [ ] Test UI rendering with 0, 1, 10, 100+ incomplete relays
- [ ] Verify pagination doesn't break accordion state
- [ ] Test auxiliary file selection with long file names
- [ ] Verify responsive layout on mobile

---

## Action Plan to Fix Issues

### Priority 1: Fix RelayMergeService Gender Bug
**Owner**: Next session  
**Estimated Time**: 30 minutes

**Steps**:
1. Add debug logging to `copy_gender_if_missing` method
2. Verify test setup in `spec/requests/data_fix_controller_phase3_spec.rb:445`
   - Confirm auxiliary_data hash has `'gender_type_code' => 'M'`
   - Confirm main_data swimmer has `'gender_type_code' => nil`
3. Add unit spec for RelayMergeService to isolate the issue
4. Fix logic if needed (might need to handle edge case)
5. Re-run failing specs

### Priority 2: Fix Relay Panel Rendering Spec
**Owner**: Next session  
**Estimated Time**: 15 minutes

**Steps**:
1. Review `/tmp/relay_panel.html` debug output
2. Verify locale in test environment (should be Italian)
3. Check if I18n.t is using correct locale in spec
4. Update expectation if needed
5. Remove debug file writes from spec

### Priority 3: Add Unit Specs
**Owner**: Next session  
**Estimated Time**: 2 hours

**Steps**:
1. Create `spec/services/phase3/relay_enrichment_detector_spec.rb`
2. Create `spec/services/phase3/relay_merge_service_spec.rb`
3. Cover happy path and edge cases
4. Verify all methods have coverage

### Priority 4: Integration & Polish
**Owner**: Future session  
**Estimated Time**: 3 hours

**Steps**:
1. Add end-to-end workflow spec
2. Test UI rendering variations
3. Add error handling coverage
4. Update documentation with examples

---

## Testing Checklist

### Manual Testing Steps
- [ ] Create meeting with Microplus relay results (layout-4)
- [ ] Run Phase 1 (sessions)
- [ ] Run Phase 2 (teams)
- [ ] Run Phase 3 (swimmers) - verify relay panel appears
- [ ] Create auxiliary Phase 3 file with complete swimmer data
- [ ] Select auxiliary file in dropdown
- [ ] Click "Scan & merge"
- [ ] Verify flash message shows merge stats
- [ ] Verify relay panel disappears or shows resolved issues
- [ ] Verify auxiliary paths persisted in metadata
- [ ] Navigate away and back - verify auxiliary selection remembered
- [ ] Proceed to Phase 4 - verify no errors

### Automated Testing
- [ ] Run `bundle exec rspec spec/requests/data_fix_controller_phase3_spec.rb`
- [ ] Run `bundle exec rspec spec/services/phase3/` (when created)
- [ ] Run full spec suite - verify no regressions
- [ ] Check coverage report for new code

---

## Dependencies & References

### Files Modified
- `app/controllers/data_fix_controller.rb`
- `app/services/phase3/relay_enrichment_detector.rb` (new)
- `app/services/phase3/relay_merge_service.rb` (new)
- `app/views/data_fix/review_swimmers_v2.html.haml`
- `app/views/data_fix/_relay_enrichment_panel.html.haml` (new)
- `app/views/data_fix/_swimmer_form_card.html.haml`
- `config/locales/data_import.en.yml`
- `config/locales/data_import.it.yml`
- `spec/requests/data_fix_controller_phase3_spec.rb`
- `docs/data_fix/phase6_implementation_complete.md`

### Related Documentation
- [Phase 6 Implementation](./phase6_implementation_complete.md)
- [Microplus Crawler Schema](../crawler/microplus_layout4_schema.md) (if exists)
- [Phase File Format](./README_PHASES.md) (if exists)

### External Dependencies
- PhaseFileManager (existing)
- Kaminari pagination (existing)
- Bootstrap 4 collapse component (existing)
- I18n (existing)

---

## Future Enhancements (Not in Scope)

- [ ] Auto-detect auxiliary files in subdirectories
- [ ] Preview merge results before applying
- [ ] Undo/rollback merge operation
- [ ] Bulk import multiple meetings with relay enrichment
- [ ] Export incomplete relay data as CSV for manual editing
- [ ] API endpoint for programmatic merge

---

## Notes

- The relay enrichment workflow is **manual and inline** - no background jobs or modals
- Downstream phase data (Phase 4+) is **always cleared** when Phase 3 is modified
- Auxiliary Phase 3 files must be in the **same directory** as the source file
- Auxiliary file paths are stored as **relative paths** from source file directory
- The feature only activates when **incomplete relay swimmers are detected**
- Gender normalization accepts 'M'/'F' (case-insensitive, first letter match)

---

## Success Criteria

✅ All request specs pass  
✅ Unit specs added and passing  
✅ Manual workflow tested with real data  
✅ No regressions in existing Phase 3 functionality  
✅ Documentation updated  
✅ Code reviewed and approved  

---

**Last Updated**: 2025-11-08T01:15:00Z
