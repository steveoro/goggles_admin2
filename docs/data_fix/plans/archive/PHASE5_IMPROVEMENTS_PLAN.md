# Phase 5 Improvements Plan

**Created**: 2025-11-16  
**Priority**: High  
**Estimated Time**: 12-16 hours

## Overview

Four critical improvements needed for Phase 5 results review:

1. **DSQ Results Handling** - Fix ranking and display
2. **Category/Gender Code Computation** - Fix relay gender inference
3. **Remove 1000 Result Limit** - Show all results with pagination
4. **Invalid Result Filtering** - Highlight problematic results

---

## Issue 1: DSQ Results Handling

### Current Behavior
- DSQ results show at top with rank 0° and timing 0'00"00
- Uses "DQ" label
- Mixed with valid results

### Required Behavior
- Use "DSQ" label (not "DQ")
- Position at bottom of group
- Rank = last non-DSQ + 1 internally, display "-" to user
- Don't show timing, show "DSQ" badge instead

### Implementation (2-3 hours)

**Files to Modify**:
- `app/strategies/import/phase5_populator.rb`
- `app/views/data_fix/_result_program_card.html.haml`
- `app/views/data_fix/_relay_program_card.html.haml`

**Tasks**:
1. Update populator to set proper rank for DSQ results (1.5 hrs)
   - Detect `disqualified: true`
   - Count non-DSQ results in same group
   - Set rank = max_non_dsq_rank + dsq_sequence
   
2. Update display partials (1 hr)
   - Check `disqualified` flag
   - Display "-" instead of rank number
   - Hide timing, show red "DSQ" badge
   - Ensure DSQ results render at bottom

3. Test with real DSQ data (0.5 hrs)

---

## Issue 2: Category/Gender Code Computation

### Current Behavior
- Relay gender taken from first swimmer (`gender_type1`)
- Missing swimmer genders not inferred
- Category codes not computed from age sum

### Required Behavior

**A. Relay Gender Inference** (from `fin_sesso` header):
- Use relay header `fin_sesso` as primary source
- If missing, infer from swimmer genders:
  - All same → relay gender = that gender
  - Mixed → relay gender = "X"
- Propagate to missing swimmer genders:
  - Single-gender relay (F/M) → all swimmers = that gender
  - Mixed relay (X) + 2 known → remaining = opposite gender

**B. Relay Category Inference** (from age sum):
- If `fin_sigla_categoria` missing and all YOBs present
- Compute sum of ages at meeting date
- Use `CategoriesCache.find_category_for_age(sum, relay: true)`

**C. Individual Category Inference** (from YOB):
- If badge category missing and YOB present
- Compute age at meeting date
- Use `CategoriesCache.find_category_for_age(age, relay: false)`

### Implementation (4-6 hours)

**Files to Create**:
- `app/services/phase5/data_integrator.rb` (NEW)

**Files to Modify**:
- `app/strategies/import/phase5_populator.rb`
- `app/strategies/import/solvers/result_solver.rb` (if needed)

**Tasks**:

1. Create DataIntegrator service (2 hrs)
   ```ruby
   class Phase5::DataIntegrator
     def initialize(meeting_date:, season:)
       @categories_cache = CategoriesCache.instance
       @meeting_date = meeting_date
       @season = season
     end
     
     # Relay gender inference
     def infer_relay_gender(relay_row)
       # Use fin_sesso if present
       # Else infer from swimmers
     end
     
     def infer_swimmer_genders(relay_row, relay_gender)
       # For single-gender: set all to relay gender
       # For mixed: infer from known swimmers
     end
     
     # Category inference
     def compute_relay_category(swimmers_yobs)
       # Sum ages, find category
     end
     
     def compute_individual_category(yob)
       # Calculate age, find category
     end
   end
   ```

2. Integrate into Phase5Populator (2 hrs)
   - Instantiate DataIntegrator
   - Call before populating each result
   - Apply inferred values to row data
   - Log inference actions

3. Update program_id resolution (1 hr)
   - Ensure correct gender code used for MeetingProgram lookup
   - Verify category code accuracy

4. Test with real relay data (1 hr)
   - Test mixed relays with missing genders
   - Test category inference
   - Verify program grouping

---

## Issue 3: Remove 1000 Result Limit

### Current Behavior
- Phase 5 loads max 1000 results
- No pagination
- Incomplete data review

### Required Behavior
- Show ALL results
- Paginate by program groups (Option B)
- Keep programs together (don't split mid-program)

### Implementation (3-4 hours)

**Files to Modify**:
- `app/controllers/data_fix_controller.rb`
- `app/views/data_fix/review_results_v2.html.haml`

**Tasks**:

1. Controller pagination logic (1.5 hrs)
   ```ruby
   def review_results
     # Group by program FIRST
     all_programs = group_results_by_program(@individual_results)
     
     # Paginate program groups (not individual results)
     @per_page = 20 # programs per page
     @page = params[:page]&.to_i || 1
     @total_programs = all_programs.size
     
     start_idx = (@page - 1) * @per_page
     @program_groups = all_programs.slice(start_idx, @per_page) || []
     
     # Similar for relays
   end
   ```

2. Update view with pagination controls (1 hr)
   - Add pagination UI at top & bottom
   - Show current page / total programs
   - Keep existing card rendering

3. Test with large dataset (0.5 hrs)
   - Verify all results accessible
   - Check program integrity

4. Update display message (0.5 hrs)
   - Remove "Displaying up to 1000" text
   - Show "Page X of Y" instead

---

## Issue 4: Invalid Result Filtering

### Current Behavior
- No filter for problematic results
- All results shown always
- Hard to identify blocking issues

### Required Behavior
- Filter toggle: "Show only results with issues"
- Highlight missing/invalid data
- Auto-expand problem cards
- Similar to Phase 2/3 filters

### Implementation (3-4 hours)

**Files to Modify**:
- `app/controllers/data_fix_controller.rb`
- `app/views/data_fix/review_results_v2.html.haml`
- `app/views/data_fix/_result_program_card.html.haml`
- `app/views/data_fix/_relay_program_card.html.haml`

**Tasks**:

1. Define "invalid" result criteria (0.5 hrs)
   ```ruby
   def result_has_issues?(result)
     result.swimmer_id.blank? ||
     result.badge_id.blank? ||
     result.meeting_program_id.blank? ||
     result.team_id.blank? ||
     swimmer_incomplete?(result.swimmer_id) # missing gender/YOB
   end
   
   def swimmer_incomplete?(swimmer_id)
     swimmer = @swimmers_by_id[swimmer_id]
     return false unless swimmer
     swimmer['gender_type_code'].blank? || swimmer['year_of_birth'].to_i.zero?
   end
   ```

2. Controller filter logic (1.5 hrs)
   - Add `show_invalid_only` param
   - Filter programs with invalid results
   - Count invalid results per program
   - Pass issue flags to view

3. View filter UI (1 hr)
   - Add checkbox toggle
   - Show invalid count badge
   - Auto-expand cards with issues
   - Red border for problem cards

4. Visual indicators in cards (0.5 hrs)
   - Add warning icons
   - Red badges for missing data
   - Tooltip explanations

5. Test edge cases (0.5 hrs)
   - All valid → filter shows nothing
   - Mixed valid/invalid
   - Missing swimmer data propagation

---

## Implementation Order

### Day 1 (4-5 hours)
1. **DSQ Handling** (2-3 hrs)
2. **Start Category/Gender Computation** (1.5-2 hrs)
   - Create DataIntegrator skeleton
   - Basic relay gender inference

### Day 2 (5-6 hours)
3. **Complete Category/Gender Computation** (3-4 hrs)
   - Swimmer gender propagation
   - Category calculation from ages
   - Integration into populator
4. **Invalid Result Filtering** (2 hrs)
   - Basic filter implementation
   - Issue detection logic

### Day 3 (4-5 hours)
5. **Remove 1000 Limit + Pagination** (3-4 hrs)
6. **Final Testing & Polish** (1 hr)
   - Complete filter UI
   - Test all improvements together
   - Update documentation

---

## Testing Strategy

### Test Data Required
- Results with DSQ status
- Relay with missing `fin_sesso`
- Relay with partial swimmer genders
- Relay with all YOBs but no category
- Individual with YOB but no badge category
- Large dataset (2000+ results)
- Results with missing swimmer/team IDs

### Test File
Use: `crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json`

### Verification Steps
1. DSQ results at bottom, showing "-" and "DSQ" badge
2. Relay programs correctly grouped by gender (X not F)
3. All results visible across pagination
4. Filter shows only problematic results
5. Missing data clearly highlighted

---

## Documentation Updates

After completion:
- Update `ROADMAP.md` with completed milestones
- Add to `CHANGELOG.md` (2025-11-16 entry)
- Update `PHASES.md` Phase 5 section with new features
- Document DataIntegrator in `TECHNICAL.md`

---

## Acceptance Criteria

- [ ] DSQ results ranked at bottom, display "-" rank and "DSQ" badge
- [ ] Relay gender comes from `fin_sesso`, not first swimmer
- [ ] Missing swimmer genders inferred from relay type
- [ ] Missing categories computed from age sums
- [ ] All results viewable (no 1000 limit)
- [ ] Pagination by program groups works
- [ ] Filter shows only results with issues
- [ ] Invalid results clearly marked with warnings
- [ ] All tests pass
- [ ] Documentation updated

---

**Total Estimate**: 12-16 hours over 3 days  
**Priority**: High (blocks Phase 6 relay commit)  
**Dependencies**: Phase 3 data (swimmer/badge info)
