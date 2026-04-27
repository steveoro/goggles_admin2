# Goggles Admin2 main TO-DOs

[x] = DONE, [ ] = TODO, [~] = almost ok, additional testing needed

- [ ] preselect city_id (and all sub fields) when changing or setting a swimming_pool_id in phase 1 (city_id must come from associated SwimmingPool, if present)

- [ ] if the Meeting commit fails in phase 6 because some of the required fields in phase 1 weren't properly set, the controller redirects to the file list instead of reporting the issue and allowing the operator to review the meeting data

- [ ] improve the ActionCable progress counters for results (it should be: 1 global index for all rows that have to be committed, 1 sub-index per meeting program)

- [ ] fix remaining RSpec failures (mostly controller-related: 1 failure remains)

- [ ] make it so that app/strategies/merge/swimmer_in_badge.rb can process badges from different seasons (probably must search for duplicates inside the season of the currently processed badge instead of assuming a single @season instance)