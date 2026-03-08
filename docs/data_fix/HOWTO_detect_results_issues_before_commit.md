## HOW-TO: detect results issues before commit (phase 6)

Phase 5: if a result in the same program for the same swimmer_id is already existing on the DB (present for the same meeting_program, regardless of the associated badge/team), it means probably the team matching is wrong and the current row is a duplicated that MUST NOT BE inserted.

**IT'S ALWAYS:**
- 1 swimmer registration x team (1 badge) across the whole season year (a season typically starts in September and ends the next August, with NO category changes across the same season for swimmers)
- in other words: 1 swimmer -> 1 badge (same badge for the whole year, same team: these should never change inside the same meeting); if we find more than 1 badge x swimmer in the same season_id, these are BIG RED FLAGS for data-import errors.
- Each swimmer badge should be unique within the same season and the same swimmer cannot be enrolled/"badged" with more than 1 team x season championship.

- unique result for each swimmer: 1 swimmer result -> 1 MIR x event (1 MeetingProgram -> 1 MIR -> 1 Swimmer) => if a MIR for the same event, for the same swimmer, already exists on the database, the one being imported is either a duplicate (different team_id? different timing? different badge? => one of the two result rows has wrong data and the operator should decide what to do)

- unique relay result for each team (x same group of relay swimmers): 1 MRR (x MRS) x event (1 MeetingProgram -> 1 MRR -> same group of relay swimmers for the same team); if the same group of swimmers participating in a relay result (MRS) points to an existing MRS group associated to an MRS having the same timing result, it probably means the team matching is wrong and needs to be corrected by the operator.

- MORE IMPORTANTLY: if a matched team is wrong for a swimmer, it is wrong FOR ALL OTHER SWIMMERS AND RESULTS tied to that same team key.

We can leverage the points above to identify data that needs to be fixed and prevent data errors from being committed to the DB in Phase 6.


## Overall goal
Be able to re-process an already processed JSON result file without getting any additional INSERT row statements in phase 6 due to team or swimmer mis-matches.
This way, if a JSON data-file is updated with new data (usually, lap timings), it can be re-processed without getting any duplicated rows.