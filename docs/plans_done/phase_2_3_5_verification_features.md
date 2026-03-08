## Verification Features

=> DONE, 2026-03-07; plan kept as reference

### [x] Phase 5 verification button(s)
If the meeting being processed is existing (has an ID) and with results already present, we should show an additional "verify" button for each "NEW" result of a swimmer paired to a team with less than perfect match.

For example: a 100% sure swimmer with ID, matched to what it seems like a new result on a ~90% sure team (with ID), could be verified for existing MIRs on the same meeting_program_id (if set), using the same swimmer ID and timing result (ignoring the team_id).
If an existing matching MIR is found (on the same meeting_program_id, meaning in the same meeting), it implies most certainly the team matching is wrong (or needs to be fixed) and the current row is a duplicated that MUST NOT BE inserted.

Moreover, we should allow the operator to fix the team association or the result as easily as possible, deciding if the team matching is wrong or if the result is wrong (e.g., wrong timing, wrong badge, deciding to keep the result as new or discard the result as duplicate).

One idea could be to respond to the "verify" button press with an AJAX section that gets expanded below the current result row, or a modal. (Any other better UX idea is worth considering).
From this additional section/modal/whatever we could show the operator that:
- if the swimmer has other/different badges in the same season
- if there's already another result for the same swimmer and event in the same meeting, but with a different team ID or a different timing
- reuse the team form card (app/views/data_fix/_team_form_card.html.haml) if possible to allow the operator to edit directly the overall team matching


### [x] Phase 3 verification add-ons
The ideas above could be used to improve the data shown for each swimmer during phase 3 and ease the operator experience. We could reorder (changing the weight) of the "fuzzy_matches" of each swimmer to be matched, based on the gathered data for the "badges" array, to help the operator make the right choice.

Phase 3 is namely about matching swimmers to their respective IDs, but in fact is more about their badges (the tuple [swimmer, team, season]). So, fixing the swimmer row to its correct match implies also detecting if an existing badge is already present in the DB.
Phase 3 stores in its data files the matching badge for each extracted swimmer string key. 

Example:
```json
    "badges": [
      {
        "swimmer_key": "M|ROSSI|Carlo|1984",
        "team_key": "<team_key>",
        "season_id": 222,
        "swimmer_id": <swimmer_id>,
        "team_id": <team_id>,
        "category_type_id": 1523,
        "category_type_code": "M35",
        "number": "?",
        "badge_id": <badge_id>
      },
  // [...]
```

By comparing all badges available for the fuzzy-matched swimmers corresponding to the same swimmer_key, we could identify the most probable candidate for the correct match, if we add to the shown data also the team names associated with both the row being edited and the available matching candidates.

Ideally, to do that, we should be able to store also the badges and the team names associated to each "fuzzy_matches" entry, not just the swimmer data.
We could then show for each item in the drop down selection list the candidate name and team name to be compared to the targeted swimmer/team being edited (adding the associated team_key to the current swimmer row is trivial). A target swimmer_key (+ team_key) that has a corresponding "fuzzy match" swimmer associated to a team that is already a 100% match from phase 2, is definitely more probable than a candidate with a fuzzy match to a team that is not a 100% match from phase 2.
(In more simple words: enhance the matching procedure by using also the associated teams for each match)


### [x] Phase 2 verification button(s)
Again, the same principles could be applied in phase 2 (teams / team_affiliations) by leveraging any existing swimmer already associated to the "fuzzy_matches" candidates, limiting this check to the first 3 "100% sure" associated swimmers found for each team (using matching keys for import data vs corresponding fields for the existing rows).

This process requires the data file from phase 3 to be already existing, so this verification process is a better candidate for a "verify" button to be shown during a review of phase 2 after phase 3 (i.e.: only if the data files from phase 3 are available), and only for each team row not-already-100%-sure.

For instance, we could:
- retrieve from the phase 3 data file the first 3 swimmer keys associated to the same team_key that have possibly a 100% match candidate set and use these swimmer IDs as reference
- for each fuzzy-matched team candidate, retrieve its the 3 existing & corresponding swimmer badges from the data file
- compare the two sets (if a swimmer associated to the target team key was 100% matched, it means it has an ID associated, thus it has a badge and a team, which can be used for comparison)
- if the target team + swimmer set matches the fuzzy-matched team + existing swimmer IDs, the match is 100% confirmed
