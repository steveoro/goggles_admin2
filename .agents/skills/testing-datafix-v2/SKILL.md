---
name: testing-datafix-v2
description: How to log into goggles_admin2 without the API and stage spec fixture files to drive the DataFix v2 phased wizard (review_sessions → review_results) end-to-end in a browser.
---

# Testing the DataFix v2 wizard in goggles_admin2

## Admin login without goggles_api

Admin auth = Devise `GogglesDb::User` + `AdminGrant` row + a **valid** JWT stored on `users.jwt` (decoded with `Rails.application.credentials.api_static_key`). The API is only needed when the stored JWT is expired — mint a valid one locally instead:

```ruby
# RAILS_ENV=development bin/rails runner
u = GogglesDb::User.find_or_initialize_by(email: "devin.test@example.com")
u.assign_attributes(first_name: "Devin", last_name: "Test", name: "devin.test",
                    password: "Password123!", password_confirmation: "Password123!",
                    confirmed_at: (u.confirmed_at || Time.zone.now))
u.save!
u.update_columns(jwt: GogglesDb::JWTManager.encode({ user_id: u.id }, Rails.application.credentials.api_static_key))
GogglesDb::AdminGrant.find_or_create_by!(user: u, entity: nil)
```

Then log in via `/users/sign_in` in the browser.

**Caveat:** the root dashboard (`home#index`) calls the remote API (`APIProxy.call`) and raises `ECONNREFUSED` when no goggles_api runs. Login itself works — navigate directly to file-based pages (`/pull/result_files`, `/data_fix/*`) instead of `/`.

## Staging meeting + phase files

- Source files live in `crawler/data/results.new/<season_id>/`; the **parent dir name must be a real season id** (`detect_season_from_pathname`).
- Phase files are siblings named `<source-base>-phaseN.json` (N=1..5).
- `spec/fixtures/import/sample-200RA-l4.json` (LT4 source) + `sample-200RA-l4-phase{1..4}.json` pair for season **242** ("Circuito italiano supermaster FIN 2024/2025" — exists in the test dump). The source's sha256 matches the phase `_meta.parent_checksum`, so phases aren't treated as stale.
- Rewrite `_meta.source_path` in each copied phase file to the absolute staged path (only needed if a `-phaseN.json` path is ever passed directly).
- Verify every `result['category']` in the LT4 source resolves to a `category_types` row for that season — otherwise `normalize_lt4_result_categories` runs `CategoryRecomputer` and deletes phase3/4/5 + all `data_import_*` rows for the file.
- To make the phase-5 step exercise `ResultSolver.build!` + `Phase5Populator.populate!`, do **not** stage a `-phase5.json`: first `review_results` visit auto-builds + auto-populates. `&rescan=1` (or the step-tab refresh icon) re-runs both; `&populate_db=1` re-runs only the populator.

## Reaching the wizard in the UI

`/pull/result_files` lists `crawler/data/results.new/<dir>` files; every `.json` row has two process icons — `fa-cogs` (legacy) and `fa-bolt` (**v2**). The bolt link goes to `review_sessions?file_path=<abs path>&phase_v2=1`. Step tabs then carry `phaseN_v2=1` params (`phase_v2` for step 1, `phase2_v2`…`phase5_v2`).

## Useful verifications

- Phase-1 session edit: expand a session card → edit Description → "Save Session" (confirm dialog) → exercises `PhaseFileManager` read→mutate→write!.
- `review_results` needs populated `data_import_meeting_individual_results` rows (`phase_file_path = <source abs path>`) for issue detection; check `import_key`/`swimmer_id`/`team_id`/`badge_id`/`meeting_program_id` columns in SQL.
- A/B no-regression check for `Phase5Populator`: snapshot MIR/lap rows (`SELECT CONCAT(import_key,'|',...)`), then in a runner `load` the pre-change file (`git show HEAD~1:app/strategies/import/phase5_populator.rb > /tmp/old.rb`) to redefine methods in-process, delete rows, re-run `populate!`, diff.
- Test-dump meetings for season 242 are fake names, so `meeting_program_id`/`meeting_individual_result_id` stay NULL (all results = NEW) — expected, not a bug.

## Pitfalls when hand-writing URLs

- Steps 2-5 require their own `phaseN_v2=1` param (`review_teams?…&phase2_v2=1`, `review_swimmers?…&phase3_v2=1`, `review_results?…&phase5_v2=1`); `phase_v2=1` alone is only for step 1. A bare URL **redirects to `data_fix_legacy`**, whose LT2 pipeline can rewrite the staged source file to `layoutType:2` and materialize `-lt4` working copies — afterwards the v2 wizard silently reads the `-lt4-*` phase set instead of `<src>-phaseN`. If that happens, restore the LT4 source + `rm *-lt4*.json`.
- `review_teams`/`review_swimmers` have a safety rebuild: if the phase file's `teams`/`swimmers` array is empty, they rebuild and redirect — a source yielding 0 teams/0 swimmers (e.g. a relay-only LT4 source, since those solvers only read individual results) loops forever (`ERR_TOO_MANY_REDIRECTS`). Exercise solvers via runner `build!` instead of the step-tab refresh on such fixtures.

## Driving `Committers::Main` end-to-end on the fixtures

`commit_all` inside `ActiveRecord::Base.transaction { …; raise ActiveRecord::Rollback }` gives clean A/B; snapshot/restore `information_schema` AUTO_INCREMENT before **each** run or the rolled-back AI drift makes `sql_log_content` differ.

Fixture gaps to sanitize in /tmp copies (all in unchanged code — payload ids point at rows that don't exist in the test DB):

- phase2 `team_affiliations[].team_id`: null the dangling ones (committer resolves by `team_key` then).
- phase3 `badges[]`: fill `number` (all blank); null `team_id`/`swimmer_id` where the payload id doesn't exist.
- phase4: needs `data.sessions[].events[]` with `key`; the event's **internal `session_order` must equal the parent session's** — the phase-5 program lookup is `@event_id_by_key["{session_order}-{key}"]` while MIR import_keys are `"{order}-{event}-…"`. Relay program keys carry the gender fused to the event code (`1-M4X50SL-100-119-X` → event key `M4X50SL`, event_type ids 32/33 in the dump).
- phase1 must be the **current** flat schema (`data.meeting_session[]` with nested `swimming_pool.city`); old-schema fixture phase1 (`data.meeting`/`meeting_sessions`) isn't readable by the committer — synthesize by cloning a known-good file.
- MIR preflight requires `swimmer_id`/`badge_id`/`team_id` on the staging row (badge must match swimmer+team, `team_affiliation` for (team,season) must exist). To get real MIR+lap commits, prefill inside the same transaction: create dangling `Team`s by explicit id, `find_or_create_by!` swimmers from the `G|LAST|First|YOB|Team` swimmer_key, create `TeamAffiliation` + `Badge` (needs `team_affiliation_id`, `category_type_id`, `entry_time_type_id`) and `row.update!(swimmer_id:, badge_id:)`. GenderType ids in the dump: M=1, F=2.
- Relay commit needs `team_affiliations` to exist for its teams @ season — synthesize them in the phase2 copy (`team_key`,`team_id`,`season_id`,`team_affiliation_id:null`) and the committer creates them.

## Query-count evidence

Instrument `sql.active_record` inside the same runner (subscribe → regex counters → unsubscribe) around `commit_all`: memoized lap lookups show **one** `FROM laps WHERE meeting_individual_result_id = N ORDER` per MIR (298 for the 200RA fixture) vs ~2 per lap row unmemoized (1786). Pair-keyed `team_affiliations` SELECTs drop accordingly. Total SELECTs printed too for a gross comparison.
