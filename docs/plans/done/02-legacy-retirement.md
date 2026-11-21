# Phase 02 — Legacy Data-Fix retirement (team scores ported first)

## Goal

Leave one Data-Fix flow (v2). Before removing the legacy wizard, port the one thing only it does: importing the overall team ranking (`GogglesDb::MeetingTeamScore`) from PDF-derived LT2 sources. Then delete the legacy controller, views, routes and solver/committer pair, the classes they leave unused, the dead code around them, and the staging-environment leftovers.

## Operator-visible outcome

- The PDF-scan "DATA-FIX" button and every file-list entry open the v2 flow. The v2 flags (`phase_v2`, `phase2_v2` …) become optional: old deep links still work.
- Phase 2 (Teams) shows a "Team rankings" card when the source carries one. The Phase 6 commit writes the scores and the commit report counts them ("Team scores: created / updated / skipped").
- The junk "Overall Team Ranking" / "Overall Stats" events no longer appear in Phase 4 for PDF sources.
- The gear (legacy) icon, the "Fetch Latest updates" (production vs staging) page and the "STAGING" label in the home header are gone. Pushing a script moves it from `results.new` to `results.sent` and stops there: no second push to `results.done`.

## Depends on

01: the smoke suite and the characterization spec guard the deletions; the event log records the commits used for the parity check.

## Invariants that apply here (from the master plan)

- No admin2-only tables in MySQL and **no goggles_db migration**: team scores are staged in the Phase 2 JSON, not in a new `data_import_*` table.
- Jobs that commit or push are enqueued only from an operator click (no job is added here; commit stays synchronous until 09).
- "Staging" means the `data_import_*` tables. The deprecated staging environment loses its leftovers here and gains nothing. Its config files (`staging:` blocks in `config/database*.yml`, etc.) are out of scope.
- Operator edits win: rebuilding Phase 2 rebuilds `team_scores` from the source, but team edits stay keyed by `team_key`, which an update never changes (`data_fix/teams_controller.rb:120`).
- File conventions stay (`NNNN-<base>-lt4.sql`, `results.new/sent/done/<season>`).
- Repo conventions: `# frozen_string_literal: true`; en + it keys; CHANGELOG + PATCH bump (`lib/version.rb`, `PATCH` at line 30) per user-visible step; `bundle exec rubocop -a` clean; never a bare `db:prepare` / `db:migrate`.

## The legacy team-score path today (verified)

| Step | Where |
|---|---|
| PDF parse builds a section `{ 'title' => 'Overall Team Ranking', 'ranking' => true, 'rows' => [{ 'pos', 'team', 'ind_score', 'overall_score' }] }` | `app/strategies/pdf_results/l2_converter.rb:475-498` (`create_ranking_section`, called at `:211`); stats section at `:570-590` (called at `:220`) |
| Example row from a real file: `{"pos":"1","team":"Roma Nuoto Master ssd","ind_score":"35209.930","overall_score":"35209.930"}` | `crawler/data/results.done.2025/242/json/…Trofeo_Roma_nuoto_Master-res.json` (gitignored; copy a trimmed version into fixtures) |
| Solver: ranking sections are skipped for team/swimmer mapping, then processed in `map_events_and_results` | `app/strategies/import/macro_solver.rb:308`, `:458-463` |
| `process_team_score`: team + affiliation by name, key `"#{rank}-#{team}"`, first key wins, scores parsed with `Parser::Score.from_l2_result` | `macro_solver.rb:2599-2626`; `app/strategies/parser/score.rb:27-32` |
| `find_or_prepare_team_score`: existing row by meeting+team+affiliation, else new row with `rank`, `sum_individual_points = ind`, `sum_relay_points = overall - ind`, `sum_team_points = overall`, `meeting_points = ind`, `meeting_relay_points = overall - ind`, `meeting_team_points = overall`, `season_* = 0.0`, `season_id` = solver season | `macro_solver.rb:1675-1701` |
| Commit: binds team / affiliation ids, re-seeks by `(meeting_id, team_id)`, insert or update + SQL log | `app/strategies/import/macro_committer.rb:784-818` (called at `:127`), `commit_and_log` `:839-869` |

v2 gap: `Import::Adapters::Layout2To4#build_dictionaries_and_events!` (`app/strategies/import/adapters/layout2_to4.rb:112-150`) has no `ranking` / `stats` check, so a ranking section becomes an event with code `EVENT` (`build_event_code`, `:276-280`). `Committers::Main#commit_all` (`app/strategies/import/committers/main.rb:90-168`) has no team-score step. Only PDF sources carry rankings: the FIN crawler does not emit `ranking` sections (grep of `crawler/server`).

## Scope

### A. Team-score port

| File | Change |
|---|---|
| `app/strategies/import/adapters/layout2_to4.rb` | in `build_dictionaries_and_events!` (`:112-150`): a section with `ranking` present is not turned into an event. Its rows go to `out['teamRankings']` (raw strings, as in the source) and their team names into the `teams` dictionary. A section with `stats` present is skipped. Retry sections keep today's behaviour |
| `app/strategies/import/team_score_extractor.rb` (new) | `Import::TeamScoreExtractor.extract(data_hash) -> Array<Hash>`: reads LT4 `teamRankings`, or LT2 `sections` with `ranking: true`. Returns `{ 'team_key', 'rank' (Integer), 'ind_score' (Float), 'overall_score' (Float) }`, deduplicated on `"#{rank}-#{team}"` (legacy key), sorted by rank. `.from_source(source_path, data_hash)` falls back to the LT2 sibling (`source_path.sub(/-lt4\.json\z/, '.json')`) when an older LT4 working copy has no `teamRankings` |
| `app/strategies/import/solvers/team_solver.rb` | `build!` (`:37-110`) adds `'team_scores' => TeamScoreExtractor.from_source(...)` to the Phase 2 payload (`:93-96`) and makes sure every score's `team_key` has a team entry (built with `build_team_entry`) |
| `app/services/data_fix/source_resolver.rb#source_result_free?` (`:290-306`) | the LT2 branch ignores `ranking` / `stats` sections |
| `app/strategies/import/committers/meeting_team_score.rb` (new) | `Import::Committers::MeetingTeamScore` (`include LegacyPersistence`), `initialize(stats:, logger:, sql_log:)`, `commit(score_hash, meeting_id:, season_id:, team_id:, team_affiliation_id:) -> id`. Attribute mapping identical to `macro_solver.rb:1684-1699`; existing row looked up by `(meeting_id, team_id)` as at `macro_committer.rb:808-811`, updated through `changes_for_update` + `SqlMaker#log_update(changes)`, otherwise inserted + `SqlMaker#log_insert`; counts `team_scores_created` / `team_scores_updated`; `logger.log_success(entity_type: 'MeetingTeamScore', …)` |
| `app/strategies/import/committers/main.rb` | stats keys `team_scores_created/updated/skipped` (`:42-61`); memoized `meeting_team_score_committer` next to the other committers (`:1179-1300`); private `commit_team_scores` called in `commit_all` **after `merge_overwrite_candidates!` and before `mark_results_acquired!` (`:128-129`)**, in the legacy position (last). Per score: `team_id = resolve_team_id(team_hash&.dig('team_id'), team_key)` (`:1133`), `team_affiliation_id = resolve_team_affiliation_id_for_result(team_id:, team_key:, create_missing: true)` (`:1099`), `season_id = @season_id` and `meeting_id = @meeting.id` (both set in Phase 1, `:205-206`). Unresolved team or affiliation: `team_scores_skipped += 1` + `logger.log_operation(action: 'team_score_skipped', details:)`. This does not halt the commit (see Decisions) |
| `app/views/data_fix/review_teams.html.haml` | collapsed card "Team rankings (N)" under the metadata card (`:18-21`): rank, team key, matched team (from the Phase 2 team entry), individual / overall points; a warning badge on keys whose team entry is missing or new |
| `app/views/data_fix/commit_phase6_report.html.haml` | `'Team Scores' => [:team_scores_created, :team_scores_updated]` in `entity_groups` (`:60-77`); "Team scores skipped" in the auto-fix block (`:98-99`) |
| `config/locales/data_import.{en,it}.yml` | `data_import.data_fix.team_scores.{title,rank,team,matched_team,ind_points,overall_points,missing_team,skipped}` |
| `app/views/pdf/_result_card.html.haml:85` | `review_sessions_path(file_path: json_pathname, phase_v2: 1)`, **only after the parity spec is green** |
| `docs/data_fix/DATA_STRUCTURES.md`, `PHASES.md` | document `teamRankings` (LT4) and `team_scores` (Phase 2) |

Phase 2 JSON shape added:

```json
"data": {
  "season_id": 242,
  "teams": [ … ], "team_affiliations": [ … ],
  "team_scores": [
    { "team_key": "Roma Nuoto Master ssd", "rank": 1, "ind_score": 35209.93, "overall_score": 35209.93 }
  ]
}
```

Phase 2 owns the scores because they reference only teams, and the teams' resolution lives there. The meeting is resolved at commit time (it may be new until Phase 6).

### B. Move what v2 borrows

| Item | Change |
|---|---|
| `data_fix_legacy/_modal_progress` (7 v2 callers: `data_fix/review_{sessions,teams,swimmers,events,results}.html.haml:3`, `pull/index.html.haml:3`, `push/index.html.haml:1`) | `git mv` to `app/views/goggles/_modal_progress.html.haml` (next to the other shared partials such as `goggles/_api_offline_banner`; 03 and later phases use this path); update the 7 render paths (`render(partial: 'goggles/modal_progress')`); no markup edit, the ids `#modal-progress`, `#progress-msg`, `#di-progress` stay |
| `DataFixController#coded_name` (`app/controllers/data_fix_controller.rb:40-42` redirects to legacy `:654-675`) | move the body + `coded_name_params` (`:749-755`) into `DataFixController`; live caller: `app/javascript/controllers/coded_name_controller.js:87` (`/data_fix/coded_name`), used by `data_fix/_meeting_form_card` and `_session_form_card` |
| `DataFixController#teams_for_swimmer` (`:44-46` → legacy `:685-698`) | move the body, `teams_for_swimmer_params` and `data_fix_legacy/teams_for_swimmer.turbo_stream.erb` → `app/views/data_fix/`. No v2 caller exists today (only `data_fix_legacy/review_swimmers.html.haml:56`); see Decisions |
| Optional v2 flags | drop `LEGACY_REDIRECT_FLAGS` and its guard (`app/controllers/data_fix/base_controller.rb:37-42`, `:59-60`); drop the line-7 legacy redirect in `data_fix/{sessions,teams,swimmers,events,results}_controller.rb`. `review_redirect_params` keeps emitting the flag (harmless) |
| `app/views/file_list/_file_table.html.haml:77-82` | remove the gear (`fa-cogs` → `review_sessions_legacy_path`); keep the v2 bolt link. The PDF `fa-cogs` at `:90` (`pdf_extract_txt_path`) stays |

### C. Delete list (each verified by grep: remaining references outside itself)

| Delete | Remaining references, removed or reworded in the same step |
|---|---|
| `app/controllers/data_fix_legacy_controller.rb` (1177 lines) | routes `config/routes.rb:105-116`; redirects `data_fix_controller.rb:41,45` (section B) |
| `app/views/data_fix_legacy/*` (17 files) | the 7 `_modal_progress` renders (section B) |
| 12 routes `config/routes.rb:105-116` (`*_legacy` helpers) | line-7 redirects in the 5 v2 controllers; `_file_table.html.haml:79`; request specs asserting legacy redirects: `spec/requests/data_fix_controller_phase1_spec.rb:1163,1172`, `phase2_spec.rb:856,865`, `phase3_spec.rb:1019,1027`, `phase4_spec.rb:148,157`, `phase5_spec.rb:605,614` → rewrite to "without the flag, v2 renders" |
| `PushController#prepare` (`app/controllers/push_controller.rb:31-77`), its `before_action` (`:13`), `parse_file_contents` (`:143-151`), `detect_season_from_pathname` (`:157-161`), `prepare_solver` (`:165-169`); route `post 'push/prepare'` (`routes.rb:119`); key `data_import.push.msg_prepare_batch_ok` (en/it `:173`) | only caller `data_fix_legacy/review_results.html.haml:100` |
| `app/strategies/import/macro_solver.rb`, `macro_committer.rb`; `spec/strategies/import/macro_solver_spec.rb`, `macro_committer_spec.rb` | `push_controller.rb:49,168`; legacy controller. Comment-only mentions to reword: `pdf_results/l2_converter.rb` (10 comments), `import/phase5_populator.rb:8`, `import/committers/legacy_persistence.rb:7`, `pdf_controller.rb:165`, 7 `pdf_results/formats/*.yml` comments |
| `app/strategies/import/entity.rb`, `spec/strategies/import/entity_spec.rb` | `macro_solver.rb`, `data_fix_legacy/_swimming_pool_form.html.haml:9`, `macro_solver_spec.rb` |
| `app/strategies/import/adapters/layout4_to2.rb`, `spec/strategies/import/adapters/layout4_to2_spec.rb` | only `data_fix_legacy_controller.rb:830` |
| `app/components/data_fix/result_details_set_component.*`, `result_details_card_component.*` + their specs in `spec/components/data_fix/` | only `data_fix_legacy/result_details.turbo_stream.erb:6` |
| `app/components/switch/rotating_component.*`, `app/assets/stylesheets/rotating_switch_component.scss` + `@use` at `application.scss:14` | only `data_fix_legacy/review_results.html.haml:82` |
| i18n keys used only by deleted views | find each with grep before removing; the 01 parity spec keeps en/it aligned |

**Keepers despite the name (do not delete):** `LegacyAutoCompleteComponent` (+ `app/javascript/controllers/legacy_autocomplete_controller.js`, `legacy_auto_complete_component.scss`), used by `data_fix/_team_form_card.html.haml:113,149`, `_swimmer_form_card:135`, `_event_form_card:85`; `Import::Committers::LegacyPersistence`, included by 16 v2 committers; `progress_modal_controller.js` (used by the moved partial); `coded_name_controller.js`; `Parser::Score`; `docs/data_fix/legacy_version/` (historical docs); `DataFix::TurboFilterStateComponent`.

### D. Dead code (verified unreferenced)

| Item | Evidence |
|---|---|
| `DataFix::EventsController#results_chunk_v2` (`events_controller.rb:382-…`), route `routes.rb:80`, exclusion `base_controller.rb:30` | no caller in views, JS or specs |
| jsoneditor CSS `app/views/layouts/application.html.haml:18-19` | replaced by CodeMirror (`config/importmap.rb:24` comment) |
| `gem 'font-awesome-rails'` (`Gemfile:45`) | no `fa_icon` / asset import; FA comes from the CDN |
| `app/assets/stylesheets/select2_customizations.scss` | not `@use`d in `application.scss` |
| 20 empty scss stubs (`api_*.scss` ×14, `best50m_results`, `pdf`, `pull`, `push`, `settings`, `stats`) + their `@use` lines | zero non-comment lines |
| `srv.sh` | starts Spring and webpack-dev-server, neither of which is used any more |
| `features/` (support only, empty `step_definitions/`), `gem 'cucumber-rails'` (`Gemfile:118`), `gem 'guard-cucumber'` (`:77`), Guardfile spring block (`:129-134`, gem already removed per `Gemfile:83`), cucumber block (`:168` to the end of the file), features watches (`:120-122`) | no `.feature` files |
| `get 'best50m_results/index'` (`routes.rb:4`), `spec/views/best50m_results/index.html.haml_spec.rb` (pending only) | no controller or view; keep `spec/requests/best50m_results_spec.rb` (it tests `best_results`) |
| "Clear downstream" blocks writing keys that v2 phase files do not have: `swimmers_controller.rb:193-197`, `:366-370`; `events_controller.rb:369-372`; `teams_controller.rb:286-292` | guarded by `data.key?`, never true in v2 phase files |
| `sessions_controller.rb:310-318` (unconditionally writes empty `meeting_event`, `lap`, … arrays into Phase 1 data) | remove after grepping that no Phase 1 reader uses those keys (Phase 1 committer reads `data` + `meeting_session`, `main.rb:197-200`) |

### E. Staging-environment leftovers

| Item | Change |
|---|---|
| `HomeController#latest_updates` + `request_latest_updates` (`home_controller.rb:26-44`, `:62-…`), route `get 'home/latest_updates'` (`routes.rb:15`), `app/views/home/latest_updates.haml`, link `home/_data_import.html.haml:33-36` | delete. The API endpoint `tools/latest_updates` is untouched; 05 reuses it for drift v0 through its own service |
| Double push (`push_controller.rb:83-88`, `:176-181`, `:203-207`) | `push_file_and_move` moves only `results.new` → `results.sent`; a path outside `results.new` is refused with a flash (`data_import.push.already_sent`, en + it). The upload buttons in `_file_table.html.haml:2-13`, `:100-106` render only when `parent_folder == 'results.new'` |
| Port guess `app/views/home/_top_header.html.haml:5-10` | `447` → PRODUCTION, anything else → UNKNOWN (no STAGING branch) |
| `send_coverage.sh` (untracked, `.gitignore:75`) | **operator checklist, not a repo change**: delete the local file and rotate the tokens it holds |

## Data model (ops migrations)

None. No MySQL change and no goggles_db migration: team scores live in `phase2.json` (`data.team_scores`).

## Ordered steps

1. **Parity baseline (before any deletion).** Add the fixture `spec/fixtures/import/pdf-teamrank-lt2.json` (a trimmed copy of a real PDF-derived LT2 file: 2 events, a ranking section of about 5 teams that exist in `goggles_test`, a stats section). Spec `spec/strategies/import/team_scores_legacy_baseline_spec.rb`: run `Import::MacroSolver#solve` + `MacroCommitter#commit_all` inside the example transaction and write the resulting `meeting_team_scores` attributes (rank, team_id, team_affiliation_id, season_id, the 9 point columns) to `spec/fixtures/import/team_scores_legacy_expected.json`, committed. Not user-visible.
2. **Port** (section A without the `_result_card` link). Parity spec `spec/strategies/import/committers/meeting_team_score_parity_spec.rb`: Phase 1-5 files built by the v2 solvers on the same fixture, `Committers::Main#commit_all`, rows compared with the frozen JSON. User-visible (Phase 2 card, report line, no junk events): CHANGELOG + PATCH bump.
3. **Single entry point** (section B + the `_result_card.html.haml:85` link). User-visible: CHANGELOG + PATCH bump.
4. **Delete legacy** (section C) and rewrite the 10 legacy-redirect expectations. Delete the baseline spec from step 1; keep its frozen JSON. User-visible (gear icon gone): CHANGELOG + PATCH bump.
5. **Dead code** (section D). Not user-visible except jsoneditor CSS (none); one CHANGELOG "internal" line, no bump required.
6. **Staging leftovers** (section E). User-visible: CHANGELOG + PATCH bump.

## Specs and manual verification

| Spec | Proves |
|---|---|
| `spec/strategies/import/adapters/layout2_to4_spec.rb` (additions) | ranking section → `teamRankings` + teams, no `EVENT` event; stats section skipped |
| `spec/strategies/import/team_score_extractor_spec.rb` | LT4 key, LT2 sections, sibling fallback, dedupe on `rank-team`, score parsing (`'35209.930'`, `'1.234,50'`) |
| `spec/strategies/import/solvers/team_solver_spec.rb` (additions) | `team_scores` in the payload; missing team keys added |
| `spec/strategies/import/committers/meeting_team_score_spec.rb` | insert, update by `(meeting_id, team_id)`, SQL log lines, stats |
| `spec/strategies/import/committers/meeting_team_score_parity_spec.rb` | v2 rows equal the frozen legacy output |
| `spec/strategies/import/committers/main_spec.rb` (additions) | call order (after the merge step), skip + log on an unresolved team, no-op without `team_scores` |
| `spec/requests/data_fix_controller_phase{1..5}_spec.rb` (rewritten examples) | no flag → v2 page, no redirect |
| `spec/requests/data_fix_controller_spec.rb` (new) | `coded_name` JSON for `code` / `nick_name`; `teams_for_swimmer` turbo stream |
| `spec/requests/push_controller_spec.rb` (additions) | `results.new` → `results.sent`; a `results.sent` path is refused; `push/prepare` route is gone |
| `spec/requests/home_controller_spec.rb` (additions) | header never says STAGING; `home/latest_updates` is not routable |
| `spec/system/pdf_to_data_fix_spec.rb` | from the PDF result card to v2 Phase 1, Phase 2 shows the rankings card |
| `spec/routing/legacy_routes_spec.rb` | none of the 12 `/data_fix_legacy/*` paths, nor `push/prepare`, `best50m_results/index`, `data_fix/results_chunk_v2`, is routable |

Grep gate (no output expected; comments in docs excluded):
`grep -rnE "DataFixLegacy|data_fix_legacy|_legacy_path|Import::Macro|MacroSolver|MacroCommitter|Import::Entity|Layout4To2|push_prepare" app lib config spec`

Manual: one PDF-derived source with a ranking (e.g. a copy of the Trofeo Roma 2024 file) goes Phase 1 → 6 in v2 on the dev DB; `GogglesDb::MeetingTeamScore.where(meeting_id:)` holds the ranking and the SQL script contains the inserts. One FIN source passes the full routine gate. `bundle install` after the Gemfile removals; `bundle exec guard` starts without the spring/cucumber plugins.

## Exit criteria

- A PDF source commits its team scores through v2 Phase 6, and the parity spec matches the legacy output.
- The grep gate returns nothing; keepers are still present and their specs green.
- Characterization spec from 01 unchanged and green; smoke suite green.
- `rubocop -a` clean, en/it parity green, CHANGELOG + PATCH for steps 2, 3, 4, 6.
- **Routine gate:** sign in → board → crawl → review → commit → report → push → confirm works for one FIN source and one PDF-derived source, in v2 only.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Parity drift once the legacy code is gone | legacy output frozen as JSON in step 1, before deletion |
| In-progress PDF sources have an older LT4 working copy without `teamRankings` | `TeamScoreExtractor.from_source` reads the LT2 sibling; rebuilding Phase 2 is enough, no re-materialization |
| Ranking team names that never appear in the results become new teams | they now show in Phase 2 like any team and get the same review; the rankings card flags them |
| A team removed in Phase 2 leaves an orphan score | skipped, counted and logged, shown on the report |
| Deleting a class still used through a dynamic constant | grep gate plus full suite; delete in one step that can be reverted on its own |
| Dropping the double push breaks someone's habit | staging is deprecated (decision 11); `results.sent` stays readable for `DiskIndex` / `Backfill` |

## Decisions to confirm (default taken)

1. Unresolved team for a score: **default: skip, count and log; the commit goes on.** Alternative: add to `stats[:errors]`, which halts the commit.
2. `teams_for_swimmer`: **default: move as planned** (cheap, keeps the route). Alternative: delete it, since no v2 caller exists.
3. Pushing from `results.sent`: **default: refused.** Alternative: allow a re-push that leaves the file in place. Phase 07 replaces this list anyway.
4. `Import::DiffCalculator` (`app/strategies/import/diff_calculator.rb`) already has no caller in app/lib: **default: leave it, outside this phase's list**; flag it for 15.
5. Stats sections: **default: dropped** (legacy did not store them either).

## Out of scope

- Team scores for FIN/Microplus LT4 crawls (no ranking data in their output; not verified for Microplus "RIEPILOGO", `crawler/server/microplus-crawler.js:1497`).
- Season-level points (`season_*` stay 0.0 as in legacy).
- `staging:` entries in `config/database*.yml` and other staging config files.
- Converting Data-Fix views to Bootstrap 5 (12); the persistent commit report (09).

## Outcome (done, 0.10.78, 2026-11-21)

Delivered as two commits on `feature/modernize-admin-console-ux` (steps 1-2 + 5-6, then 3-4). Decisions 1-5 confirmed with their defaults. Full suite green (2939 examples, system specs included), rubocop clean, grep gate empty. Notes for later phases:

- Parity: v2 rows match the frozen legacy output exactly (`spec/fixtures/import/team_scores_legacy_expected.json`, season 192 fixture). The legacy committer could not commit team scores for a brand-new meeting (no meeting binding); v2 can.
- `phase2.json` gets `data.team_scores` only when the source has a ranking (keeps the 01 characterization digests). A score with no Phase 2 team entry is skipped directly (no `Team.for_name` fallback, which matched unrelated teams).
- `Parser::Score` reads `"1.234,50"` as 1.234 despite its doc comment; `TeamScoreExtractor` normalises the value itself. `Parser::Score` is unchanged (candidate fix).
- The v2 Phase 1 solver leaves meeting `code`, `header_year`, `edition`, `edition_type_id`, `timing_type_id` and the pool `nick_name` / `lanes_number` blank; Phase 6 fails without them. The parity spec fills them as an operator would. Relevant to the "ready to commit" rule in 09/10.
- LT4 working copies made before 0.10.78 keep their junk `EVENT` events from ranking sections until re-materialised; their scores are read from the LT2 sibling.
- `app/services/phase1_session_rescanner.rb:79-85` still writes empty downstream keys into Phase 1 data (not in the delete list).
- `coded_name` / `teams_for_swimmer` now flash `data_import.errors.invalid_request`; `pdf_controller.rb` was switched to the same key (the old `search_view.errors.invalid_request` has no `it` translation).
- For 15: `Import::DiffCalculator` still unused; docs under `docs/data_fix/legacy_version/` kept as history.
- Operator checklist still open: delete the untracked `send_coverage.sh` and rotate its tokens; run the routine gate by hand for one FIN and one PDF-derived source.

## Rollback note

Steps 2 to 6 are separate commits. Step 4 (deletion) reverts cleanly with `git revert`, and the routes, views and controller come back unchanged because step 3 kept the v2 flags accepted. Phase 2 files written with `team_scores` stay valid for older code, which ignores the extra key. Committed `meeting_team_scores` rows are ordinary rows and do not need undoing.
