# Phase 10 — Pipeline automation up to review

## Goal

Let jobs take a meeting from crawl through manifest extraction to "ready to commit" or "needs review at step N", by running the phase 09 runner unattended. Stay inside the automation boundary: jobs may crawl, extract manifests, build phases 1-5 and flag issues. The local commit and the remote push always need an operator click.

## Operator-visible outcome

- A clean FIN meeting shows up on the board and in the inbox as **Ready to commit · +2 teams, +37 swimmers** without any click. "Commit" opens the 09 commit summary, so finishing takes two clicks: Commit, then Push in the Outbox.
- A meeting that needs a decision shows **Needs review at step 3 · 4 issues**. It opens on that step with the review filter on.
- A failed preparation shows **Preparation failed at step 4: …** with a Retry button.
- Pending manifest PDFs are extracted automatically, up to 3 attempts per PDF spaced at least 20 h apart, then an inbox item.
- When FIN marks a meeting with results as published, a structure-committed meeting is re-crawled (rate-limited).
- The dashboard shows kill switches: automation, auto-extract, auto-prepare.

## Depends on

Hard dependencies: **05** and **09**.

- **09**: `DataFix::Pipeline` (with the lease and `mark_edited!`), `ReviewRules`, verdicts, `Ops::{PipelineSource,PhaseVerdict,PipelineRun,CommitReport}`, `Import::Progress::Ops`, the `pipeline` queue worker, `DataFixCommitJob`, `DataFix::Guards`, the commit summary page and its route helper `data_fix_commit_summary_path`.
- **05**: `Inbox::Source` / `Inbox::Registry` (registration in `config/initializers/inbox.rb`) and `Inbox::Builder`, the board snapshot in `Ops::Snapshot` key `season_board:<season_id>` (invalidated by `SeasonBoard::Notifier.ping`), `SeasonBoard::ActionPaths`, `DataFix::SessionIndex`, and the dashboard system column where the switches and the worker mode are shown.
- Softer links, reached through 05 and 09: 01 (`Ops::Setting`, `Ops.record_event!`); 08 (optional): `Drift::Gate.check(scope: :prepare)`, see the start guards below; 14 (later): `DbRestore::Lock`, honoured through `DataFix::Guards` (09), which is no-op-safe until 08 and 14 exist.

## Invariants that apply here

- Jobs that commit or push (`DataFixCommitJob`, `Outbox::PushJob`) are enqueued only by a controller action triggered by an operator click: never by `DataFixPrepareJob`, `SeasonBoard::PipelinePlanner`, `CrawlPlanner`, `SeasonRecheckJob`, a callback or another job. Retries are disabled. There is no bulk commit and no "Commit selected".
- Operator edits win. A prepare run never rewrites or deletes an edited phase (09 edit markers in `_meta`). The planner never queues a prepare for a source that holds an edited phase; the operator opts in with the row's "Prepare" button.
- Crawls stay strictly serial on `background` (`config/queue.yml:18-21`). Prepare and commit share the single-thread `pipeline` queue.
- No job broadcasts on `ImportStatusChannel`. Progress goes to `Ops::PipelineRun`, and boundaries ping `SeasonBoard::Notifier`.
- Dashboard and status surfaces make no synchronous remote call.
- "Staging" means the `data_import_*` tables. Everything a job computes for the UI (runs, verdicts, switches, board facts) lives in the ops DB, never in `Rails.cache`. Repo conventions: frozen string literal, en + it keys, CHANGELOG + PATCH bump per user-visible step, `rubocop -a` clean, ops migrations only via `bin/rails ops:prepare`.

## Scope

### Existing chain (verified)

- `FedernuotoWatchJob#plan_crawls` (`app/jobs/federnuoto_watch_job.rb:30-38`) calls `SeasonBoard::CrawlPlanner#call` (`app/services/season_board/crawl_planner.rb:31-39`). The planner crawls only `:link_not_crawled` rows, and skips rows flagged `:possible_unlinked_meeting` or already attempted with the same URL (`:47-52`).
- `SeasonRecheckJob` (recurring daily 5:15am, `config/recurring.yml`) re-crawls past `:structure_committed` rows with `:check_results` and retries failed crawls. It caps at 15 per run, spaced at least 20 h apart (`app/jobs/season_recheck_job.rb:21-22, 56-75`).
- `SeasonBoard::Scheduler.crawl!` / `.extract!` (`app/services/season_board/scheduler.rb:19-39`) log to `ActivityLog` first and refuse busy FIN ids. `extract!` hard-codes `origin: :manual` (`:35`).
- `ManifestExtractJob` runs `PdfManifests::BatchRunner#preflight_error` first and never raises (`app/jobs/manifest_extract_job.rb:42-74`). It shares `limits_concurrency key: 'season_board'` with `MeetingCrawlJob` (`:20`, `meeting_crawl_job.rb:36`).
- `ActivityLog::KINDS = %i[crawl extract]` (`app/services/season_board/activity_log.rb:24`). The same kinds are hard-coded in `RowComponent#activity_items` (`app/components/season_board/row_component.rb:133-135`) and in `Builder#build_row` (`app/services/season_board/builder.rb:111`, the `{ crawl: nil, extract: nil }` default).
- `StateResolver::STATES` (`app/services/season_board/state_resolver.rb:36-40`): first match wins. `Facts = Data.define(:row, :fin_event_id, :row_date, :calendar, :meeting, :disk)` (`:49`).

### New files

- `app/jobs/data_fix_prepare_job.rb` and `app/jobs/pipeline_planner_job.rb`.
- `app/services/season_board/pipeline_planner.rb` (the sibling of `CrawlPlanner`) and `app/services/season_board/pipeline_index.rb` (one ops query per season → per-FIN and per-base pipeline facts).
- `app/services/data_fix/automation.rb`: switch reader (`Ops::Setting` keys plus the `ADMIN2_AUTOMATION=0` env override).
- `app/services/inbox/sources/{ready_to_commit,needs_review,prepare_failed,extraction_gave_up,automation_paused}.rb`, each implementing the 05 `Inbox::Source` interface (`self.key`, `items(context)`, `self.enabled?`) and registered with `Inbox::Registry.register` in `config/initializers/inbox.rb`. They read the 05 board snapshot rows; for sources without a FIN id (15's "Prepare") they read `Ops::PipelineSource` stage directly, with `subject[:file_path]` set so the builder's de-duplication holds. The 05 `BoardRows` source skips rows in the three new states, which these sources own, so no item appears twice.
- `config/locales/pipeline_automation.{en,it}.yml`.

### Files modified

- `app/services/season_board/{state_resolver,builder,scheduler,activity_log,crawl_planner,next_action}.rb`, and `action_paths.rb` and `snapshot.rb` from 05 (the new states and actions are added there)
- `app/components/season_board/row_component.{rb,html.haml}`
- `app/controllers/season_board_controller.rb`: `prepare` and `hold` actions
- `app/jobs/{meeting_crawl_job,manifest_extract_job,season_recheck_job,federnuoto_watch_job}.rb`: enqueue `PipelinePlannerJob` at the end
- `config/routes.rb`, `config/recurring.yml`, `Procfile.dev`
- the dashboard switches partial from 05
- `docs/season_board.md`, `docs/data_fix/PHASES.md`, `AGENTS.md` (Season board section)
- The source of truth for prepare history is ops (`pipeline_runs`). Sources without a FIN id rely on `pipeline_runs` only.

### Planner rules (state → queued job)

`SeasonBoard::PipelinePlanner#call(season:)` is state-driven. It reads the board (05 snapshot or `Builder#call`) plus `PipelineIndex`, so a lost link in the chain is picked up on the next pass. Every enqueue goes through `Scheduler` (crawl, extract) or the new `Scheduler.prepare!` (ops lease plus an `ActivityLog` `:prepare` entry when a FIN id exists).

| Row state / condition | Switch | Queued job | Skip when |
|---|---|---|---|
| `link_not_crawled`, changed in watcher diff | `automation.enabled` | `MeetingCrawlJob` (existing `CrawlPlanner`, unchanged) | as today (`crawl_planner.rb:47-52`) |
| `structure_committed`, listed under the watcher's `with_results` key | `automation.enabled` | `MeetingCrawlJob` via `Scheduler.crawl!(origin: :auto)` | busy; last crawl attempt < 20 h ago (`SeasonRecheckJob::MIN_RECRAWL_INTERVAL`). (The `:possible_unlinked_meeting` flag, `row_flags.rb:20`, only applies to `:link_not_crawled` rows.) The same-URL dedupe at `crawl_planner.rb:50` does **not** apply here (the URL is unchanged by design) |
| `manifest_pending` (no meeting, PDF pending) | `.auto_extract` | `ManifestExtractJob` via `Scheduler.extract!(origin: :auto)` | busy; engine preflight fails (checked once per pass); ≥ 3 `extract` runs for this PDF; last attempt < 20 h ago |
| `results_ready` (results source, no phase files) | `.auto_prepare` | `DataFixPrepareJob(up_to: 5)` | lease held; `auto_prepare` false on the source (row hold) |
| `structure_ready` / `crawled_no_manifest` (result-free source) | `.auto_prepare` | `DataFixPrepareJob(up_to: 1)` | same as above |
| `needs_review` / `ready_to_commit`, verdicts stale and **no edited phase** | `.auto_prepare` | `DataFixPrepareJob(mode: :rebuild_stale)` | any phase edited (operator opts in) |
| `ready_to_commit` / `needs_review`, `db_generation` behind with new entities | `.auto_prepare` | `DataFixPrepareJob(mode: :refresh_new_entities)` | lease held |
| phase 5 `blocked` by an `import_key` collision whose other source is now committed | `.auto_prepare` | `DataFixPrepareJob(mode: :rebuild_stale, phases: [5])` | phase 5 edited |
| `prepare_failed` | — | none (operator "Retry"), unless the source sha256 differs from the failed run's | — |
| `in_review` (phase files, no verdict rows, i.e. adopted as edited) | — | none (row offers "Prepare") | — |
| `sql_pending`, `committed_with_results`, `cancelled`, `archived_unlinked`, `not_linked` | — | none | — |

Notes:

- Unmatched (non-FIN) sources from `DiskIndex#unmatched` are keyed by file base. Phase 15 lets them use `DataFixPrepareJob`; in this phase the planner does not queue them.
- `ready_to_commit` never queues anything that commits.

Where the planner runs:

- `PipelinePlannerJob` (inherits `ApplicationJob`, like `DataFixPrepareJob`; `queue_as :default`, `limits_concurrency key: 'pipeline_planner', to: 1, duration: 10.minutes`) is enqueued at the end of `MeetingCrawlJob`, `ManifestExtractJob`, `DataFixPrepareJob` and `FedernuotoWatchJob` (after `plan_crawls`), and by the board's "Prepare all" button.
- It is also a recurring task `pipeline_planner` (every 15 minutes) as the safety net.
- `CrawlPlanner` keeps handling only crawls. The new `structure_committed` re-crawl rule is a second method on `CrawlPlanner` (`plan_recrawl`), called from `FedernuotoWatchJob` with the same change hash.

### New StateResolver states and their place in the rule chain

`Facts` gains `pipeline:` (`PipelineIndex::Facts` or nil), filled by `Builder#build_row`, so `StateResolver` stays pure. The new rules sit **after `sql_pending` and before `in_review`**:

```
cancelled, sql_pending, prepare_failed, needs_review, ready_to_commit, in_review, results_ready,
structure_ready, manifest_pending, committed_with_results, structure_committed, crawled_no_manifest,
archived_unlinked, link_not_crawled, not_linked
```

| State | Matches when | Detail | Action |
|---|---|---|---|
| `prepare_failed` | last `prepare` run failed and source unchanged since | `{ phase:, message: }` | `:prepare` (POST `season_board/prepare`) |
| `needs_review` | stage `needs_review`/`blocked`/stale-with-edits | `{ step:, count:, blocked: bool }` | `:resume_review` at `step`, `filter_state=review` |
| `ready_to_commit` | every phase verdict clean and fresh (`db_generation` current) | `{ new_teams:, new_swimmers: }` | `:commit` → `GET data_fix/commit_summary` |

- `in_review` remains for sources that have phase files but no verdicts.
- "Preparing…" is the busy overlay (an `ActivityLog` `:prepare` entry, or a live `pipeline_runs` row), not a state.
- `ACTIONS` gains `:prepare` and `:commit`. `RowComponent::STATE_CSS` gains three entries; use the native BS5 classes set by the 04 sweep. `RowComponent::POST_ACTIONS` gains `prepare: :season_board_prepare_path`, and the link-action mapping (moved by 05 into `SeasonBoard::ActionPaths`, out of `RowComponent#link_action_path`) maps `:commit` to `data_fix_commit_summary_path` and `:resume_review` to the step's review path.
- `ActivityLog::KINDS` becomes `%i[crawl extract prepare]`. `RowComponent#activity_items` and `Builder#build_row` iterate `ActivityLog::KINDS` instead of literals. `:commit` is not added: commits are tracked in `Ops::CommitReport`.
- Inbox: `ready_to_commit` → "Commit" (summary page); `needs_review` → "Review step N"; `prepare_failed` → "Retry"; extraction given up (3 failed attempts) → "Extract manually"; automation off → "Automation paused". Each item has exactly one primary action (05 rule). The 05 "Data-Fix sessions in review" source is switched to verdicts.

### DataFixPrepareJob: idempotency, lease and deadline rules

```ruby
class DataFixPrepareJob < ApplicationJob
  queue_as :pipeline
  queue_with_priority 10            # commit job uses 0 (lower value runs first; verify against the installed Solid Queue)
  limits_concurrency key: 'data_fix_pipeline', to: 1, duration: 1.hour   # not 'local_db_writer': that key is DataFixCommitJob's (09) and Maintenance::RunJob's (11)

  # source_path: canonical path; origin: 'auto' | 'operator'; mode: :prepare | :rebuild_stale | :refresh_new_entities
  def perform(source_path:, season_id:, origin:, up_to: 5, mode: :prepare, phases: nil, run_id: nil)
end
```

- **Never raises, no retries.** Same pattern as `MeetingCrawlJob` (`meeting_crawl_job.rb:48-61`): every error closes the `pipeline_runs` row as `failed` and sets the source stage to `failed`. There is no `retry_on`; a spec checks that `rescue_handlers` is empty.
- **Start guards, in order:**
  1. `DataFix::Automation.enabled?(:auto_prepare)` when `origin == 'auto'`;
  2. `Ops.available?` (refuse without ops, because the edit guard and the audit trail need it);
  3. `DataFix::Guards.check(:prepare)` (09's wrapper: `Drift::Gate.check(scope: :prepare)` when 08 exists, `DbRestore::Lock` when 14 exists);
  4. the source file still exists in `results.new`.

  A refused start ends the run as `refused` with its reason. A drift `block` skips the build, sets the verdict `blocked` with reason `drift_red` and raises one inbox item; a `warn` builds and annotates the verdict (08). The prepare job never calls the `:commit` or `:push` scopes.
- **Lease.** `Pipeline.for(...)` takes the `pipeline_sources` lease (`lease_owner = "job:#{job_id}"`, expiry = deadline + 5 min) and releases it in `ensure`. A request finding the lease held shows "Being prepared…" and offers no build. Mutating actions on a leased source answer with a flash "being prepared, retry in a moment".
- **Idempotency.**
  - Built phases that are fresh are skipped.
  - Edited phases are never built. `prepare!` stops at the first edited-and-stale phase and records `needs_review` with reason `edited`.
  - A second enqueue for the same source is refused by `Scheduler.prepare!` (lease or `ActivityLog#busy?`).
  - The job re-checks the source sha256 at the end. If it changed mid-run, it records the verdicts `stale` and leaves the rest to the next planner pass.
- **Deadline.** A soft deadline (default 20 min) is checked between phases; when exceeded, the run ends `failed: deadline`. Step 1 benchmarks the largest real source, and the constant is set from that measurement. A `pipeline_runs` row `running` for over 30 min without progress counts as stuck, the counterpart of `ActivityLog::RUNNING_STALE_AFTER`.
- **Yield to commit.** Between phases, if an `Ops::CommitReport` is `queued`, the job saves state, ends `yielded` and enqueues nothing. The planner re-queues it on the next pass.
- **Progress.** Uses `Import::Progress::Ops`: writes to `pipeline_runs` throttled to about 1 per second, and pings `SeasonBoard::Notifier` at phase boundaries.
- **No commit or push path.** The job's file and its callees (`DataFix::Pipeline`, solvers, populator, `ResultVerifier`) never reference `DataFixCommitJob`, `DataFix::CommitRunner`, `Import::Committers::Main`, `Outbox::PushJob` or `APIProxy`. This is enforced by a static spec.

### Kill switches and extraction retries

- `Ops::Setting` keys: `automation.enabled` (master, default true), `automation.auto_extract` (default true), `automation.auto_prepare` (default true). The env `ADMIN2_AUTOMATION=0` forces all of them off.
- The planner checks the switches before every enqueue. The jobs check them at start when `origin == 'auto'`. Toggles live on the dashboard system column and on the board header, each writing an `Ops::Event`.
- Per-row hold: `pipeline_sources.auto_prepare = false` via POST `season_board/hold`. The planner skips held rows.
- Extraction: `Scheduler.extract!` gains `origin:` (default `:manual`; the planner passes `:auto`). Each auto attempt writes a `pipeline_runs(kind: 'extract', subject_key: <pdf basename>)` row. The planner stops after 3 failed rows for a PDF, spaced at least 20 h apart. A manual extraction from the board is always allowed and resets nothing.

### Procfile.dev

Add an optional `jobs` process, which is documented and not required:

```
jobs: env -u DATABASE_URL RAILS_ENV=development SOLID_QUEUE_IN_PUMA=false bin/jobs
```

The `web` line must then also run with `SOLID_QUEUE_IN_PUMA=false`; otherwise two supervisors would run. Document the two variants in `docs/season_board.md`. The dashboard shows the worker mode (`config/puma.rb:45` reads the env).

## Data model

One ops migration, `db/ops_migrate/<ts>_add_automation_to_pipeline_sources.rb`:

- `pipeline_sources.auto_prepare` boolean, NOT NULL, default true (row hold);
- `pipeline_sources.failed_source_sha256` string (lets the planner re-queue a failed source only after its source changed);
- index on `pipeline_runs (kind, subject_key, status)` for the extraction-attempt count.

New `Ops::Setting` keys: `automation.enabled`, `automation.auto_extract`, `automation.auto_prepare`.

## Ordered steps

1. **Benchmark + prepare job, manual only.** Benchmark `Pipeline#prepare!` on the largest real source and set the deadline. Add `DataFixPrepareJob`, `Scheduler.prepare!`, `ActivityLog` `:prepare`, the `KINDS` iteration in `RowComponent`/`Builder`, and `POST season_board/prepare` (a row "Prepare" button). User-visible. CHANGELOG + PATCH.
2. **PipelineIndex + states.** Add `Facts#pipeline`, the three states and the `:prepare`/`:commit` actions, row texts and links, and i18n en/it. User-visible. CHANGELOG + PATCH.
3. **Inbox sources.** The five new sources, with the 05 "in review" source switched to verdicts. User-visible. CHANGELOG + PATCH.
4. **Kill switches.** `DataFix::Automation`, settings toggles, env override, row hold, and the migration. User-visible. CHANGELOG + PATCH.
5. **Planner (prepare only).** `PipelinePlanner` with the prepare rows of the table, `PipelinePlannerJob`, hooks at the end of the crawl/extract/prepare/watch jobs, recurring entry, and "Prepare all". User-visible ("ready to commit" with zero clicks). CHANGELOG + PATCH.
6. **Auto-extract.** `Scheduler.extract!(origin:)`, preflight once per pass, capped retries, the "gave up" inbox item. User-visible. CHANGELOG + PATCH.
7. **Re-crawl on "results published".** `CrawlPlanner#plan_recrawl` for `structure_committed` rows in `with_results`, rate-limited at 20 h. User-visible. CHANGELOG + PATCH.
8. **Procfile and docs.** Optional `jobs` process, `docs/season_board.md` (chain, states, switches), `docs/data_fix/PHASES.md`, `AGENTS.md`. `manifests-extract-status.json` stays until 15 makes the batch a job. No version bump.

Recurring entry (step 5):

```yaml
  pipeline_planner:
    class: PipelinePlannerJob
    queue: default
    schedule: every 15 minutes
```

## Specs and manual verification

Specs proving the automation boundary:

- `spec/automation_boundary_spec.rb` (static): scans `app/jobs`, `app/services/season_board`, `app/services/data_fix/pipeline*` and `app/services/inbox`. It asserts that `DataFixCommitJob`, `DataFix::CommitRunner`, `Committers::Main`, `Outbox::PushJob` and `commit_all` appear only in `app/controllers/data_fix/commits_controller.rb`, the Outbox controller, `app/services/data_fix/commit_runner.rb` and `app/jobs/data_fix_commit_job.rb`.
- `spec/jobs/data_fix_prepare_job_spec.rb`:
  - On the `clean_fin` fixture (09): stage `ready_to_commit`, no `Ops::CommitReport` created, `DataFixCommitJob` not enqueued, no `GogglesDb::Meeting` or Outbox script created.
  - The edited-phase fixture: file bytes and mtime unchanged after the run.
  - Lease held → refused. Deadline exceeded → failed. Queued commit → yielded. Source changed mid-run → stale.
  - `rescue_handlers` is empty.
- `spec/services/season_board/pipeline_planner_spec.rb`: one example per table row, including "switch off → nothing queued", "edited phase → no prepare", "3 failed extractions → no extract", "structure_committed in `with_results` crawled once per 20 h".
- `spec/services/season_board/state_resolver_spec.rb`: the three states win over `in_review`/`results_ready` and lose to `sql_pending`/`cancelled`.
- `spec/requests/season_board_controller_spec.rb`: existing row-href pins (`:126-133`) stay green, plus new pins for the prepare form and the commit link.
- `spec/config/queue_names_spec.rb` (from 06): `DataFixPrepareJob` and `PipelinePlannerJob` queues exist in `config/queue.yml`.

Manual check:

1. Clear automation off and on.
2. Crawl a published FIN meeting from the board, wait, and see "Ready to commit".
3. Open the summary, commit, and push from the Outbox.
4. On a second meeting, edit a phase 2 card and confirm that no automatic build touches the file afterwards.
5. Stop the LLM engine and confirm that no extraction is queued while the dashboard pill shows the engine down.

## Exit criteria

- A clean fixture FIN meeting reaches `ready_to_commit` with zero clicks (job spec plus a manual run).
- An edited phase file is byte-identical after a prepare run.
- No code path from a job, planner or callback to commit or push (static spec plus the job spec assertions).
- With `automation.enabled` off, nothing is queued automatically. With `auto_extract` off, no extraction is queued. Crawls stay strictly serial.
- A failed auto-extraction is retried at most 3 times at least 20 h apart, then becomes one inbox item.
- Routine gate passes: sign in → board → crawl (automatic or by click) → review → commit → report → push → confirm.

## Risks and mitigations

- **CPU-bound prepares slow the UI** when Solid Queue runs inside Puma. Use the optional `jobs` process with `SOLID_QUEUE_IN_PUMA=false`; the worker mode is shown in the system column.
- **A wrong deadline** kills good runs or lets a stuck one hold the queue. Benchmark first (step 1) and detect stuck `pipeline_runs`.
- **Unattended LLM cost or loops on a bad PDF.** Separate switch, one preflight per pass, at most 3 attempts.
- **Ops rows drift from the files** when the operator moves files by hand. `PipelineIndex` reconciles against `DiskIndex` on every board build: a row without files is ignored (the index reports it as `orphaned`; the stored `stage` is untouched), and files without a row are adopted as edited.
- **Commit waits behind a prepare.** Priority 0 versus 10, plus the yield between phases. The two jobs use different concurrency keys (`local_db_writer` vs `data_fix_pipeline`) but share the single-thread `pipeline` worker, so the queue itself serialises them.
- **Mass preparation creates many staging rows**, and `import_key` collisions grow. The 09 collision detection blocks the later source, and the planner re-prepares it after the other source commits.
- **Background rebuild surprises the operator mid-edit.** The lease plus the "being prepared" banner, and the planner never touches edited sources.

## Decisions to confirm

- Unattended manifest extraction: **default on**, with 3 attempts per PDF at least 20 h apart.
- Optional `jobs` process in `Procfile.dev`: **default added but commented as optional**; Puma-embedded stays the default.
- One click per meeting: **default yes**, no "Commit selected".
- The planner queues prepare for sources with edited phases: **default no** (row button only).
- Planner recurring interval: **default 15 minutes**.
- `structure_ready`/`crawled_no_manifest` auto-prepared up to phase 1: **default yes**.

## Out of scope

Committing or pushing from any job; non-FIN sources in the planner (15); turning the season-wide `BatchRunner` thread into a job (15); new crawler layouts; Health jobs (06); the drift gate itself (08; 10 only calls `scope: :prepare`, and the commit and push gates stay in 09 and 07/08).

## Outcome (done, 0.10.89, 2026-11-24)

Delivered on `feature/modernize-admin-console-ux` (steps 1-8 in one pass, shipped as one PATCH; phases 11 and 14 were implemented in the same working tree meanwhile). All six decisions confirmed with their defaults (unattended extraction on, 3 attempts at least 20 h apart; optional `jobs` process added to `Procfile.dev` but commented out, Puma-embedded stays the default; one commit click per meeting, no bulk commit; the planner never queues a prepare for a source with an edited phase; planner every 15 minutes; result-free sources auto-prepared up to phase 1). Targeted runs only (the full suite is the coordinator's): automation boundary, all job specs, `spec/services/{season_board,inbox,data_fix}`, the season board / automation / dashboard / Data-Fix request specs (incl. `data_fix_controller_phase2_spec`), all component specs, `spec/models/ops`, navigation, BS4 ratchet, i18n parity, `spec/config`, `spec/routing`: **1,222 examples, 0 failures, 3 pending** (the pre-existing ones); after the review fixes the same set, run in six groups because phases 11/14 were running their own specs on the shared ops test DB (a group that hit "database is locked" was rerun alone): **1,292 examples, 0 failures, 3 pending** (jobs + boundary 198, `spec/services/{season_board,inbox}` 288, `spec/services/data_fix` 122, board / automation / dashboard requests 76, Data-Fix requests 126, components / ops models / navigation / BS4 / i18n / config / routing 482). New spec files (after the review fixes): `automation_boundary_spec` 5, `jobs/data_fix_prepare_job_spec` 27, `jobs/pipeline_planner_job_spec` 7, `services/data_fix/automation_spec` 9, `services/season_board/pipeline_planner_spec` 31, `services/season_board/pipeline_index_spec` 7, `services/inbox/sources/pipeline_automation_sources_spec` 8, `requests/automation_controller_spec` 4, `requests/data_fix/edit_while_prepared_spec` 4. The system specs rendering the touched pages (`season_board_spec`, `sign_in_and_dashboard_spec`, `app_shell_spec`, `data_fix_spec`; none changed) 16 examples, 0 failures (light theme). Rubocop clean on every Ruby file touched; the new and touched templates add no haml-lint offense (the remaining ones are pre-existing).

- **Review fixes** (an independent read-only review after the first pass; all five findings confirmed against the code and fixed with specs): (1) fail closed: `DataFix::Automation.stored` reads the setting outside `Ops.safely` and answers false when it cannot be read (only "ops DB not configured / not migrated" keeps the master switch on); `MeetingCrawlJob` takes `origin:` from `Scheduler.crawl!` (an unreadable logged origin counts as automatic); `ManifestExtractJob` refuses an automatic attempt whose switch or run row cannot be read; `DataFixPrepareJob` counts an unreadable commit-pending check as pending and yields on an unreadable queued-commit check; the planner queues no prepare when `PipelineIndex#read_error?`, gives up on an unreadable attempt count and treats an unreadable last attempt as recent; (2) `PipelinePlanner.unsuccessful_extractions` counts every automatic extract run not ended `done` (failed, refused for any reason but a switch off, stale queued/running per `PipelineRun#stale?`); a run refused because `automation.auto_extract` / the master switch was off or unreadable never reached the engine and is not counted (`ManifestExtractJob` stores its error as `automation_paused: ...`, `PipelinePlanner::SWITCH_REFUSAL`, `.switch_refusal?`); (3) an automatic prepare computes the working copy without side effects (`expected_working_path`), takes the lease and checks the edits before resolving, never runs the rewriting resolver branches on a source with phase files (refused `source_needs_review`; checked with `detect_layout_type_from_content`, `manifest_copy_superseded?`, `lt4_result_categories_need_normalization?`) and resolves a source without phase files only once nobody else holds the lease; operator runs resolve first, as an interactive open; (4) `spec/automation_boundary_spec.rb` proves that the only APIProxy call on the prepare path is the drift GET, and the job spec runs a prepare with the real guards and a recording `APIProxy.call` stub: only `:get`, no `Ops::RemoteWrite`; (5) `DataFix::BaseController::LEASE_GUARDED_ACTIONS` = the edit actions + `recompute_source_categories` + `discard_phase_edits`, refused while ANY owner holds an unexpired lease (the "being prepared" banner stays job-only), and `Pipeline#invalidate!` deletes nothing, even forced, while another owner holds the lease (`{ refused: true, leased: true }`, no block).
- **Boundary exception (documented)**: a prepare's only reachable API call is the light read-only `GET tools/db_fingerprint` of `Drift::Gate` (through `DataFix::Guards.check(:prepare)`), made only when no stored check under 10 minutes exists and a background JWT is available; no remote write.
- **Benchmark (step 1)**, `RAILS_ENV=test` on `goggles_test` (a production-size copy: 41k swimmers, season 262 present), sources copied into a temporary data root (scratchpad), staging rows and ops rows deleted afterwards (verified 0 left). `results.new/262` holds no result source today (everything is committed), so the largest season 262 results source was taken from `results.done/262`: `2026-11-22-14_TROFEO_COOPERNUOTO_MASTER-lt4.json` (1.3 MB, 1,189 results, 51 relays): **17.6 s** (phase 1 0.2 s, phase 2 2.7 s, phase 3 9.7 s, phase 4 0.0 s, phase 5 4.7 s, summary 0.1 s). Worst-case reference, the largest real meeting on disk (`results.new/252`, national championship, 3.7 MB, 4,105 results, 1,108 relays): **104 s** (phase 2 21.9 s, phase 3 64.1 s, phase 5 16.8 s). 3x the worst case is 5.2 min, so the soft deadline stays **20 minutes** (`DataFixPrepareJob::DEADLINE`).
- **Names as shipped.**
  - Jobs: `DataFixPrepareJob` (queue `pipeline`, priority 10, `limits_concurrency key: 'data_fix_pipeline'`, `perform(source_path:, season_id:, origin:, up_to: 5, mode: 'prepare', phases: nil, run_id: nil, fin_event_id: nil)`, modes `prepare` / `rebuild_stale` / `refresh_new_entities`, `DEADLINE` 20 min, `LEASE_MARGIN` 5 min, overridable `class_attribute :deadline`); `PipelinePlannerJob` (queue `default`, key `pipeline_planner`, `perform(trigger:)`, `.enqueue_after(trigger)` = enqueue only with the master switch on, never raises), recurring `pipeline_planner` every 15 minutes.
  - Services: `DataFix::Automation` (`SWITCHES`, `KEYS` `automation.enabled|auto_extract|auto_prepare`, `ENV_KEY` `ADMIN2_AUTOMATION` with off values `0 false off no`, `.enabled?(switch)`, `.stored`, `.env_off?`, `.switches` (`Switch#state` on/paused/off), `.paused?`, `.store!(switch, value, user_id:)` + event `automation.switched`); `SeasonBoard::PipelineIndex` (`.active_source(entry)`, `#for_entry`, `Facts` with `prepare_failed?`, `needs_review?`, `ready_to_commit?`, `preparing?`, `held?`, `fresh?`, `db_behind?`, `edited_recorded?`, `stale_phases`, `collision_bases`, `failed_but_changed?`, `review_step`); `SeasonBoard::PipelinePlanner` (`#call` => `Plan(prepares:, extractions:, skipped:)`, `#prepare_request(row)`, `.extraction_gave_up?(pdf_path)`, `.unsuccessful_extractions`, `.switch_refusal?(run)`, `SWITCH_REFUSAL`, `MAX_PREPARES_PER_PASS` 5, `MAX_EXTRACTIONS_PER_PASS` 3, `MAX_EXTRACT_ATTEMPTS` 3, `MIN_EXTRACT_INTERVAL` 20 h, `REQUEUE_AFTER` 10 min, `REFUSED_REQUEUE_AFTER` 1 h); `SeasonBoard::StateText.label(state, detail)`; `SeasonBoard::Scheduler.prepare!(season_id:, source_path:, origin:, fin_event_id:, up_to:, mode:, phases:)` (=> the queued `Ops::PipelineRun` or false), `.prepare_busy?`, `.pending_runs`, `Scheduler.extract!(..., origin: :manual|:auto, pdf_path:)`, `PREPARE_MODES`; `SeasonBoard::CrawlPlanner#plan_recrawl(change)`.
  - Pipeline additions: `DataFix::Pipeline.for(..., lease_owner:)`, `#hold_lease!(ttl:)` (re-entrant `with_lease`), `#prepare!(..., stop_if:)` + `#last_prepare_stop` (`:edited`, `:deadline`, the `stop_if` answer), `#any_edited?`; an automatic build never lets the harmonizer write an edited phase 2.
  - States / actions: `StateResolver::STATES` gains `prepare_failed needs_review ready_to_commit` (after `sql_pending`, before `in_review`), `PIPELINE_STATES`, `ACTIONS` gains `prepare commit`; `Facts#pipeline` and `Row#pipeline` (both default nil); `RowFlags` flag `prepare_held`; `ActivityLog::KINDS` = `crawl extract prepare`; `ActionPaths::POST_ACTIONS[:prepare]` = `season_board_prepare_path`, `LINK_ACTIONS` + `:commit` (=> `data_fix_commit_summary_path`), `ActionPaths.review_step_path(file_path, phase, filter_state:)`; `Snapshot::FORMAT_VERSION` 2.
  - Ops: migration `db/ops_migrate/20261124100001_add_automation_to_pipeline_sources.rb` (`pipeline_sources.auto_prepare` NOT NULL default true, `pipeline_sources.failed_source_sha256`, index `pipeline_runs (kind, subject_key, status)`); `Ops::PipelineSource::JOB_LEASE_PREFIX` `job:`, `#leased_by_job?`, `#held?`. `pipeline_runs` written for `prepare` (every run) and `extract` (automatic attempts only; `subject_key` = the PDF basename).
  - Inbox: sources `ready_to_commit`, `needs_review`, `prepare_failed` (base `Inbox::Sources::PipelineRows`), `extraction_gave_up` (same key `board:<fin>:extract_manifest` as the board item, band failed, so it replaces it), `automation_paused`; `Inbox::Builder::BOARD_SOURCES` gains the first four; `BoardRows::SKIPPED_STATES`, `SKIPPED_KINDS` + `prepare commit`.
  - UI / routes: `POST season_board/prepare` (`season_board_prepare`), `season_board/hold` (`hold=1|0`), `season_board/prepare_all`, `POST automation/switch` (`AutomationController#switch`, `switch`, `value`, `return_to=dashboard|season_board`; API-offline allowed); partial `automation/_switches` (dashboard system column `#dashboard-automation` + `#dashboard-worker-mode`, board header `#season-board-automation`); review header banner `#data-fix-being-prepared`; `DataFix::BaseController#refuse_edit_while_prepared!` (before the `EDIT_ACTIONS`, HTML redirect back with a warning, other formats 409). Locales `config/locales/pipeline_automation.{en,it}.yml` (`pipeline_automation.*`, `season_board.states|state_tooltips|state_details|actions|flags|activity|strip.*` additions, `inbox.*` for the new sources, `ops.events.automation.*` / `ops.events.pipeline.prepare_done|failed|refused`).
- **Deviations.**
  - **Planner scope**: only `SeasonBoard::Builder.latest_season` (same as `SeasonDefaults.default_season`), FIN rows only; it never takes a season parameter.
  - **Edited sources**: the planner skips ANY source with an edited phase for every mode (also the collision rebuild of phase 5 and the matches refresh, which writes phases 2/3), and the job refuses an automatic run on such a source (`refused: edited`); the plan limited some rows to "phase 5 edited" / "lease held".
  - **Freshness**: "verdicts fresh" = five verdict rows whose oldest `checked_at` is not older than the newest file of the source (1 s tolerance) and, when the source has new entities, a `pipeline_sources.db_generation` not behind `data_fix.db_generation`. A stored "ready" that is no longer fresh shows as `needs_review` at the stored review step; the planner then queues a `rebuild_stale` (no edits) which recomputes it. `in_review` stays for phase files without usable verdicts.
  - **prepare_failed** also matches a stored stage `failed` from an interactive build; "source unchanged" = the LT2/LT4 file is not newer than the failed run AND (when stored) its SHA256 equals `failed_source_sha256`. A failed source whose file changed falls back to the former states and the planner prepares it again.
  - **Drift**: a red gate refuses the run (`refused`, reason `drift_red: ...`; an active `DbRestore::Lock` gives `db_restore: ...`); the "one inbox item" is the existing `Drift::InboxSource` red item (no new item). An amber/unknown gate builds and the warning is appended to the run message, not to the verdict. Against today's API (no `db_fingerprint` capability) the gate is unknown = warn, so prepares run and note it.
  - **Loop guards** (not in the plan): a source whose last prepare finished less than 10 minutes ago (1 hour after a refusal) is skipped; only a `done` run enqueues the next planner pass; at most 5 prepares and 3 extractions per pass.
  - **Automatic crawls** (`MeetingCrawlJob`, origin read from the queued ActivityLog entry) are refused as failed ("automation paused") at start with the master switch off; `SeasonRecheckJob` and both `CrawlPlanner` methods queue nothing then. The master switch defaults to on without the ops DB (crawls as before), the two sub-switches to off.
  - **Commit pending**: `Scheduler.prepare!` and the job also refuse while an `Ops::CommitReport` of the source is queued or running.
  - **"Data-Fix sessions in review"** (05 `DataFixSessions`) switched to verdicts: the resume step is the stored `review_phase` of a `needs_review`/`blocked` source (with the review filter) and the stage is added to the detail; otherwise unchanged.
  - **Unmatched (non-FIN) sources** get no pipeline items yet: the new sources read board rows only (the 05 `UnmatchedSources` items are unchanged); `Ops::PipelineSource` rows are keyed by base, ready for 15.
  - **Fingerprint**: the board snapshot fingerprint includes the season's pipeline facts (max `pipeline_sources.updated_at`, last prepare run id / finish time, pending count, `data_fix.db_generation`), not the throttled progress writes.
  - **Dashboard switches** are a partial in the system frame (there was no 05 switches partial); the dashboard "Season progress" colours gain the three states.
  - **Unrelated fix**: `Inbox::ItemComponent#since_text` measured the waiting time from the real clock instead of its `now:` (its spec started failing on 2026-11-24); it now uses `distance_of_time_in_words(item.since, @now)`.
  - The migration carries a `rubocop:disable-next Rails/BulkChangeTable` comment, added after it had run on the test ops DB (comment only, no schema change).
- **For 11**: a local apply that creates entities should call `DataFix::Pipeline.bump_db_generation!`: the planner then refreshes the new-entity matches of the prepared sources without edits. A Health "Fix" that changes phase files must go through `DataFix::Pipeline` (edit markers), never write them directly, or the planner may rebuild them. `DataFixPrepareJob` uses the key `data_fix_pipeline`, not `local_db_writer`: it never writes the local primary DB outside the `data_import_*` staging tables.
- **For 12**: the review pages can read `Ops::PipelineRun` (kind `prepare`, `phase`, `message`, `progress`/`total`) for a "being prepared" progress bar instead of the static banner; `SeasonBoard::StateText` gives the state texts; the next-issue navigation can start from `PipelineIndex::Facts#review_step`.
- **For 14**: `DataFix::Guards` already refuses prepares while `DbRestore::Lock` is active (`refused`, reason from the lock); after a restore, bump `data_fix.db_generation` and consider turning the master switch off until the drift check is green; `pipeline_sources` leases with the `job:` prefix may be left by a killed worker until `lease_expires_at` (deadline + 5 min).
- **For 15**: give unmatched sources a key in `PipelineIndex` (by base) and let the planner queue them (`DiskIndex#unmatched`); move `PdfManifests::BatchRunner` into a job (then `manifests-extract-status.json` can go); `Ops::PipelineRun` `extract` rows are keyed by PDF basename.
- **Not verified by hand** (the dev server would run the recurring jobs against FIN, the configured API and the real `crawler/data`): the manual check of the plan (a published FIN meeting reaching "Ready to commit" by itself, commit + push, an edited phase 2 untouched by later passes, the LLM engine stopped => no extraction queued), the planner under Solid Queue (priority 10 vs 0 on the `pipeline` worker, the `limits_concurrency` blocking of concurrent planner passes), `bin/rails ops:prepare` on the development ops DB, the `jobs` process variant of `Procfile.dev`, the system specs in dark mode (none changed). On the real data today `results.new/262` holds no source and `manifests/262` no PDF, so the first passes queue nothing.

## Rollback note

Set `automation.enabled = false` (or `ADMIN2_AUTOMATION=0`) to stop everything at once without a deploy. Reverting the code removes the three states; existing `pipeline_*` rows are ignored. Keep the `:prepare` `ActivityLog` kind readable: `build_entry` must tolerate unknown kinds in `season-board.json`, or the revert must prune them. The migration only adds columns, so it can stay.
