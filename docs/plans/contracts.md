# Cross-phase contracts

The 15 phase files were written by separate authors. Where they disagree on a shared name or interface, the phase that OWNS the thing wins and every other file (and every implementation) must use the owner's wording. These rulings settle the disagreements found while the plans were written; implementations follow them too.

## Ops building blocks — owner: phase 01
- `Ops.available?`, `Ops.state`, `Ops.safely { }`.
- Events are written with `Ops.record_event!(kind:, level:, actor:, season_id:, subject_type:, subject_key:, data:, link_path:)`; i18n keys `ops.events.<kind>` in en + it. No other spelling (`Ops::Event.record`, `Ops::Event.create!` at call sites) is allowed in later phases.
- `Ops::Snapshot.write!` / `Ops::Snapshot.read`; `Ops::Setting.fetch` / `Ops::Setting.store!` / `Ops::Setting.db_epoch`.
- `rake ops:rebuild` runs a registry: `Ops::Rebuilders.register`. Phases 07 and 09 register their reconcilers there (inside `Rails.application.config.to_prepare`, the registry is reloadable).
- `Ops::Database.backup!(label:)`; phase 14 calls it with `label: 'pre_restore'`.
- Ops file: `db/ops/<env>.sqlite3`. Migrations hand-written in `db/ops_migrate/`, one per table, shipped by the phase that first writes the table.

## Ops tables and models (table -> model, owner phase)
events -> Ops::Event (01); settings -> Ops::Setting (01); snapshots -> Ops::Snapshot (01); remote_writes -> Ops::RemoteWrite (05); health_runs -> Ops::HealthRun, health_findings -> Ops::HealthFinding (06); sql_scripts -> Ops::SqlScript, push_runs -> Ops::PushRun (07); db_fingerprints -> Ops::DbFingerprint (08); pipeline_sources -> Ops::PipelineSource, phase_verdicts -> Ops::PhaseVerdict, commit_reports -> Ops::CommitReport, pipeline_runs -> Ops::PipelineRun (09); operation_runs -> Ops::OperationRun (11); season_checklist_items (13); restore_runs -> Ops::RestoreRun and the ops `sessions` table (14).
Any other table or model name for the same thing (e.g. outbox_scripts, data_fix_sources, data_fix_phases, data_fix_runs, maintenance_runs, health_check_runs, db_sync_snapshots, db_restores, remote_mutations) must be replaced by the names above.

## Snapshot keys
- `api.status:<base_url>` — ONE key. Created in phase 04 with the ping/reachability fields; phase 08 extends its payload with `environment` and `capabilities`. Do not use a separate `api.ping:<base_url>` key.
- `system_status.<probe_key>` (04); `kpi:<api_url>` (05); `season_board:<season_id>` (05); `drift_v0:<base_url>` (05, replaced in 08 by Ops::DbFingerprint rows).

## Shell — owner: phase 04
- `Shell::Navigation` at `app/services/shell/navigation.rb` (`groups`, `item_for`, `breadcrumbs_for`, `palette_entries`). Later phases ADD their items: health (06), outbox replaces push (07), db_sync (08), operations (11, extended in 13), sources (15). Each of those phase files must say it adds its navigation item.
- `Shell::PageHeaderComponent(title:, count:, subtitle:, crumbs:)` with an `actions` slot.
- `SystemStatus::Probe` / `Result` / `Registry`; a result has `label`, `level` (`:ok`, `:warn`, `:error`, `:unknown`), `detail`, `checked_at`, optional `action`. Phase 05 extends the registry, it does not recreate it.
- Shared progress partial after phase 02: `app/views/goggles/_modal_progress.html.haml`, keeping ids `#modal-progress`, `#progress-msg`, `#di-progress`.
- Compat layer: `app/assets/stylesheets/compat/_bs4.scss`, `app/javascript/bs4_compat.js`, `spec/bs4_leftovers_spec.rb` with `SWEPT` and `BASELINE`. Phases 05, 07, 12 and 15 add their folders to `SWEPT`.
- Spec changes for Bootstrap markup: in 03 only `sql_create_modal_component_spec.rb` changes (plus one additive assertion in the turbo filter state component spec); grid specs and the season board row spec change in 04; the Data-Fix phase 2/3 request specs change in 12.

## Inbox — owner: phase 05
- `Inbox::Item`, `Inbox::Source` (`key`, `items(context)`, `enabled?`), `Inbox::Registry.register` / `.replace`, registered in `config/initializers/inbox.rb`.
- Phase 07 calls `Inbox::Registry.replace(:pending_sql, ...)` with a source that reads `Outbox::Summary.call`. Phase 06 registers health sources; phase 10 registers ready-to-commit / needs-review / prepare-failed sources and upgrades the "sessions in review" source.
- `DataFix::StagingPurger` is introduced in phase 05 (phase 01 only added a per-source parameter to the existing purge action). Phase 14 reuses it; it does not extract it again.

## Outbox — owner: phase 07
- `Outbox::Writer.write!(kind:, name:, sql:, folder:, season_id: nil, applied_locally: true, held: false, origin: {}, data_root:) -> Ops::SqlScript`; `Outbox::Writer.discard!(script)`; `Outbox::Writer.mark_applied_locally!(path_or_script)`.
- `Outbox::Sequence.next!` / `.current_max(data_root:)`; `LocalDb::SqlRunner.call(path:)` returns a result object and never calls `exit`.
- `Ops::SqlScript`: `rel_path` is the unique key; `sha256` is indexed and used to follow moves (recorded as a decision to confirm in 07).
- Maintenance / cross-season scripts go to `crawler/data/results.new/misc/`. Never `results.new/maintenance/`.
- Phase 06's "flag cancelled" writes `NNNN-meeting_cancel-<id>.sql` into `results.new/<season>/` with the existing local-apply pattern and extends `SeasonBoard::DiskIndex::BOARD_SQL_REGEXP`; phase 07 moves that writer onto `Outbox::Writer`; phase 11 replaces it with the `meeting.set_cancelled` operation. All three files must say the same thing.
- Phases 11 and 13 call `Outbox::Writer.write!` (not `register!`, not `lines:`).
- goggles_api documentation is Swagger (`add_swagger_documentation`), not API Blueprint.

## Drift and restore — owners: phase 08 and phase 14
- `Drift::Gate.check(scope:, acknowledged: false, force: false, tables: nil)` returning an object with `level` (`:ok`, `:warn`, `:block`), `allowed?`, `verdict`, `reasons`. Scopes: `:commit`, `:push`, `:prepare`, `:operation`, `:board_write`, `:rake`. Phase 09 uses `:commit`, phase 10 `:prepare`, phases 11 and 13 `:operation` (checked BEFORE planning an apply, never on a dry run).
- `DbRestore::Lock.active?` / `.current_run` / `.acquire!` / `.release!`; controllers guarded by `DbRestoreGuard`; every job guarded by an `around_perform` in `ApplicationJob`, so all jobs from 06, 09, 10, 11, 13 inherit `ApplicationJob`. Phase 09's `DataFix::Guards` wrapper (a no-op while the constants are undefined) is the accepted way to call both before 08/14 exist.

## Queues and concurrency
- Workers: `maintenance` added in 06, `outbox` in 07, `pipeline` in 09. `spec/config/queue_names_spec.rb` is created in 06 and extended by 07 and 09.
- Concurrency keys: `local_db_writer` is shared by `DataFixCommitJob` (09) and `Maintenance::RunJob` in apply mode (11) because both write the local primary DB. `DataFixPrepareJob` (10) uses `data_fix_pipeline`. `Outbox::PushJob` uses `outbox_push`.
- Jobs that commit, push, apply a maintenance script or restore are enqueued only by a controller action from an operator click, retries disabled.

## Data-Fix facts shared across phases
- After phase 02 the `phaseN_v2` flags are optional; team scores live in `phase2.json` under `data.team_scores` (`team_key`, `rank`, `ind_score`, `overall_score`); phase 09's runner and verdicts treat a Phase 2 rebuild as rebuilding them, and the commit summary lists `team_scores_created/updated/skipped`.
- Phase 06 KEEPS the synchronous post-commit scan (`commits_controller.rb`) and also enqueues a health run after a commit; phase 09 removes the synchronous scan when the report becomes persistent.
- `DataFix::ResultDetailsSetComponent` / `ResultDetailsCardComponent` and `Switch::RotatingComponent` were deleted in phase 02.
- Locale files are per feature: `config/locales/<feature>.{en,it}.yml`.

## Depends-on table (must match each file's "Depends on" section)
01: none · 02: 01 · 03: 01, 02 · 04: 03 · 05: 01, 04 · 06: 01, 04, 05 · 07: 01, 04, 05 · 08: 07 · 09: 01, 02, 07 · 10: 05, 09 · 11: 06, 07, 08, 09 · 12: 04, 09 · 13: 11 · 14: 07, 08 · 15: 04, 10, 12.
A file may mention softer links to other phases (for example "06's health job is triggered here") but its Depends-on section must list exactly these as the hard dependencies.

## Standing rules
- "Staging" means the import staging tables (`data_import_*`). The deprecated staging environment gets no new behaviour.
- No job commits, pushes, applies or restores without an operator click. No bulk commit.
- Values a job computes for the UI live in the ops DB, never in `Rails.cache`.
- Never quote credentials, tokens or webhook URLs; refer to files by path only.
- All work happens on the branch `feature/modernize-admin-console-ux` (same branch name in any other framework repo touched); `main` is merged into it before each phase.
