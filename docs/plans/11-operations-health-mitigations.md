# Phase 11 — Operations framework + health mitigations

## Goal

Turn the maintenance strategies into operations that can be triggered from the UI. Each operation follows the same path: plan → dry-run page → apply locally → script registered in the Outbox → health re-run. Then wire the first eight operations to the phase-06 findings, so that every row of the 06 check-to-action table marked "11" gets a working button. This closes the "possible actions to mitigate the issue" part of the operator's requirement.

## Operator-visible outcome

- A "Fix" button on findings, and on the badge/duplicate sections of the commit report. It opens a pre-filled operation form, then a dry-run page (console log, summary, warnings, errors, SQL preview), then an "Apply locally and add to Outbox" step with the confirmation level the operation requires.
- `/operations`: list of available operations, run history (`OperationRunsGrid`), and a run page with live status, captured console output, the produced script and the linked finding.
- After an apply, the season's health group re-runs, and the finding turns resolved once the problem is gone.
- "Flag cancelled" from 06 now runs through the same framework (`meeting.set_cancelled`).

## Depends on

- 06: `Ops::HealthFinding`, check keys, the check-to-action table, `Health::SeasonRunJob`, the `maintenance` worker.
- 07: `Outbox::Writer` (global sequence, `results.new/misc/`), `Ops::SqlScript`, `LocalDb::SqlRunner` (extracted from `lib/tasks/db.rake:55-81`).
- 08: `Drift::Gate.check(scope: :operation, ...)`, called before planning an apply and never on a dry run.
- 09: `DataFix::Pipeline` staleness API (used to mark reviews in progress stale after an apply), `Ops::CommitReport` (persistent report that gets the Fix links), and `DataFixCommitJob`'s concurrency key.

## Invariants that apply here

- `Maintenance::RunJob` in apply mode is enqueued only by a controller action after an operator click (`Maintenance::RunsController#apply`). It is never enqueued by a scheduler, planner, callback, health run or another job. Retries are disabled, and a spec asserts this. Preview runs may also be enqueued only from a controller.
- `Operation#plan` never writes, to the primary DB or to disk. A spec asserts zero INSERT/UPDATE/DELETE on the primary during preview.
- Scripts are registered in local-apply order through `Outbox::Writer` (global seq), in `crawler/data/results.new/misc/`. A script is registered only after the local apply succeeds.
- Health checks stay read-only. An operation is the only place where a fix SQL is generated from a finding.
- No admin2-only MySQL tables. Run history lives in the ops DB.
- "Staging" means the `data_import_*` tables. Operations do not touch them.
- Conventions: `# frozen_string_literal: true`, en+it, CHANGELOG + PATCH bump for each user-visible step, `rubocop -a` clean, no bare `db:prepare`/`db:migrate`.

## Scope

New:
- `app/services/maintenance/{operation,plan,executor,output_capture,registry,confirmation}.rb`
- `app/services/maintenance/operations/{meeting_set_cancelled,badge_merge,results_dedupe,results_null_swimmers_fix,ranks_recompute,season_board_backfill,swimmer_merge,team_merge}.rb`
- `app/strategies/recompute/ranks.rb`: `Recompute::Ranks`, extracted from `lib/tasks/recompute.rake:55-80`.
- `app/jobs/maintenance/run_job.rb`, `app/models/ops/operation_run.rb`, plus migrations under `db/ops_migrate/`.
- `config/initializers/maintenance_output_capture.rb`: installs the `$stdout` proxy.
- `app/controllers/operations_controller.rb`, `app/controllers/maintenance/runs_controller.rb`
- `app/grids/operation_runs_grid.rb`
- `app/components/maintenance/{plan_report,confirmation,fix_button}_component.rb`
- `config/locales/maintenance.{en,it}.yml`
- Specs under `spec/services/maintenance/**`, `spec/strategies/recompute/ranks_spec.rb`, `spec/jobs/maintenance/run_job_spec.rb`, `spec/requests/maintenance/**`.

Modified:
- `lib/tasks/recompute.rake`: calls `Recompute::Ranks`. Output stays byte-identical apart from the folder and prefix.
- `app/components/health/finding_detail_component.rb` (06): Fix buttons through `Maintenance::FixButtonComponent`.
- Commit report view (09): Fix links for badge and duplicate entries.
- `config/routes.rb`, `Shell::Navigation` (this phase adds the "Data quality > Operations" item; 13 extends it).
- Removed: `app/strategies/health/meeting_canceller.rb` (06; by then writing through `Outbox::Writer`, 07), `Health::CancellationsController` and its routes (06). Old URLs redirect to the operation form.
- `CHANGELOG.md`, `lib/version.rb`, `docs/merge/MERGE_SEMANTICS.md` (a pointer to the UI).

## APIs

```ruby
module Maintenance
  # Immutable result of Operation#plan. digest ignores comment and blank lines, because scripts
  # embed timestamps (duplicate_result_cleaner.rb:287, fix.rake:276).
  Plan = Data.define(:operation_key, :params, :label, :season_id, :subjects, :console, :summary,
                     :warnings, :errors, :sql_lines, :health_group) do
    def digest = Digest::SHA256.hexdigest(sql_lines.reject { _1.strip.empty? || _1.lstrip.start_with?('--') }.join("\n"))
    def empty? = sql_lines.none? { _1.match?(/\A\s*(INSERT|UPDATE|DELETE)\b/i) }
    def blocked? = errors.any?
  end

  class Operation
    include ActiveModel::Model
    include ActiveModel::Attributes
    class_attribute :key, :confirmation, :outbox_kind, :health_group   # confirmation: :one_click | :confirm | :typed

    def self.from_finding(finding) = raise(NotImplementedError)        # prefill params from finding.payload
    def plan                                                           # never writes
      return Plan.new(**blank_plan, errors: errors.full_messages) unless valid?
      result, console = OutputCapture.capture { build_plan }           # strategies may print, see below
      result.with(console:)
    rescue StandardError => e                                          # e.g. badge.rb:184 raise
      Plan.new(**blank_plan, errors: [e.message])
    end
    def file_base = raise(NotImplementedError)                         # e.g. "merge_badges-<src>-<dest>"
    def typed_token = nil                                              # text the operator must type when :typed
    private def build_plan = raise(NotImplementedError)
  end

  class Executor
    def initialize(run:) = (@run = run)                                # Ops::OperationRun
    def call                                                           # dispatch on run.mode
      @run.preview? ? preview! : apply!
    end
    private
    def preview!   # plan, store console/summary/sql preview/digest; writes nothing else
    def apply!
      gate = Drift::Gate.check(scope: :operation, acknowledged: @run.drift_ack)  # 08: before planning; block refuses, warn needs the tick
      return refuse!(gate.reasons) unless gate.allowed?
      plan = operation.plan                                            # re-plan on live data
      return refuse!(:digest_changed, plan) unless plan.digest == @run.parent_run.sql_digest
      return refuse!(:blocked, plan) if plan.blocked? || plan.empty?
      tmp = write_tmp(plan)                                            # tmp/maintenance/<run_id>.sql
      result = LocalDb::SqlRunner.call(path: tmp)                      # 07: returns a result, never exits
      return fail!(result) unless result.success?                      # no Outbox row, tmp removed
      script = Outbox::Writer.write!(kind: op.outbox_kind, name: op.file_base, sql: plan.sql_lines.join("\r\n"),
                                     folder: 'misc', season_id: plan.season_id,
                                     applied_locally: true, held: false, origin: { operation_run_id: @run.id }, data_root: Outbox.data_root)   # 07
      after_apply!(plan, script)
    end
    def after_apply!(plan, script)  # run.sql_script_id; finding.mitigation_run_id; Ops.record_event!(...);
      # Health::SeasonRunJob.perform_later(season_id:, group: plan.health_group, trigger: 'after_operation');
      # DataFix::Pipeline.mark_season_stale!(plan.season_id) (09); SeasonBoard::Notifier.ping
  end

  module OutputCapture
    # One proxy installed at boot ($stdout = Proxy.new(STDOUT)). It writes to a thread-local
    # StringIO while capture is active and to the real IO otherwise. Proxy implements
    # write, puts, print, putc, printf, <<, flush, sync, sync=, tty?, isatty, fileno.
    def self.capture
      Thread.current[:maintenance_capture] = StringIO.new
      [yield, Thread.current[:maintenance_capture].string]
    ensure
      Thread.current[:maintenance_capture] = nil
    end
    def self.html(text) = text.gsub(/\e\[[\d;]*m/, '')    # ANSI escapes stripped for display only
  end
end

class Maintenance::RunJob < ApplicationJob
  queue_as :maintenance
  limits_concurrency key: 'local_db_writer', to: 1, duration: 2.hours   # same key as DataFixCommitJob (09)
  # No retry_on: ApplicationJob declares none (app/jobs/application_job.rb:8-11, commented out).
  def perform(run_id) = Maintenance::Executor.new(run: Ops::OperationRun.find(run_id)).call
end
```

Rake callers (13) run `Executor` inline, not as a job: the terminal user is the operator. Preview and apply both run on the single-thread `maintenance` worker, so the process-global `$stdout` proxy never mixes output from two threads.

## Stdout and stdin offenders (re-verified)

Printing from inside `prepare` (captured, strategies unchanged):
- `app/strategies/merge/swimmer.rb:73`: `@checker.display_report` when the checker fails.
- `app/strategies/merge/team.rb:105`: always prints the checker report.
- `app/strategies/merge/badge.rb:183`: prints before raising "Unrecoverable errors detected!" (line 184).
- `app/strategies/merge/meeting.rb:70`: when the checker fails (13 wraps it).
- `app/strategies/merge/swimmer_in_badge.rb:144`, `team_in_badge.rb:170`: before raising (13 wraps them).
- `app/strategies/merge/meeting_checker.rb:75, 423, 432, 438, 443`: progress output and ANSI dots when `console_output` is true. It defaults to true (line 45), and `Merge::Meeting` builds the checker without forwarding its own flag (`meeting.rb:52`). This matters in 13.

Printing only from `display_report` / `display_short_summary` / `verify_merge_result`, which operations do not call: `BadgeSeasonChecker` (281-295), `DuplicateResultCleaner#display_report` (182), `Fix::NullSwimmersInMeeting#display_report` (54-71), `Purge::Meeting#display_report` (71-86), `Merge::TeamInMeeting#display_report` (272-332), `Merge::Meeting` (123-168). Not printing at all: `Normalize::CodedNames`, `Import::CategoryCloner`, `SeasonBoard::Backfill`.

Stdin prompts exist only in rake: `check.rake:403-408`, `merge.rake:697-702`, `purge.rake:67-72`. Operations never prompt. The confirmation lives on the dry-run page.

## First operations

| Key | Inputs | Strategy and exact call (verified) | Dry run shows | Confirmation | Finding it fixes |
|---|---|---|---|---|---|
| `meeting.set_cancelled` | `meeting_id` and/or `calendar_id` | No strategy: `SqlMaker.new(row: meeting).log_update('cancelled' => true, 'updated_at' => nil)` (`sql_maker.rb:106`), same for the calendar; wrapper as `calendar_linker.rb:122-131`. Refuses when MIR+MRR > 0. | Flags, counts, SQL | one click | `meetings.no_results.unflagged`, `meetings.cancel_mismatch`, `calendars.unlinked` |
| `badge.merge` | `source_id`, `dest_id` (optional), `keep_dest_columns`, `keep_dest_category`, `keep_dest_team`, `force`, `autofix` | `Merge::Badge.new(source:, dest:, keep_dest_columns:, keep_dest_category:, keep_dest_team:, force:, autofix:)` (`merge.rake:355-358`), `#prepare`, `#single_transaction_sql_log` (`merge.rake:370`); `log`/`errors`/`warnings` delegated (`badge.rb:256-265`). From a sure finding: dest = first, source = second, `autofix: true` (`merge.rake:619-630`). For a relay category: `dest: nil, autofix: true`. Flags pass `true` or `nil` only: the constructor uses `.present?` (`badge.rb:157-161`), so `"0"` would count as on. | Checker log, errors, warnings, SQL | one click when team and category are equal; typed when any `keep_*`/`force` is set | `badges.duplicate.sure`, `.possible`, `badges.relay_category` |
| `results.dedupe` | `meeting_id` | `Merge::DuplicateResultCleaner.new(meeting:, autofix: true)` (`duplicate_result_cleaner.rb:41`), `#prepare`, `#single_transaction_sql_log` (268-282). Refused while the meeting has an open `results.null_swimmers` finding (NULL join, lines 117-125 vs 397-400). Nothing to do = `Plan#empty?`, **not** `check.rake:399`'s `size <= 5` (the wrapped log is never that short: 4 header lines at 287-290 plus 8 wrapper lines). | Counts per type, MIR groups with `timing_match`; MIR deletion ignores timing (344-363) | one click when every MIR group has `timing_match`; typed otherwise | `results.duplicates`, `results.dup_mir_per_badge` |
| `results.null_swimmers_fix` | `meeting_id` | `Fix::NullSwimmersInMeeting.new(meeting:)` (`null_swimmers_in_meeting.rb:28`), `#scan`, `#fixable?`, `#prepare` (39-97); transaction wrapper copied from `fix.rake:274-283` | Fixable/unfixable per type (unfixable rows listed, never touched) | one click | `results.null_swimmers` |
| `ranks.recompute` | `meeting_id` or `season_id` | New `Recompute::Ranks.new(season: nil, meeting: nil)`: the body of `recompute.rake:55-80` (`Merge::Badge.start_transaction_log`, per-program re-rank by timing, `end_transaction_log`); `putc`/`puts` go away | UPDATE count per meeting | one click | Offered after `results.dedupe`/`badge.merge` applies on the same meeting |
| `season_board.backfill` | `season_id` | `SeasonBoard::Backfill.new(season:, simulate: true).call` (`backfill.rb:72, 86-93`) for the plan: `sql_lines = sql_log`, `console = report` (96-117). Apply goes through the generic Executor path, not `Backfill#apply!` (which writes its own file, 397-417). For a season that is not the board season, pass `snapshot_rows: []` (default reads the current watcher snapshot, 254-256). | Resolved/unresolved calendars, meetings to flag | one click | `meetings.results_flag` |
| `swimmer.merge` | `source_id`, `dest_id`, `skip_columns`, `force` | `Merge::Swimmer.new(source:, dest:, skip_columns:, force:)` (`merge.rake:96`), `#prepare`, `#sql_log` (`merge.rake:107`); `log`/`errors`/`warnings` delegated (`swimmer.rb:117-123`) | Checker log (captured), errors | typed (`MERGE <src> INTO <dest>`) | `swimmers.possible_duplicates` |
| `team.merge` | `source_id`, `dest_id`, `skip_columns`, `keep_as_alias` | `Merge::Team.new(source:, dest:, skip_columns:, keep_as_alias:)` (`merge.rake:179`), `#prepare` (prints checker report, `team.rb:105`), `#sql_log` (`merge.rake:184`); `log` delegated (`team.rb:130`) | Checker log, failed sub-merge warnings | typed | `teams.possible_duplicates`, `badges.duplicate.possible` (team variant) |

`Ops::OperationRun.operation_key` uses these keys. `outbox_kind` values are 07's `Outbox::Kinds` and nothing new: `cancel_flag` (`meeting.set_cancelled`), `merge` (`badge.merge`, `swimmer.merge`, `team.merge`), `fix` (`results.dedupe`, `results.null_swimmers_fix`), `recompute` (`ranks.recompute`), `backfill` (`season_board.backfill`).

## Data model

**`operation_runs`**: `operation_key!`, `params` json!, `params_digest`, `mode!` (preview|apply|script_only), `parent_run_id` (apply → its preview), `status!` (queued|running|succeeded|failed|refused), `refusal_reason`, `console` text (capped at 1 MB), `summary` json, `warnings` json, `errors` json, `sql_preview` text (capped), `sql_digest`, `applied_locally` bool, `sql_script_id` (07's `Ops::SqlScript`), `season_id`, `subject_type`, `subject_id`, `origin` (ui|rake|health|commit_report), `health_finding_id`, `drift_ack` (bool, the operator's tick), `drift_verdict`, `started_by`, `job_id`, `started_at`, `finished_at`, timestamps. Indexes: `(operation_key, created_at)`, `season_id`, `health_finding_id`.

**`health_findings.mitigation_run_id`**: integer, indexed (added to the 06 table).

## Ordered steps

1. **Framework** (not user-visible): `OutputCapture` + initializer, `Plan`, `Operation`, `Registry`, `Executor`, `Ops::OperationRun`, `RunJob`. Specs use a fake operation.
2. **Runs UI** (user-visible, CHANGELOG + PATCH): `/operations`, run page with live status (AppNotificationsChannel ping), `OperationRunsGrid`, `ConfirmationComponent` (one click / checkbox / typed token).
3. **`meeting.set_cancelled`** (user-visible, CHANGELOG + PATCH): replaces `Health::MeetingCanceller`; Fix buttons on the three meeting/calendar checks; the 06 routes redirect.
4. **Results operations** (user-visible, CHANGELOG + PATCH): `results.null_swimmers_fix`, `results.dedupe` (with the null-swimmer precondition), `ranks.recompute` + `Recompute::Ranks` (rake switched to it, parity baseline recorded first).
5. **Badge and board operations** (user-visible, CHANGELOG + PATCH): `badge.merge` from sure, possible and relay findings; `season_board.backfill`.
6. **People operations** (user-visible, CHANGELOG + PATCH): `swimmer.merge`, `team.merge`, typed confirmation, Fix buttons on possible-duplicate findings.
7. **Commit report links** (user-visible, CHANGELOG + PATCH): Fix links on 09's persistent report for badge merges and duplicates.

## Specs and manual verification

- `output_capture_spec`: `puts`, `print`, `putc`, `printf` and `$stdout.write` inside the block are captured; output from another thread is not; the proxy is restored after an exception.
- `executor_spec`: preview writes no file and no Outbox row (no-write subscriber as in 06); apply with data changed between preview and apply is refused (`digest_changed`); a failing `SqlRunner` leaves no script and no Outbox row; success registers exactly one `Ops::SqlScript` with `applied_locally: true`, enqueues one health re-run and stores the console output; a red `Drift::Gate` refuses before planning.
- One spec per operation: `plan.sql_lines` equal the strategy's own output on the fixtures of the existing `spec/strategies/merge/*_spec.rb`; invalid params give errors without raising; `badge.merge` with `"0"` flags is rejected by validation.
- `run_job_spec`: queue `maintenance`; `RunJob.rescue_handlers` is empty (no retries); a grep spec asserts `Maintenance::RunJob.perform_later` appears only in `app/controllers/`.
- `ranks_spec` + rake parity: `recompute:ranks meeting=<id>` (simulate) produces the same console text and SQL before and after the extraction (only folder and prefix differ).
- Manual: from a `badges.duplicate.sure` finding run `badge.merge` (preview, apply). The script appears in the Outbox, the finding resolves after the automatic re-run, and `bin/rails check:badge src=<src> dest=<dest>` no longer finds the source badge. Repeat for one meeting with duplicate results, after fixing its null swimmers.

## Exit criteria

- Every row of the phase-06 check-to-action table whose "Button in" column names 11 (`meeting.set_cancelled`, `badge.merge`, `results.dedupe`, `results.null_swimmers_fix`, `season_board.backfill`, `swimmer.merge`, `team.merge`) has a working button from its finding, always through the dry-run page.
- Specs prove a preview writes nothing and an apply registers exactly one Outbox script, and only after a successful local run.
- Rake output for the wrapped task (`recompute:ranks`) is unchanged apart from folder and prefix.
- `Maintenance::RunJob` in apply mode has no enqueue site outside controllers and no retries.
- Routine gate: sign in → board → crawl → review → commit → report → push → confirm still works, and a commit while an operation is applying waits on the shared `local_db_writer` key instead of interleaving.

## Risks and mitigations

- Preview and apply diverge because strategies read live rows. Mitigation: re-plan plus digest comparison, with comment lines stripped.
- The `$stdout` swap is process-global. Mitigation: thread-local buffer, single-thread worker, a spec for cross-thread isolation.
- An apply changes ids that a Data-Fix review references. Mitigations: the preview lists reviews in progress for the season, the apply marks them stale (09), and the shared `local_db_writer` key orders it against commits.
- One-click fixes become destructive in production once pushed. Mitigations: one click only for the cases listed above, typed confirmation otherwise, and the push stays a separate Outbox click.
- Health findings reflect the local mirror. Mitigation: `Drift::Gate` before apply; the drift verdict is stored on the run.

## Decisions to confirm

- Keep `script_only` (today's `simulate=1`) in the UI? **Default: rake only.** Scripts produced that way are registered `applied_locally: false`, held as `not_applied_locally` (07's state), and need an explicit release or "Apply locally" in the Outbox.
- `badge.merge` for groups of 3 or more badges: `sure_badge_merges` stores pairs (`badge_season_checker.rb:235`). **Default: one pair per apply; the finding stays open until the re-run shows no pair.**
- Offer `ranks.recompute` automatically after a dedupe? **Default: suggested as a follow-up button, never chained.**
- `season_board.backfill` on non-board seasons with an empty snapshot. **Default: yes.**

## Out of scope

`meeting.merge`, `meeting.team_fix`, `badge.team_fix`, `badge.swimmer_fix`, `meeting.purge`, `coded_names.normalize`, `categories.clone`, `standard_timings.import`, `season.badge_fix`, rake conversion, `DEFAULT_SEASON_ID`, season-start checklist (all 13); `db:run` stays terminal-only.

## Rollback note

Hide the Fix buttons behind `Ops::Setting` `operations.enabled` (default on). Turning it off restores 06 behaviour (rake commands shown), except flag cancelled, which then shows only the rake/how-to text. Already-registered scripts stay in the Outbox. `operation_runs` can be dropped without data loss elsewhere. `Recompute::Ranks` can stay, since the rake parity spec guards it.
