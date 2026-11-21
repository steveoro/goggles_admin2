# Phase 06 — Closed-season health report

## Goal

Deliver the operator's own requirement: a report on "previous closed seasons about meetings without any imported results (either cancelled but not flagged as such, or missing data import at all), duplicated badges per seasons (or possible swimmer or team badges), duplicated results and, in general, a data health check on closed seasons. This could be an overview that could be expanded or viewed in detail, section by section, with possible actions to mitigate the issue."

That quote is the acceptance test for phases 06, 11 and 13 together. Phase 06 delivers the overview, the drill-down, persistent triage, and one write action. Phases 11 and 13 add the remaining fix buttons.

## Operator-visible outcome

- `/health` shows a matrix: one row per season, one column per group (Meetings, Badges, People, Results, Setup), with the error/warning count and the time of the last run in each cell.
- A season page with sections that load lazily. Each section lists its findings with filters, bulk acknowledge/ignore with a note, and a detail view (entity links, evidence, the exact rake command to copy, how-to text in en and it).
- "Flag cancelled" on meetings and calendars without results: a dry-run preview, then a local apply plus a numbered SQL script that the operator pushes from the existing Push page (the Outbox once 07 ships).
- A dashboard card and inbox items for each season and group with open errors.
- The page is labelled "local mirror": it reads the local MySQL database only.

## Depends on

- 01: ops DB (`Ops::ApplicationRecord`, `db/ops_migrate`, `Ops.safely`, `rake ops:prepare`), `Ops::Event`, `Ops::Setting` (`db_epoch`).
- 04: `Shell::Navigation` (this phase adds its "Data quality > Health" item), `Shell::PageHeaderComponent`, native Bootstrap 5 views.
- 05: `Inbox::Source` registry and dashboard card slots.

06 and 07 can run in parallel. Softer links: 07 moves the "flag cancelled" writer onto `Outbox::Writer`; 11 replaces it with `meeting.set_cancelled`; 08 shows the drift verdict. 06 must not depend on the Outbox, `Drift::Gate`, `DataFix::Pipeline` or `Maintenance::*`.

## Invariants that apply here

- Health checks never write to the primary DB. `Merge::DuplicateResultCleaner` is always built with `autofix: false`, and a spec asserts zero INSERT/UPDATE/DELETE on the primary during a run.
- The "flag cancelled" apply is enqueued by nothing: it runs in a controller action after an operator click, always behind a dry-run preview. No job, scheduler or callback writes meetings or calendars.
- "Staging" means the `data_import_*` tables. This phase does not read or write them.
- No admin2-only tables in MySQL. Findings and runs live in the ops DB. Script names stay readable by `SeasonBoard::DiskIndex` and `SeasonBoard::Backfill`.
- The dashboard and inbox read only ops rows and make no remote call.
- Repo conventions: `# frozen_string_literal: true`, en+it keys, CHANGELOG + PATCH bump (`lib/version.rb`, currently `0.10.76`) for each user-visible step, `bundle exec rubocop -a` clean. Never run a bare `bin/rails db:prepare` or `db:migrate`. Ops migrations go through `rake ops:prepare`.

## Scope

New:
- `app/models/ops/health_run.rb`, `app/models/ops/health_finding.rb`, plus two migrations under `db/ops_migrate/`.
- `app/services/health/registry.rb`: check definitions (key, group, severity rule, cost, i18n keys, action, rake template).
- `app/services/health/season_scope.rb`: which seasons are closed, current or upcoming, and which ones have data.
- `app/services/health/season_facts.rb`: shared loader for the `meetings` group.
- `app/services/health/checks/{base,meetings,badges,results,people,setup}.rb`
- `app/services/health/finding_sync.rb`, `app/services/health/runner.rb`, `app/services/health/stamp.rb`
- `app/jobs/health/season_run_job.rb`, `app/jobs/health/sweep_job.rb` (both inherit `ApplicationJob`, so 14's restore lock guards them)
- `app/strategies/health/meeting_canceller.rb`: the 06 writer. App/strategies is an eager-load root, so the constant is `Health::MeetingCanceller`.
- `app/controllers/health_controller.rb` (matrix), `app/controllers/health/{seasons,sections,findings,runs,cancellations}_controller.rb`
- `app/grids/health_findings_grid.rb`: a Datagrid scoped on `Ops::HealthFinding`, unlike the existing `data_domain` grids such as `app/grids/meetings_grid.rb:9`.
- `app/components/health/{matrix,section,finding_detail,dashboard_card}_component.rb` (+ haml)
- `app/services/health/inbox_source.rb` (registered with 05's `Inbox::Source`)
- `config/locales/health.en.yml`, `config/locales/health.it.yml`
- `spec/services/health/**`, `spec/jobs/health/**`, `spec/requests/health/**`, `spec/strategies/health/meeting_canceller_spec.rb`, `spec/config/queue_names_spec.rb` (unless an earlier phase added it)

Modified:
- `config/queue.yml`: add a `maintenance` worker. Line 8 says unlisted queues are not picked up. The worker list is at lines 13-21.
- `config/recurring.yml`: add a `health_sweep` entry.
- `config/routes.rb`: the `/health` routes below.
- `app/services/season_board/disk_index.rb:34`: add `meeting_cancel-\d+|calendar_cancel-\d+` to `BOARD_SQL_REGEXP`. Without this, `SQL_REGEXP` (line 31) treats the new script as an unmatched source (lines 122, 175-181).
- `app/controllers/data_fix/commits_controller.rb`: after a successful commit (`commit_success = true` at line 124, report stored at 181-194), also enqueue `Health::SeasonRunJob` for the season. Line 220 (synchronous `PostCommitChecks`) stays unchanged until 09.
- `app/controllers/api_meetings_controller.rb:110-130` (`no_mirs` CSV): add a link to the health page. Logic unchanged.
- `CHANGELOG.md`, `lib/version.rb`, `docs/season_board.md` (a short health section).

## Season scope

- Closed: `GogglesDb::Season.ended` (`end_date < curdate()`, goggles_db `season.rb:64`). All season types are included.
- Current: `Season.ongoing` (`season.rb:63`), plus `SeasonBoard::Builder.latest_season` (`builder.rb:54`). Shown as "current" and run daily.
- Upcoming seasons (not started) run only `season.setup`.
- Seasons with zero meetings and zero badges are listed as "no data" and skipped.

## Check catalogue

Cost classes: **cheap** means at most 3 grouped queries per season. **disk** means one `SeasonBoard::DiskIndex` scan of the season folders. **heavy** means a per-swimmer or per-meeting loop in an existing class. Nothing has been timed, so `duration_ms` is recorded per run from the first version.

| Key | Group | Finds | Backed by | Cost | Severity | Subject / drill-down fields | Action in 06 | Button in |
|---|---|---|---|---|---|---|---|---|
| `meetings.no_results.unflagged` | meetings | Past meeting, `meetings.cancelled = 0`, calendar not cancelled, MIR+MRR = 0, no source on disk | `Health::SeasonFacts` (replaces `check:results`, `check.rake:41-57`) | cheap | error if season closed; warning if current and `header_date` more than 14 days past | Meeting: id, date, code, description, event count, calendar id, `results_code`, `results_link` | Flag cancelled (dry-run), ignore with note ("no results published") | 11 `meeting.set_cancelled` |
| `meetings.no_results.source_on_disk` | meetings | Same, but `DiskIndex#for(results_code)` has a results source, phase files or pending SQL | `season_board/disk_index.rb:55`, `disk_index/entry.rb:29-67` | disk | error | Meeting + file base, phase, `sql_pending?`, path | Open in Data-Fix (`review_*_path` from `row_component.rb:31-35`), open Push | — |
| `meetings.cancel_mismatch` | meetings | `calendars.cancelled <> meetings.cancelled`; or cancelled meeting with results | SeasonFacts rows | cheap | warning; error when the cancelled meeting has results | Meeting + calendar flags, MIR/MRR counts | Flag cancelled when the unflagged side has no results; how-to text otherwise | 11 `meeting.set_cancelled` |
| `calendars.unlinked` | meetings | Calendar not cancelled with NULL or dangling `meeting_id` (never imported); duplicate FIN ids | `Calendar.unscoped` LEFT JOIN query below; `DbIndex#duplicate_fin_event_ids` (`db_index.rb:62-64`) | cheap | error if closed; warning if current | Calendar: id, name, place, `scheduled_date`, `results_link`, `results_code` | Flag calendar cancelled (dry-run), Season board link (current season only), ignore | 15 (crawl from Sources) |
| `meetings.no_events` | meetings | Not cancelled, 0 meeting events | SeasonFacts (replaces `check:events`, `check.rake:72-87`) | cheap | warning if past, info if future | Meeting, `manifest` flag | Open structure review (when a source exists), ignore | — |
| `meetings.results_flag` | meetings | `results_acquired = 0` but MIR+MRR > 0 | Same predicate as `Backfill#meetings_to_flag` (`backfill.rb:354-364`) | cheap | warning | Meeting, counts | Rake command `season_board:backfill season=<id>` | 11 `season_board.backfill` |
| `badges.duplicate.sure` | badges | Same swimmer in the season, same team or teams sharing a meeting | `Merge::BadgeSeasonChecker#sure_badge_merges` (`badge_season_checker.rb:235, 245`) | heavy | error | Swimmer + sorted badge ids: name, year, each badge's team, category | Rake `merge:badge src=<2nd> dest=<1st> autofix=1` | 11 `badge.merge`, 13 `season.badge_fix` |
| `badges.duplicate.possible` | badges | Same swimmer, similar team names | `#possible_badge_merges` (lines 233, 239) | same run | warning | as above | Rake command, ignore | 11 `badge.merge` / `team.merge` |
| `badges.relay_category` | badges | Badge on a relay category | `#relay_badges`, `#relay_only_badges` | same run | error | Badge, swimmer, category code | Rake `merge:badge src=<id> autofix=1` | 11 `badge.merge` (no dest), 13 `season.badge_fix` |
| `teams.possible_duplicates` | badges | Teams with Jaro-Winkler >= 0.89 (`DEFAULT_MATCH_BIAS`, line 109), sharing a multi-badge swimmer | `#possible_team_merges` (line 360) | same run | warning | Sorted team ids, names | Rake `check:team src= dest=`, ignore | 11 `team.merge` |
| `results.duplicates` | results | Duplicate MIRs, laps, MRSs, relay laps, MRRs | `DataFix::PostCommitChecks.build_duplicate_results_check_report` (`post_commit_checks.rb:83-125`), cleaner with `autofix: false` | heavy (5 queries per meeting) | error | Meeting: counts per type; MIR groups (swimmer, program, `timing_match`) | Rake `check:dup_mir_swimmers meeting_id=<id> autofix=1` | 11 `results.dedupe` |
| `results.null_swimmers` | results | MIR/MRS with NULL `swimmer_id` | Grouped prefilter below, then `Fix::NullSwimmersInMeeting#scan` (`null_swimmers_in_meeting.rb:39-48`) on flagged meetings | cheap + per flagged meeting | error | Meeting: fixable/unfixable per type, sample ids | Rake `fix:nil_swimmers_in_results meeting_id=<id>` | 11 `results.null_swimmers_fix` |
| `results.dup_mir_per_badge` | results | More than 1 MIR per badge and program | Season-scoped copy of `check:dup_mir_badges` (`check.rake:320-324`) | cheap | warning | Meeting, badge ids | Rake `check:dup_mir_badges meeting_id=<id>` | 11 `results.dedupe` |
| `season.setup` | setup | 0 CategoryTypes or 0 StandardTimings for the season | `CategoryType.where(season_id:).count`, `StandardTiming.where(season_id:).count` | cheap | error if current or upcoming; info if closed | Season: counts | Link to `docs/HOWTO_prepare_new_season_at_championship_start.md` | 13 season-start checklist |
| `swimmers.possible_duplicates` | people | New detector, see step 8 | New SQL + Ruby | medium | warning only | Swimmer pair, years, genders, shared teams | Rake `check:swimmer src= dest=`, ignore | 11 `swimmer.merge` |

Every finding carries at least one of: a button, a deep link, a copyable rake command, or a how-to text. All four exist in en and it.

Null swimmers must be fixed before duplicates are deleted. The report groups NULL `swimmer_id` values together (`duplicate_result_cleaner.rb:117-125`), but the generated DELETE joins on `mrs1.swimmer_id = mrs2.swimmer_id` (lines 397-400), which never matches NULL. `find_duplicate_mirs` silently skips NULL swimmers (line 82). The `results.duplicates` detail says so whenever the same meeting has a `results.null_swimmers` finding.

### Query sketches (column names checked against goggles_db `spec/dummy/db/structure.sql`)

`meetings`: `cancelled`, `results_acquired`, `manifest`, `header_date`, `season_id`, `code`, `description`. `calendars`: `meeting_id`, `cancelled` (NOT NULL), `results_code`, `results_link`, `scheduled_date` (varchar), `season_id`. `Meeting` and `Calendar` have eager-loading default scopes (`meeting.rb:30`, `calendar.rb:25`), so every query uses `unscoped`.

```ruby
# Health::SeasonFacts#meeting_rows: meeting-driven, because DbIndex starts from calendars
GogglesDb::Meeting.unscoped
  .joins('LEFT JOIN calendars c ON c.meeting_id = meetings.id')
  .where(season_id:)
  .pluck(*%w[meetings.id meetings.code meetings.description meetings.header_date meetings.cancelled
             meetings.results_acquired meetings.manifest c.id c.cancelled c.results_code c.results_link]
            .map { Arel.sql(_1) })
```
```sql
-- Health::SeasonFacts#counts: one grouped query (LEFT JOINs so that meetings without sessions show 0)
SELECT m.id, COUNT(DISTINCT me.id) ev, COUNT(DISTINCT mir.id) mir, COUNT(DISTINCT mrr.id) mrr
FROM meetings m
LEFT JOIN meeting_sessions ms ON ms.meeting_id = m.id
LEFT JOIN meeting_events me ON me.meeting_session_id = ms.id
LEFT JOIN meeting_programs mp ON mp.meeting_event_id = me.id
LEFT JOIN meeting_individual_results mir ON mir.meeting_program_id = mp.id
LEFT JOIN meeting_relay_results mrr ON mrr.meeting_program_id = mp.id
WHERE m.season_id = ? GROUP BY m.id
```
"No results" means `mir + mrr = 0`. `check:results` counts either MIRs or MRRs, never both (`check.rake:42`). `api_meetings#no_mirs` counts MIRs only (`api_meetings_controller.rb:118-121`), so a relay-only meeting looks empty to both tools.

```ruby
# calendars.unlinked
GogglesDb::Calendar.unscoped.where(season_id:, cancelled: false)
  .joins('LEFT JOIN meetings m ON m.id = calendars.meeting_id').where('m.id IS NULL')
# results.null_swimmers prefilter (same for MeetingRelaySwimmer via meeting_relay_result)
GogglesDb::MeetingIndividualResult.unscoped.joins(meeting_program: { meeting_event: :meeting_session })
  .joins('JOIN meetings ON meetings.id = meeting_sessions.meeting_id')
  .where(meetings: { season_id: }, swimmer_id: nil).group('meetings.id').count
# results.dup_mir_per_badge
GogglesDb::MeetingIndividualResult.unscoped.joins(meeting_program: { meeting_event: :meeting_session })
  .joins('JOIN meetings ON meetings.id = meeting_sessions.meeting_id').where(meetings: { season_id: })
  .group('meetings.id', :badge_id, 'meeting_programs.id').having('COUNT(*) > 1').count
```

The badges group calls `Merge::BadgeSeasonChecker.new(season:).run` once (`badge_season_checker.rb:122, 176`). It never calls `display_report`, which prints ANSI-coloured text (lines 281-295). The results group reuses `PostCommitChecks.build_duplicate_results_check_report(season)` unchanged.

## Data model

Ops migrations (SQLite, `db/ops_migrate/`):

**`health_runs`**: `season_id!` (int), `group_key!` (meetings|badges|people|results|setup), `trigger!` (scheduled|manual|post_commit|catch_up|after_operation; `after_operation` is used by 11's operations), `status!` (queued|running|succeeded|failed|skipped), `check_versions` json, `stamp` (string), `counts` json (per check key: open/new/resolved), `findings_count`, `new_count`, `resolved_count`, `duration_ms`, `db_epoch`, `error_message` text, `job_id`, `started_at`, `finished_at`, timestamps. Index `(season_id, group_key, finished_at)`. Only the last 20 rows per (season, group) are kept.

**`health_findings`**: `season_id!`, `group_key!`, `check_key!`, `fingerprint!` (SHA256 hex), `severity!` (error|warning|info), `status!` (open|acknowledged|ignored|resolved), `subject_type`, `subject_id` (int), `subject_ids` (string, sorted ids), `title` (string, interpolated at sync), `payload` json, `payload_digest`, `note` text, `status_changed_at`, `status_changed_by` (user id), `first_seen_run_id`, `last_seen_run_id`, `first_seen_at`, `last_seen_at`, `resolved_at`, timestamps. Unique `(season_id, check_key, fingerprint)`. Indexes `(season_id, group_key, status)`, `(status, severity)`. Phase 11 adds `mitigation_run_id`.

**Fingerprint**: `SHA256("#{check_key}|#{season_id}|#{identity}")`. The identity uses entity ids only: `meeting:19412`, `calendar:881`, `swimmer:123|badges:45,67` (sorted), `teams:12,34` (sorted), `badge:45`, `swimmers:7,9` (sorted). Names, counts and dates are never part of it.

**Sync rules** (`Health::FindingSync`, run only after a group run succeeds):
1. Upsert every finding seen. New rows start as `open`. Rows seen again refresh `last_seen_*`, `payload`, `payload_digest` and `title`, and keep their status.
2. Unseen `open` or `acknowledged` findings of that season and group become `resolved` (hidden by default, pruned 180 days after `resolved_at`). Unseen `ignored` findings stay `ignored`.
3. A `resolved` finding seen again goes back to `open` and keeps its note.
4. An `acknowledged` finding whose `payload_digest` changed goes back to `open`. An `ignored` finding stays ignored whatever changes.
5. A failed run resolves nothing. A skipped run touches nothing.

## Schedule and runs

- `Health::SeasonRunJob.perform_later(season_id:, group:, trigger:)` runs on `queue_as :maintenance` with `limits_concurrency key: ->(season_id:, group:, **) { "health-#{season_id}-#{group}" }, to: 1, on_conflict: :discard`. Solid Queue 1.7.2 supports `on_conflict: :discard` (`Gemfile.lock:713`). Priorities: on-demand 5, sweeps 10. The job takes no retries; the next sweep catches up.
- `config/queue.yml`: add `- queues: maintenance, threads: 1, processes: 1, polling_interval: 2` under `workers`. Phase 11 operations and phase 14 restore share this worker.
- `config/recurring.yml`: add `health_sweep: { class: Health::SweepJob, queue: maintenance, schedule: every hour at minute 45 }`. The schedule is only a heartbeat. Solid Queue does not replay recurring runs missed while the machine was off, so `SweepJob` decides what is due from `health_runs`:
  - Current season: due when its last successful run per group is older than 24 h, and not before 06:30 (after the 05:15 `season_board_recheck`).
  - Closed seasons: due when the last successful run is older than 7 days. Before running heavy groups, `Health::Stamp` (count, max id and max `updated_at` of the season's meetings and badges, MIR+MRR count, mtime of `results.new/<season>`) is compared with the last succeeded run. If the stamp is unchanged, a `skipped` run is recorded and no check runs.
  - At most one closed season is enqueued per heartbeat, so the queue never floods.
- On demand: "Re-run" per cell, per season, or "Run all" (trigger `manual`). After a commit, all groups for the season run with trigger `post_commit`.
- `Health::Runner` stores `db_epoch` (from 01) on each run. Findings from an older epoch are marked "stale data" in the UI until the next run.

## UI and routes

```ruby
get   'health',                                   to: 'health#index',                as: 'health'
get   'health/seasons/:season_id',                to: 'health/seasons#show',         as: 'health_season'
get   'health/seasons/:season_id/sections/:check_key', to: 'health/sections#show',   as: 'health_section'
get   'health/findings/:id',                      to: 'health/findings#show',        as: 'health_finding'
patch 'health/findings/bulk',                     to: 'health/findings#bulk',        as: 'health_findings_bulk'
post  'health/runs',                              to: 'health/runs#create',          as: 'health_runs'
get   'health/cancellations/new',                 to: 'health/cancellations#new',    as: 'new_health_cancellation'
post  'health/cancellations',                     to: 'health/cancellations#create', as: 'health_cancellations'
```

```
Data health (local mirror)                                [Run all]  last sweep Sun 03:02
Season       | Meetings | Badges | People | Results | Setup | Last run
262 current  |  3 !     | 12 !   |  4 ~   |  0      |  ok   | today 06:31 (38s)
252 closed   |  9 !     |  0     |  7 ~   |  1 !    |  ok   | Sun 03:02
242 closed   |  0       |  0     |  2 ack |  0      |  ok   | Sun, unchanged
! error   ~ warning   ack = acknowledged only   click a cell = open that section

Season 252 (closed 2026-09-30)                            [Re-run v]
v Meetings without results, no source (9)   error   ran Sun 03:02, 0.4s
  [x] 19412  2026-03-08  Trofeo X   no source            [Flag cancelled] [Details]
  [ ] 19377  2026-02-01  Trofeo Y   results.new, step 3  [Review]
  status [open v]  severity [all v]  search [____]   [Acknowledge selected] [Ignore selected...]
> Calendar rows never imported (2)      > Duplicate badges, sure (0)
> Duplicate results (1)                 > Null swimmers (0)
```

- Matrix counts are read from `health_findings` grouped by status. A running cell shows a spinner. The page reloads its frame on a `health-ping` broadcast through `AppNotificationsChannel` (same pattern as `SeasonBoard::Notifier.ping`, `notifier.rb:20-26`).
- Bulk actions: acknowledge, ignore (note required), reopen. Each writes `note`, `status_changed_*` and an `Ops::Event`.
- Finding detail shows the evidence, entity links (local grids), the rake command with ids filled in, and the how-to text.
- Dashboard card (`Health::DashboardCardComponent`, lazy frame): current-season errors and warnings, "closed seasons: N errors in M seasons", time of the last sweep.
- Inbox (`Health::InboxSource`): one item per season and group with open errors ("Season 252: 9 meetings without results"); one low-priority item for all open warnings; one item per group whose latest run failed; one "health sweep overdue" item when no run has finished for 8 days (catches a `maintenance` worker that never runs). Never one item per finding.

## Flag cancelled (the only write in 06)

`Health::MeetingCanceller.new(season:, meeting_id: nil, calendar_id: nil)` follows the `SeasonBoard::CalendarLinker` pattern (`calendar_linker.rb:56-73, 116-134`):
- `#preview` writes nothing. It returns the meeting and calendar facts, the current MIR/MRR/event counts, and the SQL built with `SqlMaker.new(row:).log_update('cancelled' => true, 'updated_at' => nil)` (`sql_maker.rb:106`) for the meeting and/or its calendar, plus a digest of that SQL.
- `#call(expected_digest:)` refuses if the meeting now has results or if the digest changed. Otherwise it runs `update!` and writes the file inside one `ActiveRecord::Base.transaction`.
- The script goes to `crawler/data/results.new/<season>/NNNN-meeting_cancel-<meeting_id>.sql` (or `NNNN-calendar_cancel-<calendar_id>.sql`). `NNNN` comes from `FileCounter#compute_file_counter(results.new/<season>, results.sent/<season>)` (`file_counter.rb:30-44`). The header and transaction wrapper match `CalendarLinker` (lines 122-131).
- Controller: `Health::CancellationsController#new` shows the preview. `#create` (operator click with the digest) applies, flashes the script name with a link to Push, enqueues a `meetings` re-run for the season, and records an `Ops::Event`.
- Phase 07 moves this writer onto `Outbox::Writer.write!(kind: 'cancel_flag', folder: <season dir>, ...)` (same file names, still inside the controller transaction). Phase 11 replaces it with the `meeting.set_cancelled` operation and deletes `Health::MeetingCanceller`.

## Ordered steps

1. **Queue and tables** (not user-visible): `maintenance` worker in `config/queue.yml`; `spec/config/queue_names_spec.rb` (eager-load jobs, compare every `queue_name` and every `recurring.yml` queue with the workers' queues); ops migrations and models `Ops::HealthRun`, `Ops::HealthFinding`.
2. **Health core** (not user-visible): `Registry`, `SeasonScope`, `FindingSync`, `Stamp`, `Runner`, `SeasonRunJob`, with specs. No checks yet.
3. **Cheap groups** (user-visible, CHANGELOG + PATCH): `SeasonFacts`, the six `meetings` checks and `season.setup`, plus a minimal read-only `/health` matrix and season page. This alone answers the operator's "meetings without results" question for every season.
4. **Heavy groups** (user-visible, CHANGELOG + PATCH): `badges` (one checker run, four keys) and `results` (duplicates, null swimmers, dup MIR per badge). Durations are shown per cell.
5. **Triage UI** (user-visible, CHANGELOG + PATCH): `HealthFindingsGrid`, filters, bulk acknowledge/ignore/reopen, finding detail with rake command and how-to, live refresh, en+it.
6. **Flag cancelled** (user-visible, CHANGELOG + PATCH): `Health::MeetingCanceller`, cancellations controller, `BOARD_SQL_REGEXP` extension with its DiskIndex spec.
7. **Scheduling, hooks, dashboard** (user-visible, CHANGELOG + PATCH): `SweepJob` + `recurring.yml`, stamp skip, post-commit enqueue (the line 220 scan is kept), dashboard card, inbox source, navigation entry.
8. **People group** (user-visible, CHANGELOG + PATCH): `swimmers.possible_duplicates`, warning only. (a) Same `complete_name`, different `year_of_birth`, at least one badged in the season: `badges b JOIN swimmers s1 ON s1.id = b.swimmer_id JOIN swimmers s2 ON s2.complete_name = s1.complete_name AND s2.id <> s1.id WHERE b.season_id = ?`. Exact duplicates cannot exist because of the unique key `name_and_year`. (b) Within each (team, gender, birth year) bucket of season badges, names with Jaro-Winkler >= 0.92 (configurable through `Ops::Setting`). A global team pass is deferred.

## Specs and manual verification

- `finding_sync_spec`: same finding across two runs keeps its id and status; unseen becomes resolved; failed run resolves nothing; acknowledged with changed digest reopens; ignored stays ignored; resolved seen again reopens with its note.
- `checks/meetings_spec` (factories): past meeting with no results and no file; same with a results source in a tmp `data_dir`; calendar cancelled but meeting not; cancelled meeting with MIRs; calendar without meeting; meeting without events; **relay-only meeting is not reported**; future meeting is not reported.
- `checks/badges_spec`, `checks/results_spec`: two badges for one swimmer (same team; teams sharing a meeting; similar names); duplicate MIR/MRS rows; a NULL-swimmer MRS pair pins the report-versus-delete mismatch. Fingerprints are stable across runs.
- **No-write spec**: subscribe to `sql.active_record` during `Runner` for every group. On the primary connection (`payload[:connection].pool.db_config.name == 'primary'`), no statement may match `/\A\s*(INSERT|UPDATE|DELETE|REPLACE|TRUNCATE|ALTER|CREATE|DROP)/i` (SAVEPOINT/RELEASE are ignored).
- `season_run_job_spec`: enqueues on `maintenance`; a duplicate enqueue is discarded; writes a run with `duration_ms`; a check that raises gives a failed run and resolves nothing.
- `sweep_job_spec`: with frozen time, a current season with a 25-hour-old run is due; a closed season with an unchanged stamp is recorded as skipped; a machine off for 10 days catches up one closed season per heartbeat.
- `meeting_canceller_spec`: preview writes nothing; a digest mismatch is refused; a meeting with results is refused; success writes one file whose name matches `BOARD_SQL_REGEXP` and is absent from `DiskIndex#unmatched`.
- Request specs: matrix counts; bulk ignore requires a note; `POST /health/runs` enqueues; API-offline sessions can reach nothing here (`api_offline_allowed?` stays false).
- Manual: run a closed-season sweep on the real local DB and note the durations. For one season, compare `meetings.no_results.*` with `bin/rails check:results season=<id>` and `check:results season=<id> mrr=true`: health must list the intersection minus cancelled and future meetings. Compare badge counts with `check:season season=<id>` (summary lines from `display_short_summary`, `badge_season_checker.rb:289-295`). Compare null swimmers with `fix:nil_swimmers_in_results season_id=<id>` (default simulate) totals.

## Exit criteria

- On one closed season, counts match the corresponding rake tasks as described above.
- The no-write spec passes for every group.
- Every row of the check-to-action table has, in 06, a button, a deep link, a rake command or a how-to text in en and it. Phases 11 and 13 add the buttons named in the "Button in" column, and their exit criteria refer to this table.
- Every job's `queue_as` is served by a worker (queue spec green).
- Health pages render with the API offline; the dashboard card and inbox read only ops rows.
- Routine gate: sign in → board → crawl → review → commit → report (still shows the synchronous post-commit checks) → push (including a `meeting_cancel` script from the season folder) → confirm still works.

## Risks and mitigations

- Heavy groups slower than expected (`BadgeSeasonChecker` runs about a dozen queries per multi-badge swimmer; duplicates run 5 per meeting). Durations are recorded per run and groups run as separate jobs. If a group takes more than about a minute, add a grouped SQL prefilter and run the existing classes on flagged rows only.
- Findings reflect the local mirror, which may have drifted from production. Mitigations: the "local mirror" label, `db_epoch` on runs, and in 08 the drift verdict shown on the page.
- False positives from the people group. Mitigations: warning only, never one inbox item per finding, ignore persists by fingerprint, thresholds in settings, shipped last.
- Flag cancelled is visible on the public site once pushed. Mitigations: dry-run preview, refused when results exist, ignore-with-note offered next to it.
- A missing `maintenance` worker would mean silent non-execution. Mitigations: the queue spec and the "sweep overdue" inbox item.

## Decisions to confirm

- A meeting that took place but never published results: offer both "flag cancelled" and "ignore with note". **Default: both, ignore listed first.**
- Folder for the 06 cancel scripts. **Default: `results.new/<season>/`** with the `BOARD_SQL_REGEXP` extension, so the existing per-season push order holds. 07 re-files them through the Outbox.
- Source files on disk without a FIN id (`DiskIndex#unmatched`) carry no entity id. **Default: not reported in 06** (the board already lists them for the current season).
- People thresholds. **Default: Jaro-Winkler 0.92, same team and birth year.**
- Recent boundary for the current season. **Default: 14 days after `header_date`.**

## Out of scope

Fix buttons other than flag cancelled (11, 13); replacing the synchronous post-commit scan (09); crawling closed-season meetings (`MeetingCrawlJob` refuses FIN ids not on the watcher snapshot, `meeting_crawl_job.rb:87-94`; Sources in 15); a global team-duplicate pass; drift gating (08).

## Rollback note

Remove the `health_sweep` entry and the `maintenance` worker (no other job uses them before 11), drop the routes and navigation entry. Ops tables can stay, or be removed with `rake ops:reset`. The primary DB is never touched, except for meetings and calendars the operator flagged, whose scripts are ordinary numbered files. Reverting the `BOARD_SQL_REGEXP` change would make pending cancel scripts appear as unmatched sources, so push them first.
