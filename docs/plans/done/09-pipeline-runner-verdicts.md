# Phase 09 — Pipeline runner, verdicts, commit runner

## Goal

Move the phase orchestration out of the six Data-Fix controllers into one service (`DataFix::Pipeline`). Make "clean / needs review / blocked / stale / failed" a stored, checkable fact per phase. Turn the Phase 6 commit into a clicked job with a persistent report. All of this happens on the interactive path only. No job prepares anything yet: that is phase 10, which can then reuse the exact code the controllers already run.

## Operator-visible outcome

- Each step header (a new stepper) shows its verdict and issue count, and marks a step **stale** when an earlier step changed. For example, a Phase 4 event edit now marks Phase 5 stale instead of failing at commit.
- Saving a team or swimmer card confirms it, so the card leaves the "review" filter. Gender-guessed swimmers now appear in that filter. Today they do not: they are forced to 89.9 % (`app/strategies/import/solvers/swimmer_solver.rb:459`), which the `< 89.0` filter (`app/controllers/data_fix/swimmers_controller.rb:109`) lets through.
- "Commit" opens a **commit summary**: how the meeting was matched, existing and new counts per entity, the new teams and swimmers, a fresh preflight and one Commit button. The commit then runs as a job. Its report is stored, can be reopened, links to the Outbox script, and shows season checks from a triggered health run.
- An automatic rebuild never deletes or rewrites a phase the operator edited.

## Depends on

- **01**: ops DB (`Ops::ApplicationRecord`, `Ops.safely`, `Ops::Setting`, `Ops.record_event!`), the `header_date` fix at `swimmers_controller.rb:48`, and the characterization request specs for per-phase orchestration. Those specs must stay green, unchanged.
- **02**: legacy flow gone, and team scores stored in `phase2.json` under `data.team_scores` (`team_key`, `rank`, `ind_score`, `overall_score`). The `LEGACY_REDIRECT_FLAGS` guard (`app/controllers/data_fix/base_controller.rb:41-44, 59-60`) and the `redirect_to(..._legacy_path)` lines in every `review_*` action are removed, so the phase flags (`phase_v2` …) are optional. `data_fix_legacy/_modal_progress` has been moved.
- **07**: `Outbox::Writer.write!` / `Outbox::Sequence.next!`. 07 already passes a `before_commit:` callable to `Import::Committers::Main#commit_all` that calls `Outbox::Writer.write!(kind: 'commit', ...)`, so the commit script is registered inside the commit transaction (the number comes from `Sequence.next!`); `CommitArchiver.finalize` only moves files. 09 keeps that callable and the `retry_archive` action in `CommitRunner`. "Committed, archiving failed" exists as its own state.
- **06** (soft; the hard dependencies are 01, 02 and 07): `Health::SeasonRunJob` for the triggered post-commit season checks. If 06 is not shipped, the report keeps the synchronous `DataFix::PostCommitChecks` call.
- **08** (optional): `Drift::Gate.check(scope: :commit, acknowledged: params[:drift_ack] == '1')`, and `DbRestore::Lock` from 14. Both are called through `DataFix::Guards`, which is a no-op when the constants are undefined, so 09 can ship before or after 08 and 14. 08 owns the gate call in `commit_phase6`; 09 keeps it there and repeats it at job start.

## Invariants that apply here

- `DataFixCommitJob` is enqueued only by a controller action triggered by an operator click: never by a scheduler, planner, callback or another job. Retries are disabled (asserted by spec). There is no bulk commit.
- No code path from a prepare job or a planner reaches the commit: 09 adds no job that prepares, and `DataFixCommitJob` has exactly one enqueue site.
- Operator edits win. The authoritative edit marker lives in the phase file `_meta` and is mirrored in `Ops::PhaseVerdict`. An automatic build never rewrites or deletes an edited phase.
- "Staging" means the `data_import_*` tables. There are no admin2-only tables in MySQL: ops data (verdicts, reports, runs, leases, `db_generation`) lives in the ops DB, and values a job computes for the UI never go through `Rails.cache`. File names (`NNNN-<base>-lt4.sql`, `results.new/sent/done/<season>`) stay readable by `DiskIndex`.
- Jobs never broadcast on `ImportStatusChannel`. The client opens the progress modal on any `/data_fix` or `/push` page (`app/javascript/channels/import_status_channel.js:6-7, 43-51`).
- Views created here (stepper, commit summary, commit report) are native Bootstrap 5. Older `app/views/data_fix` templates stay on the compat layer until 12.
- Repo conventions: `# frozen_string_literal: true`, en + it keys, CHANGELOG + PATCH bump in `lib/version.rb` per user-visible step, `bundle exec rubocop -a` clean. Ops migrations run through `bin/rails ops:prepare`, never a bare `db:migrate`.

## Scope

### Orchestration inventory (re-verified; this is what the runner takes over)

Every action that takes a `file_path` first runs `set_source_path` (`base_controller.rb:58-70`), which calls `SourceResolver#resolve_working_source_path` (`app/services/data_fix/source_resolver.rb:62-79`). On a GET or a POST alike, that step can:

- materialize the LT4 copy (`:320-338`) or re-materialize it in place with a `.orig` backup (`:108-112`);
- supersede a manifest copy: back up, then delete phases 1-5 and their staging rows (`:147-159`);
- normalize categories: delete phases 3-5 and their staging rows (`:197-233` → `:424-438`).

Errors are swallowed (`:76-79`).

All five review actions share `ensure_phase_file!` (`base_controller.rb:84-101`): build when the file is missing or `rescan` is set, then redirect with a flash. They also share `sync_phase_retry_flag!` (`source_resolver.rb:382-399`), which rewrites the phase file on **every GET**.

| Phase | Controller work around the solver today | Runner takes over |
|---|---|---|
| 1 | `sessions_controller.rb:10-20` season from path, layout, `Phase1Solver#build!`; `:22` retry flag; `:29` `StructureValidator` (non-blocking); `:34` source `_meta.warnings`; code auto-generation only in `update_phase1_meeting` (`:148-167`) | build + retry flag at build time; validator, warnings and FIN match feed the verdict |
| 2 | `teams_controller.rb:13-19` `TeamSolver#build!`; `:28-35` safety rebuild when the `teams` key is missing; `:52-56` review predicate; `:71` "ready" broadcast | build (missing-key rebuild becomes a `build_needed?` rule); predicate → `ReviewRules` |
| 3 | `swimmers_controller.rb:14-22` `SwimmerSolver#build!`; `:30-41` safety rebuild; `:46-58` relay enrichment detection; `:75` `Phase3Harmonizer.harmonize_phase2_phase3_team_links` (writes phase 2, `phase3_harmonizer.rb:67`); `:85` badge-duplicate annotation (in memory only); `:106-110` predicate | build, then harmonize + annotate (persisted) + enrichment as one post-build step |
| 4 | `events_controller.rb:13-20` `EventSolver#build!`; no issue detection | build; new phase 4 checks |
| 5 | `results_controller.rb:15-33` `ResultSolver#build!` then `Phase5Populator#populate!`; `:84-90` `IssueDetector`; `:153-175` `populate_db`; `:191-197` result-free branch | build; IssueDetector + `CommitPreflight` + auto-verify |
| 6 | `commits_controller.rb:13-20` overwrite confirm; `:29-49` result-free and missing-phase gates; `:51-60` structure gate; `:64` manifest flag; `:66-70` staging gate; `:73-82` file numbering; `:85-120` `Main#commit_all` + `CommitArchiver.finalize`; `:135-177` first-error step hint; `:181-191` report into `session`; `:198-224` report GET (`:220` post-commit scan) | `DataFix::CommitRunner` + `DataFixCommitJob` + `Ops::CommitReport` |

Silent tolerances that become preconditions (`MissingUpstreamError`):

- `SwimmerSolver` (`swimmer_solver.rb:49-50`), `EventSolver` (`event_solver.rb:30`) and the populator (`phase5_populator.rb:92-95`) accept missing upstream files.
- `populate!` deletes staging first, outside any transaction (`phase5_populator.rb:61-83`). It skips results with a blank category (`:204, :292`).
- `populate!` overwrites the `phase5.json` that `ResultSolver` just wrote (`:44`, `:1462-1478`, a plain `File.write` with no `_meta`). So `ResultSolver` output never survives, and `_meta.individual_result_overwrite` is lost on every repopulate.
- A cross-source `import_key` clash silently reuses the other source's row (`phase5_populator.rb:988-995`).
- Team and Swimmer committers create a new row whenever the id is nil, with no name lookup (`committers/team.rb:61-103`, `committers/swimmer.rb:62-103`).
- Progress: `broadcast_progress` is private in `TeamSolver` (`:419`), `SwimmerSolver` (`:1042`), `ResultSolver` (`:251`), `Phase5Populator` (`:1483`, called once per result row at `:202, :290`), `Main` (`:1752`) and `BaseController` (`:216`). `CategoryRecomputer` already takes a `progress:` callable (`category_recomputer.rb:14-19`); that is the pattern to copy.

### New files

- `app/services/data_fix/pipeline.rb`: `DataFix::Pipeline`, plus `pipeline/recipes.rb` (the five build recipes, moved as they are) and `pipeline/digests.rb` (input projections).
- `app/services/data_fix/review_rules.rb`: `DataFix::ReviewRules`.
- `app/services/data_fix/verdict.rb`: `DataFix::Verdict` (`Data.define`), with `verdicts/phase{1..5}.rb` checkers.
- `app/services/data_fix/commit_runner.rb`, `app/services/data_fix/result_verifier.rb`, `app/services/data_fix/guards.rb`.
- `app/strategies/import/progress.rb`: `Import::Progress::{Cable,Null,Ops}`.
- `app/strategies/import/commit_preflight.rb`: `Import::CommitPreflight`.
- `app/jobs/data_fix_commit_job.rb`.
- `app/models/ops/{pipeline_source,phase_verdict,commit_report,pipeline_run}.rb`, with `db/ops_migrate/*`.
- `app/components/data_fix/stepper_component.{rb,html.haml}`; views `app/views/data_fix/commit_summary.html.haml` and `app/views/data_fix/commit_reports/show.html.haml`.
- `config/locales/data_fix_pipeline.{en,it}.yml`.

### Files modified

- `app/controllers/data_fix/{base,sessions,teams,swimmers,events,results,commits}_controller.rb`
- `app/services/data_fix/source_resolver.rb`, `phase3_harmonizer.rb`, `commit_archiver.rb`
- `app/services/phase_file_manager.rb`: atomic write (tmp + rename) and a `data_digest` helper
- the solvers, `phase5_populator.rb`, `committers/main.rb` (`progress:` keyword)
- `app/views/data_fix/_v2_phase_header.html.haml` (renders the stepper); `_step_tabs.html.haml` and `commit_phase6_report.html.haml` are deleted
- `config/routes.rb`, `config/queue.yml`
- `docs/data_fix/{PHASES,TECHNICAL}.md`, `AGENTS.md` (Data-Fix section)

### DataFix::Pipeline API

```ruby
# frozen_string_literal: true
module DataFix
  class Pipeline
    class EditedPhaseError < StandardError; end     # build of an edited phase without force
    class MissingUpstreamError < StandardError; end  # e.g. phase 3 without phase 1/2
    class LeaseBusyError < StandardError; end        # another request/job is building this source

    def self.for(file_path, progress: Import::Progress::Cable.new, actor: :operator)
    attr_reader :source_path, :season, :base       # base = SeasonBoard::DiskIndex base name

    def build_phase!(n, force: false)              # one recipe; stamps _meta['built']; returns Verdict
    def prepare!(up_to: 5, phases: nil, deadline: nil) # builds missing + stale-and-unedited phases in order
                                                   # (`phases:` restricts it, used by phase 10's collision rebuild),
                                                   # stops at the first edited-and-stale phase (raises
                                                   # nothing: records a :stale verdict with reason :edited)
    def verdict(n, refresh: false)                 # DataFix::Verdict(status:, issues:, counts:, new_entities:)
    def stale?(n)                                  # [] or [{ upstream: 2, what: 'team ids' }]
    def edited?(n); def mark_edited!(n, action:)   # authoritative in _meta, mirrored to ops
    def restamp!(n)                                # runner-made writes (cascades, harmonizer) are not edits
    def summary                                    # per-phase verdicts + overall stage, read by stepper/board
    def meeting_date                               # flat phase 1 'header_date' || SourceResolver#source_meeting_date
    def refresh_new_entities!                      # re-resolve nil-id teams/swimmers only (step 9)
    def invalidate!(phases:, reason:)              # the only path that deletes phase files (see below)
  end
end
```

Controllers become thin callers:

- `ensure_phase_file!` calls `pipeline.build_phase!(n, force: params[:rescan].present?)`. Only the rescan link passes `force`, and it already asks for confirmation (`_step_tabs.html.haml:16`, moved into the stepper). Jobs never pass it.
- The two safety rebuilds (`teams_controller.rb:28-35`, `swimmers_controller.rb:30-41`) and the no-op "clear downstream" block (`teams_controller.rb:286-292`, plus its siblings if 02 left any) are removed.
- One `after_action :mark_phase_edited!` covers every mutating action. These are the `update_*`, `add_*`, `delete_*`, `merge_phase3_swimmers`, `rescan_phase1_sessions`, `toggle_individual_result_overwrite`, `*_overwrite_candidate`, `bulk_update_individual_result_overwrite` and `confirm_result_duplicate` actions, each mapped to its phase. It runs only on a successful redirect.

### Edit protection

- `_meta['built'] = { 'by' => 'auto'|'operator', 'at', 'digest' => sha256(canonical data), 'inputs' => {...} }` is written by the runner on every build or restamp.
- `_meta['operator_edit'] = { 'at', 'user_id', 'actions' => [last 20 action names] }` is written by `mark_edited!`.
- `edited?(n)` is true when `operator_edit` is present, or when the digest of `data` differs from `built.digest` (this catches hand edits through `file_list_controller.rb`), or when `built` is absent. A file without a `built` stamp is **adopted as edited**: every phase file that exists when this phase ships is protected.
- `_meta` is excluded from the digest, so retry-flag or overwrite-meta writes are not edits. The runner-made writes (`TeamCascade.cascade_team_to_phase3` `team_cascade.rb:59`, harmonizer `phase3_harmonizer.rb:67`, auto-verify) call `restamp!`.
- `Ops::PhaseVerdict.operator_edited_at` mirrors the marker. If ops is wiped, the file still protects itself. `mark_edited!`, every verdict write and every stage change call `SeasonBoard::Snapshot.invalidate!(season_id)` (05), because in-place phase edits do not change directory mtimes.
- **Team scores** (stored by 02 in `phase2.json` under `data.team_scores`: `team_key`, `rank`, `ind_score`, `overall_score`). They are part of the phase 2 `data`, so the build digest and `edited?(2)` cover them. A Phase 2 build or rebuild rebuilds them from the source (`build_phase!(2)`, `invalidate!(phases: [2, ...])` and the verdict's `stale` reasons treat it that way), while team edits stay keyed by `team_key`. They are not a review item and do not feed the phase 3/5 input digests. `CommitPreflight` warns when a score's `team_key` has no team entry. The commit summary lists them and the commit report stats carry `team_scores_created`, `team_scores_updated` and `team_scores_skipped` from `Main`.
- **SourceResolver's destructive branches go through `Pipeline#invalidate!`.** `normalize_lt4_result_categories` (`source_resolver.rb:224`) and `supersede_manifest_copy!` (`:152-153`) no longer call `invalidate_category_dependent_artifacts` directly. They return an invalidation request. `invalidate!` deletes only unedited phases, after the existing `.orig` backups (`backup_phase_files`, `:164-171`). When any target phase is edited, it deletes nothing, marks the source `blocked` with reason `source_changed_under_edits`, and the step header offers "Rebuild (discard edits)", which is a POST with confirmation.
- The operator's `recompute_source_categories` (`sessions_controller.rb:80`) goes through the same path. Its confirmation lists any edited phases it would discard.

### Staleness: input digests per phase

`parent_checksum` is written only by phases 1-3 (`phase1_solver.rb:102`, `team_solver.rb:107`, `swimmer_solver.rb:180`) and is never read. `PhaseFileManager#dependencies_satisfied?` (`phase_file_manager.rb:63-74`) is a placeholder. Both are replaced by `built.inputs`: each value is a SHA256 of a canonical-JSON projection, so unrelated edits do not cascade.

| Phase | Inputs (projection) |
|---|---|
| 1 | source file sha256; season id from path |
| 2 | source sha256; season id |
| 3 | source sha256; P1 `header_date`, `season_id`; P2 `teams[key → team_id]`, `team_affiliations[team_key → team_affiliation_id]` |
| 4 | source sha256; P1 `id`; P1 `meeting_session[session_order, id]` |
| 5 | source sha256; P1 `id`, `header_date`, sessions; P2 key → team_id; P3 `swimmers[key → swimmer_id, category_type_id]`, `badges[swimmer_key, team_key → badge_id]`; P4 `sessions[session_order, events[key, session_order, meeting_event_id, event_type_id]]`; plus `db_generation` when nil-id entities exist |

`stale?(n)` compares the stored inputs with fresh projections. Cascades keep phases 3 and 5 in step (`TeamCascade`, `SwimmerCascade`), so the runner re-stamps after a cascade instead of flagging. Phase 4 edits (`events_controller.rb:111-375`) change the P5 input digest. When Step 5 opens on a stale, unedited phase 5, it rebuilds automatically. When phase 5 holds fixes or an overwrite selection, the step asks first.

### Verdicts (statuses: `unbuilt`, `clean`, `review`, `blocked`, `stale`, `failed`)

`blocked` means the commit would fail. `review` means an operator decision is needed. `failed` means the build raised (the message is stored).

| Phase | Blocked (grounded in) | Review |
|---|---|---|
| 1 | `StructureValidator#valid?` false (`structure_validator.rb:53`); retry flag (`source_resolver.rb:346-359`); FIN id already linked to another meeting (read-only copy of `committers/calendar.rb:141-151`) | meeting not matched by `meeting_match.source == 'fin_event_id'` (`phase1_solver.rb:282`) and not saved by the operator; `_meta.warnings` present (`sessions_controller.rb:34`); a session without id in an existing meeting |
| 2 | — | per `ReviewRules.team_needs_review?` |
| 3 | gender or year missing; category unresolved (`committers/badge.rb:110-114` raises); badge `team_key` absent from phase 2 | per `ReviewRules.swimmer_needs_review?`; relay-enrichment summary not empty |
| 4 | event type unresolvable (`committers/main.rb:1337-1360`, `committers/meeting_event.rb:36-39`); event `session_order` missing from phase 1 (silently skipped, `main.rb:366-369`); event `session_order` ≠ its parent session (lookup key at `main.rb:384-387`) | unmatched events in a meeting that already has events |
| 5 | `populate_stats[:errors]`; cross-source collisions; source result count ≠ staged rows; `IssueDetector` count > 0 (today's gate, `review_results.html.haml:37`); `CommitPreflight` errors | overwrite mode with selections; partial duplicate matches from auto-verify |

A result-free source (`SourceResolver#source_result_free?`, `:290-306`) is clean when phase 1 is structurally valid and nothing is staged, which mirrors `commits_controller.rb:29-34, 51-60`.

### DataFix::ReviewRules (the ready rule, in full)

A source is **ready to commit** when all five phase verdicts are `clean` and fresh (none `stale`, `blocked`, `review` or `failed`) and `CommitPreflight` reports no errors. One module used by the filters (`teams_controller.rb:52-56`, `swimmers_controller.rb:106-110`), the verdicts and the commit summary. Constants: `MATCH_BAR = 89.0`, `MAX_NEW_SWIMMER_SHARE = 0.40`, `MAX_NEW_TEAM_SHARE = 0.25`.

- **Confidently new swimmer**: `swimmer_id` nil, `fuzzy_matches` empty, and `gender_type_code`, `year_of_birth` and `category_type_id` all present.
- **Confidently new team**: `team_id` nil, `fuzzy_matches` empty, and `similar_affiliated` false (`team_solver.rb:185`).
- Confidently-new entities **do not** send a phase to review. They are counted in `Verdict#new_entities` and listed on the commit summary.
- **Review is required** for:
  1. a meeting not matched by FIN event id and not saved by the operator (phase 1);
  2. any team with a candidate: `team_id` nil with `fuzzy_matches` or `similar_affiliated`, or a `phase3_conflict_hint?` (`phase3_harmonizer.rb:84`);
  3. any match under the 89 % bar that the operator has not confirmed. For swimmers this includes `gender_guessed` (`swimmer_solver.rb:435`), `auto_assigned_from_secondary_match` (`:479`) and `has_badge_duplicates` (persisted in step 5). A non-new nil-id swimmer is also in review;
  4. more than 40 % new swimmers, or more than 25 % new teams, in the source.
- `confirmed: true` is set on the row by `update_phase2_team` / `update_phase3_swimmer`, and by an explicit "Confirm" on a card. Confirmed rows never count as review. A rebuild drops `confirmed`, because it builds a fresh file. That is one more reason edited phases are not rebuilt automatically.
- The 'similar_on_team' check stays out of the filter, as the existing warnings in both controllers state.
- Threshold facts: the swimmer finder returns candidates only at ≥ 0.89, or 0.80 on the fallback (`swimmer_solver.rb:549-556`), and auto-assigns at 0.60 (`:643-647`). So a gender-known nil-id swimmer always has an empty candidate list. Teams auto-assign at 0.81 (`team_solver.rb:270-275`), so teams have a real grey band between 0.81 and 0.89.

### Import::CommitPreflight

Modelled on `StructureValidator`. It writes nothing and returns `errors` / `warnings` with a phase hint each. It covers what today only `Committers::Main` finds:

- program → event key: `"#{session_order}-#{event_key}"` must exist in phase 4 (`main.rb:609-617`);
- category and gender resolvable, with the relay fallbacks (`main.rb:650-680`, `resolve_category_type` `:697`);
- overwrite snapshot validity (`main.rb:416-433`, `IndividualResultOverwriteReconciler.commit_plan_for`);
- the FIN link conflict (`calendar.rb:141-151`);
- **exact-name check**: every nil-id team (by `editable_name`/`name`) and nil-id swimmer (by `complete_name` + `year_of_birth` + gender) that would be created is looked up by exact name in the local DB. A hit is an error ("would duplicate team 123; refresh matches"), with a one-click "Refresh matches" that calls `refresh_new_entities!`.

It runs in the phase 5 verdict, on the commit summary page, and again at commit job start.

### Phase5Populator hardening

- **Loud collisions**: on `RecordNotUnique`, the populator no longer falls back to `find_by(import_key:)` (`:993-995`). When the existing row belongs to another `phase_file_path`, it records `stats[:collisions] << { import_key, other_source }`, and the phase 5 verdict is `blocked` ("waiting for `<other>` to be committed"). After that other source commits, the colliding phase 5 is re-prepared.
- **Parity check**: source result rows minus blank-category skips must equal staged rows; the difference is reported per program.
- **Transactional repopulate**: truncate + insert run in one `ActiveRecord::Base.transaction`. Progress writes stay outside it. Ops writes happen after it.
- **Overwrite metadata preserved**: `write_phase5_output!` writes through `PhaseFileManager`, keeping the existing `_meta` (overwrite snapshot, `operator_edit`, `built`). `ResultSolver` is dropped from the phase 5 recipe, because its output is always overwritten.

### Matching freshness

- `Ops::Setting['data_fix.db_generation']` is bumped by every successful local commit. Each verdict stores the generation it was computed under.
- A verdict with new entities whose generation is behind becomes `stale` (reason `db_changed`). Opening the step, or the summary's "Refresh matches", runs `refresh_new_entities!`. It re-resolves only nil-id entries, using a per-entry re-resolve method on `TeamSolver`/`SwimmerSolver` that reuses `find_team_matches` / `find_swimmer_matches`. Operator-set ids, confirmed rows and edits are left alone, and the file is restamped.
- Phase 10's planner queues this refresh for prepared sources. In 09 the refresh runs on open.

### Commit runner, job, report, summary

- `GET data_fix/commit_summary?file_path=` (`CommitsController#summary`, route `get 'data_fix/commit_summary', to: 'data_fix/commits#summary', as: 'data_fix_commit_summary'`, the helper 10 and 12 link to) shows: meeting and how it was matched, counts per entity (existing / new), the confidently-new teams and swimmers, results to create or update, overwrite deletions, a fresh preflight, one Commit button (a `button_to commit_phase6_path`, so the existing form action stays), and a link to Step 5. Step 5 gains a link to this page and keeps its own `button_to commit_phase6_path` (pinned by `spec/requests/data_fix_controller_structure_commit_spec.rb:113-127`; both buttons hit the same POST, with the same preflight and guards, so there is still exactly one commit per click).
- `POST data_fix/commit_phase6` (route kept, `config/routes.rb:81`) runs the overwrite confirmation (`commits_controller.rb:17-20`), `CommitPreflight` and `DataFix::Guards.check(:commit, acknowledged: params[:drift_ack] == '1')` (no-op-safe: calls `Drift::Gate.check(scope: :commit, acknowledged:)` when `defined?(Drift::Gate)` and `DbRestore::Lock.active?` when defined; `Guards.check(:prepare)` is the same wrapper with `scope: :prepare`, used by phase 10). A `block` verdict refuses with a flash linking `/db_sync`; a `warn` verdict re-renders the summary with the tick (08). It then creates `Ops::CommitReport(status: 'queued', requested_by_user_id: current_user.id)`, enqueues `DataFixCommitJob.perform_later(commit_report_id:)` and redirects to `GET data_fix/commit_reports/:id`.
- `DataFixCommitJob` (inherits `ApplicationJob`, so the 08/14 `around_perform` guards apply): `queue_as :pipeline`, `queue_with_priority 0`, `limits_concurrency key: 'local_db_writer', to: 1, duration: 1.hour`. That key is shared with `Maintenance::RunJob` in apply mode (11), because both write the local primary DB; phase 10's `DataFixPrepareJob` uses `data_fix_pipeline` instead. It does not use `retry_on`/`discard_on`, and it never raises: the same pattern as `MeetingCrawlJob`. It moves the report `queued → running` with a conditional update; when the row is not `queued`, or `requested_by_user_id` is nil, it refuses. It re-runs preflight and `DataFix::Guards.check(:commit, acknowledged:)` (the acknowledged flag is stored in the report's `preflight` json by the POST), then calls `DataFix::CommitRunner#call`. It is enqueued only by `CommitsController#commit_phase6`.
- `DataFix::CommitRunner` holds `commits_controller.rb:22-177` as it is, with these changes: the numbering block at `:73-82` goes away: the script is registered through 07's `before_commit:` callable (`Outbox::Writer.write!`, numbered by `Outbox::Sequence.next!`), and the `retry_archive` action of 07 stays; progress via `Import::Progress::Ops` (report row, throttled to about 1 per second); success split into `committed` and `committed_archive_failed`, with `CommitArchiver.finalize` made resumable. After success it bumps `db_generation`, calls `Ops.record_event!(kind: 'commit', ...)` (en + it keys `ops.events.commit`), enqueues `Health::SeasonRunJob` for the season's `results` and `badges` groups (06) and stores their run ids on the report. The report page shows those runs in a lazy frame. Without 06 it falls back to `PostCommitChecks.build_post_commit_checks_report` (`post_commit_checks.rb:10`), stored as JSON.
- The report page (native BS5) reads the row by id and polls its frame while the status is `queued`/`running`. It shows stats, the first error step (the `phase_hint_map`, `commits_controller.rb:143-160`), the log path, an Outbox link and season checks. `session[:commit_report]` is removed.
- `DataFix::ResultVerifier` is extracted from `verify_result` (`results_controller.rb:402-482`). It runs after populate (exactly one perfect match, never an overwrite merge target, idempotent) and from a POST "Verify all" endpoint. The button itself ships in 12. The current GET `data_fix/verify_result` (`routes.rb:97`) stays for the JS until 12.
- `DataFix::StepperComponent` replaces `_step_tabs.html.haml` (51 lines, five copied blocks). It reads `pipeline.summary` and is rendered by `_v2_phase_header`. Labels go to i18n (`data_fix.steps.*`).

## Data model

Ops migrations in `db/ops_migrate/`, one per table, created by `bin/rails ops:prepare`. `!` = NOT NULL.

**pipeline_sources**: `season_id!`, `base!`, UNIQUE(`season_id`, `base`), `fin_event_id`, `source_kind` (results|manifest|result_free), `source_path`, `source_sha256`, `stage!` (new|preparing|needs_review|blocked|ready_to_commit|committing|committed|failed, default new), `review_phase`, `review_count`, `new_teams_count`, `new_swimmers_count`, `db_generation`, `lease_owner`, `lease_expires_at`, `prepared_at`, `committed_at`, timestamps. Indexes: `fin_event_id`, `stage`. The key is the `DiskIndex` base, which stays stable from results.new to results.done and covers non-FIN sources. Rebuildable from disk.

**phase_verdicts**: `pipeline_source_id!` FK, `phase!` (1..5), UNIQUE(source, phase), `status!`, `issues_count!` default 0, `issues` json (capped at 200), `counts` json, `new_entities` json (capped), `built_by`, `built_at`, `built_digest`, `input_digests` json, `operator_edited_at`, `confirmed_count`, `db_generation`, `checked_at`, timestamps. Recomputable, except that `operator_edited_at` is a mirror of the file marker.

**commit_reports**: `pipeline_source_id` FK, `season_id`, `source_base!`, `source_path`, `status!` (queued|running|committed|committed_archive_failed|failed|refused), `requested_by_user_id!`, `requested_at!`, `started_at`, `finished_at`, `job_id`, `preflight` json, `summary` json, `stats` json, `error_message`, `first_error_phase`, `log_rel_path`, `sql_rel_path`, `sql_script_id` (07), `done_dir`, `meeting_id`, `health_run_ids` json, `post_commit_checks` json, `db_generation_after`, timestamps. Indexes: `status`; (`source_base`, `created_at`). Not unique per source, because re-imports happen. Not rebuildable.

**pipeline_runs** (the runs/lease record): `pipeline_source_id` FK nullable, `subject_key!` (base, FIN id or PDF name), `kind!` (build|prepare|refresh|commit|extract), `origin!` (operator|auto), `status!` (queued|running|done|failed|yielded|refused), `phase`, `progress`, `total`, `message`, `error`, `job_id`, `started_at`, `finished_at`, timestamps. Indexes: (`subject_key`, `kind`, `created_at`); `status`.

Why a separate table: background builds need throttled progress that the UI can read, and the decision forbids `ImportStatusChannel` for that. It also gives stale-run detection (the counterpart of `ActivityLog::RUNNING_STALE_AFTER`) and history for "prepare failed" items, and phase 10 counts extraction attempts per PDF here. Keyed by `subject_key`, it covers non-FIN sources. The lease itself is two columns on `pipeline_sources`, taken with one conditional `UPDATE … WHERE lease_owner IS NULL OR lease_expires_at < now`. That is atomic under SQLite `BEGIN IMMEDIATE` and avoids row-lock tables.

`Ops::Setting` key added: `data_fix.db_generation` (integer).

## Ordered steps

1. **Progress injection** (no behaviour change). Add `Import::Progress::{Cable,Null,Ops}` and a `progress:` keyword (default `Cable`) on the solvers, the populator, `Main` and the `BaseController#broadcast_progress` callers. The populator's per-row broadcasts are throttled in `Ops`/`Null` only. No CHANGELOG.
2. **Ops tables + models** (no behaviour change). Four migrations, models, factories in `spec/factories/ops/`, model specs, and a reconciler registered with `Ops::Rebuilders.register` (01's `rake ops:rebuild` registry) that recomputes `pipeline_sources` and `phase_verdicts` from `DiskIndex` and the phase files; `commit_reports` and `pipeline_runs` are not rebuildable. No CHANGELOG.
3. **Runner extraction** (no behaviour change). `DataFix::Pipeline` with the five recipes, upstream preconditions and the lease. `ensure_phase_file!` delegates. The safety rebuilds become `build_needed?`. The 01 characterization specs pass unchanged. No CHANGELOG.
4. **Edit markers + guarded invalidation.** `built`/`operator_edit` stamps, adoption of existing files, `after_action :mark_phase_edited!`, SourceResolver branches routed through `invalidate!`, atomic `PhaseFileManager#write!`. User-visible: "source changed under your edits" banner. CHANGELOG + PATCH.
5. **Review GETs stop writing.** The retry flag is written at build time and computed in memory on GET. The harmonizer and duplicate annotation run as a post-build step and after phase 2 saves. Spec: no review GET changes any file mtime. CHANGELOG + PATCH (persisted duplicate flags).
6. **ReviewRules + `confirmed`.** Filters and solver thresholds use it, and gender-guessed swimmers enter review. CHANGELOG + PATCH.
7. **Verdicts 1-4, staleness, stepper.** `Ops::PhaseVerdict` writes, `pipeline.summary`, `StepperComponent` (BS5). Phase 4 → 5 banner and auto-rebuild of an unedited phase 5. CHANGELOG + PATCH.
8. **Phase 5 hardening.** Populator (collisions, parity, transaction, meta kept), `CommitPreflight`, `ResultVerifier` after populate, phase 5 verdict. CHANGELOG + PATCH.
9. **Matching freshness.** `db_generation` bump, `refresh_new_entities!`, exact-name preflight check. CHANGELOG + PATCH.
10. **CommitRunner + persistent report**, still synchronous inside the POST. Report stored in `Ops::CommitReport`, `GET data_fix/commit_reports/:id`, `session[:commit_report]` removed, the four structure-commit specs and `commits_controller_helpers_spec.rb:403-470` rewritten to read the report row. CHANGELOG + PATCH.
11. **Commit summary + job.** `pipeline` worker added to `config/queue.yml`, plus `limits_concurrency`. `DataFixCommitJob`, summary page, guards, triggered health run, and `spec/config/queue_names_spec.rb` (from 06) now covers `pipeline`. Commit specs use `perform_enqueued_jobs`. CHANGELOG + PATCH.
12. **Docs.** `docs/data_fix/PHASES.md` and `TECHNICAL.md`: runner, verdicts, edit markers, commit job. `AGENTS.md`: the Data-Fix canonical-source note on `invalidate!`. No version bump.

`config/queue.yml` worker added in step 11 (keep the file's comment style):

```yaml
    - queues: pipeline
      threads: 1
      processes: 1
      polling_interval: 1
```

## Specs and manual verification

- `spec/services/data_fix/pipeline_spec.rb`: recipes, preconditions, lease, `prepare!` skipping edited phases, `invalidate!` refusing on edits.
- `spec/services/data_fix/review_rules_spec.rb`: one example per ready-rule clause, using the fixtures below.
- `spec/services/data_fix/verdicts/phase{1..5}_spec.rb`; `spec/strategies/import/commit_preflight_spec.rb`; `spec/strategies/import/phase5_populator_collision_spec.rb`.
- `spec/jobs/data_fix_commit_job_spec.rb`:
  - refuses a report not in `queued`, and one without `requested_by_user_id`;
  - `DataFixCommitJob.rescue_handlers` is empty;
  - a duplicate perform commits once;
  - the commit never runs when `DataFix::Guards` returns a reason;
  - `limits_concurrency` key is `local_db_writer` (the key `Maintenance::RunJob` in apply mode also uses), and the queue is `pipeline`.
- `spec/requests/data_fix/no_write_on_get_spec.rb`: file mtimes and digests unchanged after each `review_*` GET on a built source.
- Static spec: `DataFixCommitJob` is referenced only by `app/controllers/data_fix/commits_controller.rb` and by specs.
- Fixtures in `spec/fixtures/data_fix/pipeline/`: `clean_fin` (FIN-matched meeting, all ids, 2 new teams and 37 new swimmers under the shares), `new_meeting`, `team_candidate`, `grey_match_unconfirmed`, `grey_match_confirmed`, `too_many_new_swimmers` (41 %), `too_many_new_teams` (26 %), `new_swimmer_missing_category`, `gender_guessed`, `result_free_manifest`.
- Manual check:
  1. Open a fresh source, confirm the stepper verdicts, and edit a Phase 4 event. Step 5 should show stale; open it and it rebuilds.
  2. Save a grey team and watch it leave review.
  3. Open the commit summary and commit. The report should refresh to "committed", reopen from its URL and link to the Outbox.
  4. Hand-edit a phase file and trigger category normalization. The banner should appear, and no file should be deleted.

## Exit criteria

- The phase 01 characterization request specs pass **unchanged**. Commit specs are updated only in steps 10-11, and only where they read `session[:commit_report]` or rely on the synchronous POST.
- The ready rule has one passing fixture case per clause:
  - `clean_fin` → ready, listing 2 teams and 37 swimmers;
  - `new_meeting` → review at step 1;
  - `team_candidate` → review at step 2;
  - `grey_match_unconfirmed` → review; `grey_match_confirmed` → clean;
  - `too_many_new_swimmers` → review at step 3; `too_many_new_teams` → review at step 2;
  - `new_swimmer_missing_category` → blocked at step 3 (a new swimmer without gender, year or category is not "confidently new");
  - `gender_guessed` → review at step 3 (a match under the 89 % bar, and the 89.9 % value no longer hides it);
  - `result_free_manifest` → clean once phase 1 is valid.
- A Phase 4 edit marks Phase 5 stale. An edited phase is never deleted by category normalization or manifest supersede (spec).
- No review GET writes to disk (spec). No job broadcasts on `ImportStatusChannel` (spec using `Import::Progress::Null`/`Ops`).
- A commit runs only from a click, as a job on `pipeline`, with its report reopenable by URL. "Committed, archiving failed" is shown as its own state.
- A cross-source `import_key` collision blocks phase 5 with the other source named, instead of silently reusing that source's row.
- Routine gate passes: sign in → board → crawl → review → commit (summary → job → report) → push from the Outbox → confirm.

## Risks and mitigations

- **Behaviour drift during extraction.** Steps 1-3 are pure moves, guarded by the 01 characterization specs plus a byte-compare of phase files built before and after on the fixtures.
- **Adopted-as-edited blocks rebuilds of old sources.** The operator rescan (with confirmation) still forces. The stepper labels adopted phases "edited (pre-existing)".
- **Commit waits behind a prepare (phase 10) on the single thread.** Commit priority 0. The prepare job yields between phases when a `queued` commit report exists (specified in 10).
- **Commit job runs in a Solid Queue process, not Puma.** The runner uses no request state: the solvers, populator and `Main` read no session, JWT or API (verified by grep). The log and SQL paths stay under `crawler/data`.
- **Ops DB missing.** The edit marker still lives in `_meta`, and verdicts are computed on the fly and not stored. The commit button is disabled, with the "run `bin/rails ops:prepare`" notice, because the report needs ops.
- **Exact-name check false positives** (homonyms). It is an error with "Refresh matches" or "Create anyway (confirmed)", recorded on the report.
- **A queued commit and a running prepare (10) share the `pipeline` worker.** They use different concurrency keys, so the worker must stay at 1 thread / 1 process in `config/queue.yml`; that is what serialises them.
- **SQLite contention.** Progress throttled to about 1 per second, short transactions, the lease as columns.

## Decisions to confirm

- Staging-key collisions: **default admin2-only handling** (detected, blocked, re-prepared after the other source commits). The alternative is a goggles_db migration scoping `import_key` per source, which touches the engine, goggles_api, goggles_main and production. Not in scope.
- Files that exist when this ships are adopted as edited: **default yes**.
- Commit without ops DB: **default refuse with notice** (no synchronous fallback).
- `ResultSolver` dropped from the phase 5 recipe: **default yes** (its output is always overwritten).
- Exact-name hit: **default blocking**, with an explicit "create anyway" override.
- Step 5 keeps its own Commit `button_to` next to the link to the summary: **default yes** (spec-pinned; same POST either way).

## Out of scope

Any job that prepares phases, the planner and the board/inbox states (10); native BS5 for the older Data-Fix views, Turbo-frame saves, next-issue navigation and the "Verify all" button (12); a per-source staging key in goggles_db; push changes (07/08); a bulk commit.

## Outcome (done, 0.10.88, 2026-11-23)

Delivered on `feature/modernize-admin-console-ux` (steps 1-12, implemented in one pass in the same working tree as phase 08, which shipped `Drift::Gate` meanwhile). All six decisions confirmed with their defaults (admin2-only collision handling, existing files adopted as edited, commit refused without the ops DB, `ResultSolver` dropped from the Phase 5 recipe, exact-name hit blocking with "Create anyway", Step 5 keeps its own Commit button). The 01 characterization spec `spec/requests/data_fix/phase_orchestration_characterization_spec.rb` passes **unchanged** (12 examples). Targeted runs (no full suite): the Data-Fix request / service / strategy / job / component / view / model / config specs with navigation, BS4 ratchet and i18n parity (990 examples, 0 failures, 1 pending, final run); season board, inbox, dashboard, ops rake + Data-Fix (964, 0 failures); an earlier wider set incl. all components, views, routing and models (1,472, 2 failures since fixed: the rebuilder names of `application_record_spec` and one intermittent "database is locked" on the shared ops test DB, green on rerun). After 08 finished: `spec/requests/data_fix` + `spec/services/data_fix` + `application_record_spec` 180 examples, 0 failures; the system specs `data_fix_spec`, `pdf_to_data_fix_spec` and `outbox_spec` (6 examples) green in light and in dark (`SYSTEM_THEME=dark`). Rubocop clean on every Ruby file touched, the new templates are haml-lint clean (the old `review_results` / `review_sessions` templates gain no new lint). Notes for later phases:

- **Names as shipped.**
  - Services: `DataFix::Pipeline` (`for`, `db_generation`, `bump_db_generation!`, `build_phase!(n, force:, strict_upstream:)`, `prepare!(up_to:, phases:, deadline:)`, `build_needed?`, `verdict(n, refresh:)`, `summary(refresh:)`, `stale?`, `db_stale?`, `edited?`, `adopted?`, `mark_edited!(n, action:, user_id:)`, `restamp!(n, keys:, generation:)`, `settle!`, `retry_needed?`, `meeting_date`, `refresh_new_entities!`, `harmonize!`, `invalidate!(phases:, reason:, force:)`, `source_row`, `last_build_result`, `relay_enrichment_count=`) with `Pipeline::{Recipes, Digests, Summary}`; `DataFix::{Verdict, Verdicts::Base, Verdicts::Phase1..5, ReviewRules, Guards, CommitRunner, CommitSummary, ResultVerifier, PipelineReconciler}`; `Import::Progress::{Cable, Null, Ops}`; `Import::CommitPreflight` (`Result#ok?`, `#to_h`, `#exact_name_hits`).
  - Ops (migrations `db/ops_migrate/202611235000{01..04}_*`): `Ops::PipelineSource` (`STAGES`, `SOURCE_KINDS`, `SOURCE_CHANGED_UNDER_EDITS`, `.base_for`, `.season_id_for` (0 for a non-numeric folder), `.for_path!`, `#acquire_lease!` / `#release_lease!` / `#leased_by_other?`), `Ops::PhaseVerdict` (`ISSUES_CAP`, `.capped_issues`), `Ops::CommitReport` (`STATUSES`, `STAT_GROUPS`, `.stat_rows`, `#claim!`, `#record_progress!`, `#finish!`, `#refuse!`, `#first_error_step_key`), `Ops::PipelineRun` (model and table only: nothing writes it in 09). `Ops::Rebuilders` key `:data_fix_pipeline` (`config/initializers/data_fix_pipeline.rb`). Setting `data_fix.db_generation`.
  - Job `DataFixCommitJob` (queue `pipeline`, priority 0, `limits_concurrency key: 'local_db_writer'`); worker `pipeline` (1 thread, 1 process) in `config/queue.yml`, in `spec/config/queue_names_spec.rb`.
  - UI: `DataFix::StepperComponent` (rendered by `data_fix/_v2_phase_header`; keeps one `ul.nav-tabs .nav-link` per step and the "Step N • Label" texts, identical in en and it as before), `data_fix/commit_summary` (+ `commit_summary/_overview`, `_preflight`), `DataFix::CommitReportsController` (`show`, `status`, `health` frames) with `data_fix/commit_reports/{show,_status,_outcome,_stats,_health,_legacy_checks}`; locales `config/locales/data_fix_pipeline.{en,it}.yml` (`data_fix.steps.*`, `data_fix.stepper.*`, `data_fix.verdicts.*`, `data_fix.pipeline.*`, `data_fix.commit_summary.*`, `data_fix.commit.*`, `data_fix.commit_report.*`).
  - Routes: `data_fix_commit_summary` (`GET data_fix/commit_summary`), `data_fix_commit_report` / `_status` / `_health` (`GET data_fix/commit_reports/:id[/status|/health]`), `data_fix_discard_phase_edits`, `data_fix_refresh_matches`, `data_fix_verify_all_results` (POSTs); `commit_phase6` and `data_fix_retry_archive` kept (`retry_archive` now takes `commit_report_id` and updates the report); `GET data_fix/commit_phase6_report` removed with `session[:commit_report]`. Navigation: `data_fix/commit_reports` added to the `:data_fix` item.
- **Deviations.**
  - **Review GETs.** "No review GET writes" would have broken the unchanged 01 characterization spec (it pins one metadata-only write of the step's own phase file on every render, cold and warm start). Shipped: GETs never write phase data or other files; the only GET writes are idempotent `_meta` syncs made once per file (`Pipeline#settle!`: retry flag, adopted stamp) and the Step 3 harmonizer's NEW conflict hints into phase 2 (re-stamped; also run after a Phase 2/3 build and after each Phase 2 save). `spec/requests/data_fix/no_write_on_get_spec.rb` asserts that a settled source is never written by any review GET, and that no GET changes phase data. The retry flag is therefore written on the first GET, not at build time. Flipping to "never write" is a small change (drop `settle!` from the review actions) plus two expectations of the characterization spec.
  - **Duplicate-badge flags** are computed in memory (a pure function of the phase 3 data, as before), not persisted: the review page and the Phase 3 verdict compute the same flags, also for hand-written files.
  - **Upstream preconditions** (`MissingUpstreamError`) are strict for `prepare!` / jobs only; the interactive builds pass `strict_upstream: false` (the solvers' former tolerance, pinned by the phase 3 rescan specs).
  - **Review filter vs verdict.** The verdict excludes confidently-new teams / swimmers (they go to `new_entities`); the page's "review" filter also keeps the unconfirmed nil-id rows (`ReviewRules.team_in_review_filter?` / `swimmer_in_review_filter?`), otherwise the phase 2/3 request specs (and the operator's view of what will be created) would change. Confirmed rows leave both.
  - **Collisions.** The `data_import_*` models validate `import_key` uniqueness, so a cross-source key surfaced as a `RecordInvalid` "MIR error" (not a silent reuse as the plan said); both that and `RecordNotUnique` now record `stats[:collisions]` and skip the row.
  - **Events.** The commit keeps the existing kinds `datafix.committed` / `datafix.commit_failed` / `datafix.archive_failed` / `datafix.archived` (05's snapshot fingerprint and the activity log read them) instead of a new `commit` kind.
  - **Health runs.** `CommitRunner#enqueue_health_runs` first enqueues `results` and `badges` with `Health::SeasonRunJob.enqueue` (their ids go to `report.health_run_ids`), then `enqueue_season` for the other groups (the pending ones are skipped, so every group still runs once). The synchronous `PostCommitChecks` call is gone; a report holding the legacy `post_commit_checks` JSON still renders it (`_legacy_checks`).
  - **Schema additions** to the plan's columns: `pipeline_sources.stage_reason` + `stage_details` (kept / edited phases of a refused invalidation), `phase_verdicts.fingerprint` (verdict cache key: mtimes and sizes of the files read, staging aggregates for phase 5, db generation, checker version), `commit_reports.archive_error` + `progress_message/current/total`.
  - **Verdict flags** (`edited`, `adopted`, `stale_reasons`, `message`) are stored inside `phase_verdicts.counts` under `_`-prefixed keys.
  - **Step 1 review items** (not FIN-matched, source warnings, new session in an existing meeting) are cleared by saving Step 1; an adopted phase 1 counts as saved.
  - **System journey** `spec/system/outbox_spec.rb` (07/08): its Phase 6 step now goes Step 5 → "Commit summary" link → drift tick (a stored `:unknown` `Ops::DbFingerprint` for the configured API, so the gate makes no remote check) → Commit → queued report → `DataFixCommitJob.perform_now` → the report frame turns "committed" → the report reopened from its URL → script link → Outbox → push (08's push tick kept). It ends with `expect_no_js_errors`. A Commit click without the tick answers 422 (Turbo renders the summary again), which Chrome logs as a SEVERE console entry: journeys must tick it.
  - **Report status frame**: the show page renders `commit_reports/_status` with `src:` (`polling: true`); the status action answers WITHOUT `src`, because Turbo refuses a response frame whose source references itself (the frame went blank after the first reload; found by the system journey).
  - **Commit summary form** is a `form_with` posting to `commit_phase6_path(file_path:)` (it carries the acknowledgement and "Create anyway" ticks); Step 5 keeps its `button_to`.
  - **Specs changed outside steps 10-11**: `spec/services/data_fix/source_resolver_spec.rb` (supersede now needs stamped phase files; new example for the kept edited ones), `spec/models/ops/application_record_spec.rb` (rebuilder names now `%i[data_fix_pipeline outbox]`), `spec/views/data_fix/commit_phase6_report.html.haml_spec.rb` ported to `spec/views/data_fix/commit_reports/_stats.html.haml_spec.rb`. Commit specs (steps 10-11) read the report row and perform the job inline (`:data_fix_commit` tag, `spec/support/data_fix_commit_helpers.rb`, which also stubs `DataFix::Guards` to `:ok`: the real `Drift::Gate` asks for an acknowledgement without a stored check); "commits all the same when the ops DB is not available" became "refuses the commit with the setup notice".
- **For 10**: `pipeline.prepare!(up_to:, phases:, deadline:)` is the job entry point (actor `:auto`, `Import::Progress::Ops` on an `Ops::PipelineRun` row, never `force`); it raises `LeaseBusyError` when an operator request builds the same source and stops at a stale edited phase. `DataFix::Guards.check(:prepare)` is ready. `Ops::PipelineSource.stage` / `review_phase` / `review_count` / `new_*_count` are written by every `summary`; the board / inbox can read them (stages `new needs_review blocked ready_to_commit committed failed`; `preparing` / `committing` are for 10). The collision re-prepare ("after the other source commits") is not automatic yet: `CommitRunner` marks the committed source and bumps `data_fix.db_generation`; 10's planner should rebuild the phase 5 of sources whose verdict has a `collisions` issue naming it. `refresh_new_entities!` runs today when Step 2/3 opens on a `db`-stale phase and from the summary's "Refresh matches".
- **For 11**: `Maintenance::RunJob` in apply mode must use `limits_concurrency key: 'local_db_writer'` (shared with `DataFixCommitJob`); it should bump `DataFix::Pipeline.bump_db_generation!` after a local apply that creates entities.
- **For 12**: the older Data-Fix views (team / swimmer cards, review pages) are still on the compat layer; the "Verify all" button can POST `data_fix_verify_all_results_path(file_path:)`; an explicit "Confirm" button per card can PATCH the update actions with no changes (saving sets `confirmed: true`); next-issue navigation can read `Verdict#issues[*]['details']` (row keys).
- **For 14**: `DataFix::Guards` calls `DbRestore::Lock.active?` / `.current_run` when the constant exists; after a restore, bump `data_fix.db_generation` too (new-entity matches become stale).
- **For 15**: `Ops::PipelineSource` is keyed by the DiskIndex base and covers non-FIN sources.
- **Not verified by hand** (the dev server runs the recurring jobs against FIN and the configured API, and the dev DB is a production copy): the stepper and banners on real sources, a real commit through the `pipeline` worker under Solid Queue (priority, concurrency key, report polling every 2 s), "Retry archiving" from the new report, "Rebuild (discard edits)" after a real category normalization or manifest supersede, `bin/rails ops:prepare` on the development ops DB, `bin/rails ops:rebuild` on the real `crawler/data` (it only reads the phase files), the summary's 422 re-render with a real drift warning in a browser (covered by request specs; the journey ticks first).

## Rollback note

Steps 1-3 revert cleanly: there are no file-format changes. From step 4 on, phase files carry the extra `_meta` keys `built` and `operator_edit`, which older code ignores (`PhaseFileManager#meta` merges them through). Reverting steps 10-11 restores the session report and the synchronous POST. Ops tables can stay, because nothing in MySQL references them. Remove the `pipeline` worker only after no `DataFixCommitJob` is queued.
