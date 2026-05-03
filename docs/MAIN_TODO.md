# Goggles Admin2 main TO-DOs

[x] = DONE, [ ] = TODO, [~] = almost ok, additional testing needed

- [ ] Error during `merge:team` (from team 889 to team 542):

```bash
--------------
INSERT INTO team_affiliations (team_id, season_id, name, created_at, updated_at) VALUES (542, 152, 'ASD NUOTO CLUB CA', NOW(), NOW())
--------------

ERROR 1062 (23000) at line 1410 in file: '/home/steve/Projects/goggles_admin2/crawler/data/results.new/0230-merge_teams-889-542.sql': Duplicate entry '152-542' for key 'uk_team_affiliations_seasons_teams'
```
  The error appears for all TAs apparently missing from target season; the rake task doesn't seem to take into account "recycled" TAs

- [ ] if the Meeting commit fails in phase 6 because some of the required fields in phase 1 weren't properly set, the controller redirects to the file list instead of reporting the issue and allowing the operator to review the meeting data

- [ ] improve the ActionCable progress counters for results (it should be: 1 global index for all rows that have to be committed, 1 sub-index per meeting program)

- [ ] fix remaining RSpec failures (mostly controller-related: 1 failure remains)
