# Data-Fix pipeline fixtures (phase 09)

Phase data used by `spec/services/data_fix/review_rules_spec.rb` (one example per ready-rule clause) and the
verdict specs. Each `<name>.json` holds the `data` section of phases 1-3 (`phase1`, `phase2`, `phase3`); the specs copy
them into a temporary `<tmp>/242/` folder as `<name>-lt4-phaseN.json` files, stamped as built by the pipeline.
`result_free_manifest.json` is a manifest-only LT4 source (no results).

| Fixture | Expected |
|---|---|
| clean_fin | FIN-matched meeting, all ids, 2 new teams of 10 and 37 new swimmers of 100 (under the shares): clean, ready |
| new_meeting | review at step 1 (meeting not matched by FIN id) |
| team_candidate | review at step 2 (nil-id team with a candidate) |
| grey_match_unconfirmed / grey_match_confirmed | review / clean (team matched at 85%) |
| too_many_new_swimmers | review at step 3 (41% new) |
| too_many_new_teams | review at step 2 (26% new) |
| new_swimmer_missing_category | blocked at step 3 |
| gender_guessed | review at step 3 (gender guessed, 89.9%) |
| result_free_manifest | clean once Phase 1 is valid |

The ids are fake: the phase 1-3 review rules make no DB lookup (the exact-name preflight runs on the clean_fin names, which are unlikely on purpose).
