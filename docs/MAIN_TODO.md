# Goggles Admin2 main TO-DOs

[x] = DONE, [ ] = TODO, [~] = almost ok, additional testing needed

- [ ] a more generic `fix:swimmer_in_badge` / `fix:team_in_badge`
  Make it so that app/strategies/merge/swimmer_in_badge.rb can process badges from different seasons (probably must search for duplicates inside the season of the currently processed badge instead of assuming a single @season instance)
  Current constraints:
  - loop halts if badges are from different seasons
    => we should be able to process any number of badges from any season
  - loop halts if the target team has NO team_affiliation for the season in which the badge was issued
    => existing affiliations for the updated team should be reassigned to the target team (so we reuse the same ID)
    => missing affiliations should be created (rare, but could happen)

  [x] Real use-case: fix (wrong) team (1305, Cagliari) assigned to swimmers 45341, 52332, 48648: correct team (1634, Toscana)
  => fixed for seasons 252, 242 and 232, but in 222, 212 and 202 we need to change the team in the badges but the affiliation is missing. Check it with: `rails check:map_swimmer_mirs swimmer=<swimmer_id>` (reports the results for each season)

- [x] preselect city_id (and all sub fields) when changing or setting a swimming_pool_id in phase 1 (city_id must come from associated SwimmingPool, if present)

- [ ] if the Meeting commit fails in phase 6 because some of the required fields in phase 1 weren't properly set, the controller redirects to the file list instead of reporting the issue and allowing the operator to review the meeting data

- [ ] improve the ActionCable progress counters for results (it should be: 1 global index for all rows that have to be committed, 1 sub-index per meeting program)

- [ ] fix remaining RSpec failures (mostly controller-related: 1 failure remains)
