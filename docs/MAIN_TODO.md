# Goggles Admin2 main TO-DOs
[x] = DONE, [ ] = TODO, [~] = almost ok, additional testing needed

## [~] Debug / Improve phase 5 verification

### Issues / additional improvements:
2. Clicking on "confirm" doesn't refresh the page (but the JSON data gets updated): probably we just need a full page refresh for this

3. The confirmation dialog gets displayed once for every "confirmation row" (definitely wrong), even if we just click on the correct row (3 + 1 confirmation dialog appears in sequence for a 3 row subsection, even if we click just to the second one; plus, the page doesn't refresh the contents)

4. Add a filter to display only NEW results. More selective: show either NEW MIRs or NEW MRRs (with unmatched IDs - e.g.: "yellow" badge rows).
Currently the filter shows correctly any row that may generate an SQL INSERT: both "green" (ID/matched) results that have a new associated lap, plus any NEW/yellow (unmatched) results (with or without laps). This new filter should focus just on the main result row, ignoring the siblings (laps, MRS, relay_laps).
This is because when we review the data being imported, focusing on the "parent" result row first allows the operator to find faster mismatches coming from earlier phases.

---

## Misc

- [~] Create fixture duplicate badges (test domain) for pending test:
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
