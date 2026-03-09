# Goggles Admin2 main TO-DOs

## [~] fix:team_in_badge (rake task + strategy + specs)
New rake task to fix a wrong `team_id` set to a specific Badge: updates all related results (only MIRs); delete meeting entries and reservations.
As usual, we need to create an SQL script as all other merge/fix rake commands do. (Implement also a "simulate" option, default 1: no actual changes are made)
For ref.: lib/tasks/check.rake, lib/tasks/merge.rake

Use a strategy for this so we can test in isolation and possibly reuse it in the admin front end (associated to a dedicated page with other maintenance tools).
Add RSpec tests for the strategy if possible.

MRS (meeting_relay_swimmers) have the link to `swimmer_id` and `badge_id` but lack the team_id so no update is needed.

MRR have a direct link to the team_id only, but they're also linked to the badge through MRS. If we're fixing a team in a badge that has any associated MRR row, that means all other meeting_relay_swimmers of the same MRR row need to be fixed too, as each MRR row represents a single relay team.

To avoid recursion and simplify the process, we could collect all results (MIR & MRS) found for the badge as these should all be associated to the same (new) team_id.

With this batch of badges to be processed we can:
- report the list of affected swimmer & badges ("All these badges will be updated..."), with names and IDs
- process and fix the whole batch of badges for data coherence, even though the command was invoked on a single one (data coherence is a must)

Example:
- team_id A needs to be fixed in Badge B
- the fix process finds all MRS rows associated to badge B, collects also all other badges associated to the same parent MRR row, and updates all of them with the correct team_id
- having a list of involved batches allows us to printout the report of affected swimmers and badges by the team change.

We should also check for duplicate badges before processing, to avoid data corruption and halt the task in case of multi-badge detection.
Example: swimmer A has already 2 badges for the same season (wrong) with different teams => it's a candidate for badge merge, not "badge fix".

Actual example from the current development DB:
- Badges 162160 and 169628 in Season 222 are wrongly assigned to `team_id` 1204 ("RN Genova") when it should be instead `team_id` 193 ("RN Flegrea")
- No duplicates or merge candidates exist => team fix is safe for both
- The fix should keep the badges, update the team_id and update all related results (MIRs/MRSs/MRRs) with correct team_id links.

---

## [~] Debug / Improve phase 5 verification
1. Show only existing results of the same event (ex.: verifying a MIR on "100RA" shouldn't show existing results for "50RA" or "200RA"). For the same reason, the "Confirm existing" button makes sense only on an already existing MIR for the same meeting_program (not just the meeting_event).

Gathering all existing results for the same swimmer in the current meeting is not totallu useless but it makes sense during phase 2, when checking/confirming that the matched team is actually corresponding to pre-existing results for the same team and swimmer. But in phase 5, verifying a specific result row (MIR or MRR) implies comparing the result timing with the parent meeting program as its main filter: if the meeting program is the same (meaning, same event and category), the timing is the same and the swimmer is the same, we have a possible duplicate, either due to a mismatched team during phase 2 or a mismatched swimmer during phase 3 (more rare, but possible).

=> Show rows with the confirmation button only if the meeting program and the swimmer are equal. By pressing the confirmation button, the existing row will overwrite the current JSON data row being "confirmed" and the page should get refreshed.

### Issues / additional improvements:
2. Clicking on "confirm" doesn't refresh the page (but the JSON data gets updated): probably we just need a full page refresh for this

3. The confirmation dialog gets displayed once for every "confirmation row" (definitely wrong), even if we just click on the correct row (3 + 1 confirmation dialog appears in sequence for a 3 row subsection, even if we click just to the second one; plus, the page doesn't refresh the contents)

4. Add a filter to display only NEW results. More selective: show either NEW MIRs or NEW MRRs (with unmatched IDs); that is "yellow" badge rows.
Currently the filter shows correctly any row that may generate an SQL INSERT: both "green" (ID/matched) results that have a new associated lap, plus any NEW/yellow (unmatched) results (with or without laps). This new filter should focus just on the main result row, ignoring the siblings (laps, MRS, relay_laps).
This is because when we review the data being imported, focusing on the "parent" result row first allows the operator to find faster mismatches coming from earlier phases.

---

## Misc

- [ ] Create fixture duplicate badges (test domain) for pending test:
```bash
Pending: (Failures listed here are expected and do not affect your suite's status)

  1) Merge::TeamInBadge duplicate badge detection populates errors when duplicate badges exist
     # No swimmer with multiple team badges found in test DB
     # ./spec/strategies/merge/team_in_badge_spec.rb:279

  2) Merge::TeamInBadge duplicate badge detection raises on prepare when duplicate badges exist
     # No swimmer with multiple team badges found in test DB
     # ./spec/strategies/merge/team_in_badge_spec.rb:297
```

- [ ] Improve coding in merge strategies

- [ ] Check for very-slow specs and optimize them
