# Phase 2 (Teams) Implementation Summary

**Date**: 2025-10-07  
**Status**: Ready to implement (Option A: Full Feature Parity)  
**Estimated Time**: 6-8 hours  

---

## Quick Reference

### Current State
- ✅ TeamSolver implemented (LT2 + LT4 support)
- ✅ Basic controller actions (`review_teams`, `update_phase2_team`)
- ✅ Basic table view with pagination/filtering
- ❌ Missing 4/6 team fields
- ❌ Missing AutoComplete components
- ❌ Missing visual status indicators
- ❌ Missing add/delete actions
- ❌ No test coverage

### Target State (100% Complete)
- ✅ All 6 team fields editable
- ✅ Two AutoComplete components (Team + City)
- ✅ Visual status indicators (borders, backgrounds, icons)
- ✅ Collapsible card layout
- ✅ Add/Delete team actions
- ✅ 20-25 comprehensive tests
- ✅ Service objects (if needed)

---

## Team Entity Structure

```ruby
{
  'key' => 'Original Team Name',        # immutable reference key
  'name' => 'Actual Name',              # required
  'editable_name' => 'Display Name',    # required
  'name_variations' => 'alt1|alt2',     # optional (pipe-separated)
  'team_id' => 123,                     # DB ID (nil if new)
  'city_id' => 456                      # optional city binding
}
```

**Currently Supported**: `name`, `team_id` (2/6)  
**Missing**: `editable_name`, `name_variations`, `city_id`, fuzzy matches (4/6)

---

## Visual Status Indicators

### Border Colors
- **Red border**: `team_key.downcase != team.name.downcase` (mismatch detected)
- **No border**: Names match

### Background Colors
- **bg-light**: Team has DB ID (match found)
- **bg-light-yellow**: Team has no ID (new entity)

### Status Icons
- **✅**: `team.valid? && team.id.present?` (valid DB match)
- **🔵**: `team.id.present?` but not valid (match found but validation issues)
- **🆕**: `team.id.blank?` (new entity, not in DB)

---

## AutoComplete Configuration

### Team AutoComplete
```ruby
AutoCompleteComponent.new(
  base_dom_id: "team[#{index}]",
  base_api_url: api_url,
  detail_endpoint: 'team',
  search_endpoint: 'teams',
  search_column: 'name',
  label_column: 'editable_name',
  default_value: team['team_id'],
  target3_dom_id: "team_#{index}_editable_name",
  target3_column: 'editable_name',
  target4_dom_id: "team_#{index}_city_id",
  target4_column: 'city_id',
  target5_dom_id: "team_#{index}_name",
  target5_column: 'name',
  target6_dom_id: "team_#{index}_name_variations",
  target6_column: 'name_variations',
  jwt: current_user.jwt
)
```

### City AutoComplete
```ruby
AutoCompleteComponent.new(
  base_dom_id: "team[#{index}]",
  base_api_url: api_url,
  detail_endpoint: 'city',
  search_endpoint: 'cities',
  search_column: 'name',
  label_column: 'area',
  default_value: team['city_id'],
  target2_field: 'area',
  target2_column: 'area',
  jwt: current_user.jwt
)
```

---

## Card Layout Pattern

```haml
.card{ class: border_class }
  .card-header{ class: bg_class, data: { toggle: 'collapse', target: "#team-#{index}" } }
    .row
      .col-3
        %button.btn.btn-link
          = team['key']
      .col
        %span.text-secondary= '->'
        = team['editable_name']
        - if team['team_id'].present?
          ID: #{team['team_id']}
          = status_icon
        - else
          🆕
      .col
        %i.form-text.text-muted
          🔑 "#{team['key']}"
  
  .collapse{ id: "team-#{index}" }
    .card-body
      = form_tag(update_phase2_team_path, method: :patch) do
        = hidden_field_tag :file_path, @file_path
        = hidden_field_tag :team_index, index
        
        -# Fuzzy matches dropdown
        .form-group
          = label_tag 'fuzzy_matches'
          = select_tag 'quick_select', options_from_collection_for_select(...)
        
        -# Row 1: Team AutoComplete + editable_name
        .row
          .col-6
            = render(AutoCompleteComponent.new(...)) # Team
          .col-6
            = text_field_tag 'editable_name', team['editable_name'], required: true
        
        -# Row 2: name + name_variations
        .row
          .col-5
            = text_field_tag 'name', team['name'], required: true
          .col-7
            = text_field_tag 'name_variations', team['name_variations']
        
        -# Row 3: City AutoComplete
        = render(AutoCompleteComponent.new(...)) # City
        
        = submit_tag 'Save', class: 'btn btn-primary', data: { confirm: '...' }
```

---

## Implementation Checklist

### Session 1: View + AutoComplete (2-3 hours)
- [ ] Convert `review_teams_v2.html.haml` from table to card layout
- [ ] Add visual indicators (borders, backgrounds, status icons)
- [ ] Integrate Team AutoComplete component
- [ ] Integrate City AutoComplete component
- [ ] Add fuzzy matches dropdown
- [ ] Add all 6 fields to form (editable_name, name, name_variations, team_id, city_id)
- [ ] Test manually with sample phase2 data

### Session 2: Add/Delete Actions (1 hour)
- [ ] Implement `add_team` controller action
- [ ] Implement `delete_team` controller action
- [ ] Add routes: `post 'data_fix/add_team'`, `delete 'data_fix/delete_team'`
- [ ] Add "Add Team" button above cards
- [ ] Add "Delete" button in each card header
- [ ] Clear downstream phase data (phase3+) on changes
- [ ] Update metadata timestamp on changes

### Session 3: Controller Refactoring (1 hour, optional)
- [ ] Extract `Phase2NestedParamParser` if AutoComplete params get complex
- [ ] Extract `Phase2TeamUpdater` if update logic grows beyond simple assignment
- [ ] Ensure controllers stay thin (<20 lines per action)
- [ ] Resolve any RuboCop complexity warnings

### Session 4: Test Coverage (2-3 hours)
- [ ] Write `spec/requests/data_fix_controller_phase2_spec.rb`
- [ ] Test `review_teams`: pagination, filtering, rescan, phase2_v2 flag
- [ ] Test `update_phase2_team`: all 6 fields, nested params, validation
- [ ] Test `add_team`: blank team creation, index increment
- [ ] Test `delete_team`: removal, downstream clearing, edge cases
- [ ] Write service object tests if extracted
- [ ] Verify all edge cases: nil params, out-of-range indices, invalid data
- [ ] Target: 20-25 tests, 100% passing

### Session 5: Documentation + Polish (30 min)
- [ ] Update `data_fix_redesign_with_phase_split-to_do.md` status to 100%
- [ ] Add decision log entry
- [ ] Create `phase2_status_YYYYMMDD.md` if needed
- [ ] Document any deviations from legacy
- [ ] Update graph_mem observations

---

## Key Files Reference

### Legacy (for feature parity)
- `app/views/data_fix_legacy/review_teams.html.haml` - Card layout, visual indicators
- `app/views/data_fix_legacy/_team_form.html.haml` - Form fields, AutoComplete setup

### Current V2 (starting point)
- `app/controllers/data_fix_controller.rb:46-90` - `review_teams` action
- `app/controllers/data_fix_controller.rb:208-251` - `update_phase2_team` action
- `app/views/data_fix/review_teams_v2.html.haml` - Current basic table view
- `app/strategies/import/solvers/team_solver.rb` - Phase2 solver

### Phase 1 (patterns to reuse)
- `app/views/data_fix/review_sessions_v2.html.haml` - Collapsible cards, AutoComplete
- `app/controllers/data_fix_controller.rb` - add_session, delete_session patterns
- `app/services/phase1_*.rb` - Service object patterns

### Tests (for coverage patterns)
- `spec/requests/data_fix_controller_phase1_spec.rb` - 29 passing tests
- `spec/services/phase1_nested_param_parser_spec.rb` - 15 passing tests

---

## Success Criteria

Phase 2 will be considered **100% complete** when:

1. ✅ All 6 team fields are editable via UI
2. ✅ Two AutoComplete components working (Team + City)
3. ✅ Visual indicators clearly show match status at a glance
4. ✅ Add/Delete team actions functional
5. ✅ Collapsible cards save vertical space for overview
6. ✅ 20-25 tests passing (100% coverage of Phase 2 actions)
7. ✅ No controller complexity warnings (AbcSize, MethodLength)
8. ✅ Documentation updated in TO-DO plan

---

## Notes

- **Design Decision**: Inline editing chosen over modal (consistency with Phase 1, only 6 fields)
- **Pagination**: Keep existing pagination (50 items/page works well)
- **Filtering**: Keep existing search/filter (works well)
- **Collapsible**: Initially collapsed to show 50+ teams at once
- **AutoComplete**: Proven pattern from Phase 1, no issues expected
- **Service Objects**: Extract only if controller complexity grows (keep it simple)

---

## Next Session Prep

When starting Phase 2 implementation:

1. Read this summary document
2. Check graph_mem for "Phase 2" observations
3. Review legacy files for visual reference
4. Start with Session 1 (view enhancement)
5. Test manually before moving to Session 2
6. Keep Phase 1 test patterns for reference

**Estimated total time**: 6-8 hours (can be split across multiple sessions)

Good luck! 🚀
