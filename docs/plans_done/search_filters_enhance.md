## Search & Filter Enhancements

=> DONE, 2026-03-07; plan kept as reference

- [x] Add a search widget in review_teams (phase 2: app/views/data_fix/review_teams.html.haml) and review_swimmers (phase 3: app/views/data_fix/review_swimmers.html.haml)

- [x] Add an additional filter toggle beside the search widget, to show just the rows having the name ("last_name|first_name" for swimmers, "editable_name" or "name" for teams) different from their respective key (es: "Rari Nantes Flegrea" as a team name vs. a key "Rari Nantes Cagliari" should show up with this filter on, even if the match was marked as ~90% sure). On the "Having != key" switch toggle, the page should be reloaded showing only the rows having the key different from the one composed from the name.

- [x] Phase 5 only: add a filter to show just which results will be created. This should be relatively easy after the data has been loaded and the matching process has been completed, so that we can simply check if the result row ID is nil or not.
The displayed icon for these rows (MIRs / MRRs) should be yellow, not green. Currently the icon is set to be yellow only for "problematic rows" (which have some columns that need manual review because the weren't "properly matched").
(See for example app/views/data_fix/_result_program_card.html.haml lines [53-61], [124-127], [164-168]; app/views/data_fix/_relay_program_card.html.haml lines [30-52], [68-80], [85-93], [118-125], [207-214])
