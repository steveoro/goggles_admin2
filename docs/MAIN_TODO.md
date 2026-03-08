# Goggles Admin2 main TO-DOs

## [ ] fix:team_in_badge (rake task + strategy + specs)
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
