# Guided local DB restore

When the DB sync verdict (`/db_sync`, see `docs/db_sync.md`) is red and the local development DB should mirror production again, the wizard at `/db_restore/new` replaces the local MySQL DB with a production dump already on disk, keeping the local-only state. Entry points: the "Restore local DB..." button on `/db_sync`, and the secondary link of the red DB sync item in the dashboard inbox.

Fetching a dump from production stays manual: production dumps are made by `db:dump` inside the server container (`/app/db/dump/production.sql.bz2`, i.e. `~/Projects/goggles_deploy/backups` on the server); copy one by hand to `goggles_main/db/dump/production-NNNN-label.sql.bz2`. Restoring production, rebuilding the test DB and upgrading the engine stay in the terminal.

## What a restore keeps and changes

- **Kept**: your sign-in (the web sessions live in the ops DB since 0.10.91, `Ops::SessionStoreSetup`), the API URL (by default; you can take the dump's instead), the ops DB (Outbox registry, health findings, events, verdicts, commit reports, this history) and every file under `crawler/data`. The queue, cable and cache SQLite DBs are not touched either.
- **Replaced**: everything in MySQL, including `users`, `settings` / `app_parameters` (then fixed by the post-steps) and the five `data_import_*` staging tables (then purged).
- **Re-applied by the post-steps**: `ar_internal_metadata.environment` back to `development` (a production dump says `production`, which makes Rails refuse destructive DB tasks), the API URL, your API token (`users.jwt`: kept in the ops row only until re-applied or the run ends, never shown nor written to the logs: its statements run with the SQL log silenced and error texts are scrubbed), maintenance flag off.
- **Marked stale**: `db_epoch` and `data_fix.db_generation` are bumped, so the Data-Fix verdicts and new-entity matches are recomputed and every process reconnects its MySQL pool; the remote-only writes logged before the dump time count as covered (the `/remote_writes` acknowledgement moves forward to the dump time, never back).
- **Reported, never run**: engine migrations newer than the dump (the result page prints the command, `cd ~/Projects/goggles_main && bin/rails db:migrate`; restart admin2 afterwards). A dump *newer* than the local engine is refused at inspection: update goggles_db first (`./update_engine.sh`).
- **Not replayed**: Outbox scripts pushed after the dump was taken are listed as a warning (inspection and result): pick a newer dump.

## The wizard

0. **Guards** (refused with the reason): `Rails.env` is `development`; the primary DB host is the local socket, `localhost`, `127.0.0.1` or `::1`; the DB name is not a production name (`goggles`) and is the `development` entry of `config/database.yml`; the ops DB is ready; no other run is open.
1. **Preconditions**: the Outbox has no `pending`, `held`, `pushing`, `sent`, `in_doubt` or `failed` script (push, withdraw or discard them first: a failed one also blocks the server queue); no push run is live; no `DataFixCommitJob`, `Maintenance::RunJob`, `Health::SeasonRunJob` or `Health::SweepJob` is running, and none of the first three is queued (skipped through the lock, its commit report / operation / health run would stay queued); Data-Fix reviews in progress (phase files in `results.new`, staging rows) need the "discard" tick. Other running jobs are listed: the load waits for them.
2. **Dump**: the `production*.sql.bz2` files of the dump folders, newest first. Default folders: `goggles_main/db/dump` and this app's `db/dump`; edit them in the "Dump folders" box (stored in the ops setting `db_restore.dump_dirs`).
3. **Inspection** (`DbRestore::InspectJob`, about a minute): `bzip2 -t`, then one streamed pass reading the `db:dump` header (it must name a production dump), the table list, the newest `schema_migrations` version, the `import_queues` auto-increment, the dump's API URL and the "Dump completed" date.
4. **Safety snapshot** (`DbRestore::SnapshotJob`, on by default, skippable with a tick): `mariadb-dump --single-transaction` of the current local DB to `<first dump folder>/development-<NNNN>-pre-restore.sql.bz2` (same header/footer as `db:dump`, definers stripped), plus an ops DB backup (`db/dump/ops-development-pre_restore-*.sqlite3`). Needs free space for 3 times the dump.
5. **Confirmation**: type the database name; choose the API URL (keep / dump's) and the load (wizard / terminal). Confirming takes the restore lock, pauses the `default`, `background`, `pipeline` and `outbox` queues (queued jobs wait, they are not lost) and opens the progress page.
6. **Load** (`DbRestore::RestoreJob`, `maintenance` worker): waits up to 10 minutes for the running jobs, re-checks the preconditions, captures what must be kept, then `DROP DATABASE` / `CREATE DATABASE` and streams `bunzip2 -c` into `mariadb --database=<db>` (no uncompressed copy on disk; progress = compressed bytes read). The sandbox line of recent dumps is kept for clients that understand it (MariaDB 11.8 does), dropped for older ones.
7. **Post-steps**: see "re-applied" and "marked stale" above, then the lock is released, the queues resume (in this order: a job claimed while the lock is held would be skipped) and a DB sync check runs (`DriftCheckJob`, trigger `post_restore`).
8. **Result**: the post-step outcomes, the DB sync verdict, the pending migrations, and on failure the safety snapshot with the command to load it.

## While a restore runs

- Every page answers **"Local DB restore in progress"** (HTTP 503, restore layout, no MySQL access); JSON requests get `{"error":"db_restore_in_progress"}`. The browser that confirmed the run gets a link to the progress page.
- Every background job but `DbRestore::RestoreJob` skips (event `db_restore.job_skipped`); recurring jobs simply run next time. The Outbox push and the Data-Fix commit are also refused at enqueue.
- The **progress page** (`/db_restore/<id>`) polls `/db_restore/<id>/status.json` every 2 seconds (no Action Cable). It answers only local requests carrying the run's one-time token in the URL (shown once, as the page's bookmark link after the confirmation; only its digest is stored), or from the browser holding the run's grant (set by the confirmation or by opening the token link; the session keeps only the run id and a 24-hour expiry).
- Don't restart the server while the database is dropped: in development the pending-migration check of the first request would fail before the app can answer.

## Interrupted runs

If the load or a post-step fails after the drop, the run becomes **interrupted** and the lock stays (the app keeps answering "restore in progress"). A run whose heartbeat stopped for 2 minutes (the worker died) is shown the same way. The progress page offers:

- **Resume from load**: drops and reloads the same dump, then the post-steps;
- **Load safety snapshot**: drops and loads the snapshot (the state before the restore), then the post-steps;
- **Abandon** (type the DB name): releases the lock and resumes the queues without finishing; the local DB may be empty or half loaded, so load the snapshot or another dump from the terminal afterwards.

If the web UI itself is unusable: `bin/rails db_restore:status`, then `bin/rails db_restore:abandon database=<name>` (ops DB only; never touches MySQL).

## Terminal fallback

At the confirmation, choose "I'll load it from the terminal". The wizard takes the lock, pauses the queues, waits for the running jobs and captures the values to keep, then shows the command:

```bash
# the dump already in goggles_main/db/dump:
(cd ~/Projects/goggles_main && bin/rails db:rebuild from=production-NNNN-label to=development)
# a dump elsewhere (e.g. goggles_admin2/db/dump):
cp /path/to/production-NNNN-label.sql.bz2 ~/Projects/goggles_main/db/dump/ && (cd ~/Projects/goggles_main && bin/rails db:rebuild from=production-NNNN-label to=development)
```

Run it, then click **"Load done, run post-steps"**: the wizard checks that `schema_migrations` and the core tables are there and runs step 7. The same command loads the safety snapshot by hand (`from=development-NNNN-pre-restore`).

## After updating to 0.10.91

1. `bin/rails ops:prepare` (creates the ops `sessions` and `restore_runs` tables).
2. Restart the server: the sessions move to the ops DB, so you sign in once more. Until the ops DB is ready the sessions stay in MySQL.

## Internals

`DbRestoreController` (wizard + progress actions), `DbRestoreGuard` (prepended in `ApplicationController`), `DbRestore::{Lock, JobGuard, Reconnect, Target, Queues, DumpCatalog, DumpInspector, Preconditions, Snapshot, Preserver, Loader, Commands, PostSteps, Restorer, TerminalCommand}`, jobs `DbRestore::{InspectJob, SnapshotJob, RestoreJob}` (all on `maintenance`, no retries; `RestoreJob` enqueued only by `DbRestoreController`), ops tables `restore_runs` (`Ops::RestoreRun`, also the history) and `sessions`, ops settings `db_restore.lock`, `db_restore.dump_dirs`, `db_epoch`. Events `db_restore.{confirmed,finished,rolled_back,failed,interrupted,abandoned,job_skipped}`. Credentials go to the MySQL clients only as `MYSQL_PWD` in the child environment, never on a command line or in the run log.
