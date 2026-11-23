# SQL Outbox

Every SQL script that changes the local DB, whatever wrote it, is registered in **one ordered list** (the ops DB table `sql_scripts`, `Ops::SqlScript`) and pushed to the API from **one page**, `/outbox` (sidebar **Import > Outbox**; it replaced the Push page, and `/push/index` redirects there).

The files keep their conventions: `crawler/data/results.new/<folder>/NNNN-<name>.sql` while waiting, moved to `crawler/data/results.sent/<folder>/` once the API accepted them. **The disk decides pending vs sent**; the registry keeps what the disk can't: the global order, the remote import queue id, the target and the outcome.

## The page

| Section | Lists | Filter |
|---|---|---|
| Needs push | `pending`, `held`, `pushing`, `in_doubt`, by sequence; a lock badge "after NNNN" marks a script waiting for a lower one | never filtered: every folder |
| On the server | `sent` ("sent, not verified"), `executed_unreported` ("executed, outcome not reported"), newest first | default: the default season folder + `misc`; "all folders" |
| History (collapsed) | `legacy_sent`, `archived`, `discarded`, `missing` | same |

- `?focus=<filename>` scrolls to and highlights a row: the Season board **Push** button, the board header counter, the commit report and the dashboard inbox item open the Outbox this way.
- Each file name opens the script page: details, origin (producer, meeting, calendar, FIN event, rake task), the SQL preview and the actions.
- The page reloads its frame on the `outbox-ping` broadcast (`Outbox::Notifier`) and every 5 s while a push run is live.
- Without the ops DB the page shows the setup notice (`bin/rails ops:prepare`) and the files waiting in `results.new`, without any action.
- Opening the page rescans the disk (at most every 30 s); **Rescan disk** does it now.

## Pushing

1. **Push next**, **Push all (N)**, **Push selected** (checkboxes) or **Push this script** open the confirmation page: the ordered list, the total size, the target API URL, its environment (a port guess, labelled "unverified" until phase 08), a fresh ping (reachability, maintenance flag, API version) and the validity of your API session.
2. Type the environment label (`production` or `unknown`) and confirm. The environment is never verified in this phase, so the label is always asked.
3. The push runs as `Outbox::PushJob` on its own single-thread `outbox` worker: one script after the other, in sequence order, **stopping at the first error**.

Rules:

- A script never jumps a lower-numbered script in `pending`, `pushing` or `in_doubt` unless that one is held or you tick "override the sequence" (an explicit choice, recorded on the run).
- Held scripts are never pushed. "Push all" is always the whole pending queue, whatever the folder filter.
- Before each POST: the file must be unchanged (sha256) and the script still pending; `pushing` is saved **before** the POST.
- Accepted (`new.id > 0`): remote id, target and time stored, file moved into `results.sent/<folder>/`, state `sent`.
- Rejected or unreachable: back to `pending` with the error, the run stops.
- An unreachable target or an expired JWT aborts the run before the first POST.
- `Outbox::PushJob` is enqueued only by `OutboxController#push` after the confirmation (a spec scans `app/` for it); no retry, ever: a failure is recorded on the run (`Ops::PushRun`: running, finished, stopped, aborted).

## States

```
  Writer / Reconciler (results.new)            Reconciler (results.sent, import)
        |                                              |
        v                                              v
  +-----------+  hold/release  +--------+         +-------------+
  |  pending  |<-------------->|  held  |         | legacy_sent |  (terminal, History)
  +-----------+                +--------+         +-------------+
        | PushJob: before POST                      archived, discarded, missing:
        v                                           terminal
  +-----------+  POST ok: moved to results.sent    +--------------------------+
  |  pushing  |----------------------------------->| sent ("not verified")    |
  +-----------+                                    +--------------------------+
     |  POST rejected / unreachable -> pending          | GET import_queue/:id -> null
     |  left by a dead run                              v  (after 5 min)
     v                                             +--------------------------+
  +-----------+  operator resolves                 | executed_unreported      |
  | in_doubt  |----> sent | pending | discarded    +--------------------------+
  +-----------+
```

- **held**: reason `not_applied_locally` (written but not run on the local DB: rake `simulate=1`, standard timings, normalize), `local_apply_failed`, `operator`, `legacy_folder` (a file found in `redo/` or `results.new/old-subseeded/` before the import). **Apply locally** runs the script on the local DB (`LocalDb::SqlRunner`) and makes it pending, renumbered after the scripts written meanwhile (so the push follows the local-apply order; the rename is logged). **Push without local apply** releases it anyway (the local DB and the server will differ).
- **in doubt**: a push was interrupted (the job died between the POST and the move). It is never re-posted automatically (an explicit-id INSERT would fail, an UPDATE-only script would apply twice): look it up in the remote import queue, then **mark sent** (with its id), **back to pending** or **discard**.
- **discarded**: with a note; the file goes to `results.new/discarded/<folder>/`, never scanned again.
- **missing**: the file is gone from disk; it gets its previous state back when it reappears.
- **sent → executed_unreported**: `Outbox::RemoteStatusJob` (recurring every 2 minutes, also queued by the page) asks `GET import_queue/:id` with the stored admin JWT for every script pushed to the configured API at least 5 minutes ago; a null answer (the row was processed and deleted) means executed. With an expired JWT it changes nothing ("sign in to refresh"). Phase 08 adds the real outcome (applied / failed).

## Producers

All of them call `Outbox::Writer.write!(kind:, name:, sql:, folder:, ...)` exactly where they used to `File.write`, inside their own MySQL transaction, with `Outbox::Writer.discard!(script)` when that transaction rolls back after the write. The bytes are written verbatim (same files as before).

| Producer | Kind | Folder |
|---|---|---|
| Data-Fix Phase 6 commit (`before_commit:` of `Import::Committers::Main#commit_all`) | `commit` | `<season>` |
| Season board calendar link / backfill | `calendar_link` / `backfill` | `<season>` |
| Data health "Flag cancelled" (`Health::MeetingCanceller`) | `cancel_flag` | `<season>` |
| Team managers (`TeamManagerSqlCreate`) | `team_manager` | `<season>` |
| rake merge / fix / purge / recompute / check / import_categories (`process_sql_file`) | inferred from the name | season id given as subdir, else `misc` |
| `rake normalize:coded_names` | `normalize` (held unless `simulate=0`) | `misc` |
| `rake import:standard_timings` | `standard_timings` (held) | `<season>` |
| a file dropped by hand under `results.new/` | inferred (`Outbox::Kinds`) | its folder |

- The sequence (`Outbox::Sequence`) is global: `max(stored floor, registry max, highest NNNN- prefix under results.new/**, results.sent/**, redo/) + 1`, allocated in one SQLite `BEGIN IMMEDIATE` transaction. A rake `index=` option is kept as the file prefix only.
- A Phase 6 commit never succeeds without its registered script: the script is written inside the local transaction (a failed write rolls the commit back). If moving the files to `results.done` fails afterwards, the report says **"Committed, archiving failed"** (its own state, with the script link) and offers **Retry archiving** (idempotent).
- `rake db:run path=...` runs a script locally and marks it applied in the registry (a held one becomes pending).
- Running SQL locally goes through `LocalDb::SqlRunner` (the MariaDB client with an outer transaction; the password in `MYSQL_PWD`, never on the command line).

## Reconciler and the one-time import

`Outbox::Reconciler` converges the registry with the disk. Scan roots, exactly: `crawler/data/results.new/**` (but `discarded/`), `crawler/data/results.sent/**`, `crawler/data/redo/`; never `results.done*`, `results.backup`, `results.old`. Registered files are only stat'ed (re-hashed when size or mtime changed); unknown files are hashed once.

- unknown file in `results.new` → pending (or held when its kind is not applied by default); in `results.sent` → legacy_sent; in a legacy folder → held (`legacy_folder`);
- a registered file moved by hand `results.new` → `results.sent` → legacy_sent (event); back to `results.new` → pending, flagged "changed after push";
- an edited pending file is re-hashed; an edited sent file is flagged "changed after push";
- gone → missing; a `pushing` row older than 10 minutes without a live run → in doubt.

It runs on the Outbox page load (30 s throttle), from the dashboard "Needs you" frame (same throttle), before every push run, from `bin/rails outbox:reconcile` and from `bin/rails ops:rebuild` (`Ops::Rebuilders`, `:outbox`).

The **one-time import** registers what existed before the Outbox (rows only, no file is touched):

```bash
bin/rails outbox:import             # dry run: prints the counts
bin/rails outbox:import simulate=0  # registers the rows
bin/rails outbox:status             # counts per state, next script, last runs
```

`results.sent/**` → legacy_sent; `results.new/old-subseeded/**` and `redo/` → archived ("pre-Outbox leftover", never pushed); the rest of `results.new` → the usual rules (`results.new/normalize/0002-normalize_coded_names.sql`: held, not applied locally). Until it runs the page shows a reminder.

## Dashboard and other links

- The "Needs you" source in the `pending_sql` slot is `Outbox::InboxSource` (`Inbox::Registry.replace(:pending_sql, ...)`), reading `Outbox::Summary.call` (`pending`, `held`, `in_doubt`, `sent_unverified`, `oldest_pending`): one push item (oldest script focused), one failed-band item for pushes in doubt, one notice for held-only scripts. Without the ops DB it falls back to the disk list (`Inbox::Sources::PendingSql`).
- The import queue grid (`/api_import_queues`) shows the `batch_sql` flag and links a pushed batch to its Outbox entry (by remote id).

## Tables (ops DB)

- `sql_scripts` (`Ops::SqlScript`): `seq` (unique), `rel_path` (unique, under `crawler/data`), `filename`, `folder`, `season_id`, `kind`, `sha256` (indexed, used to follow moves), `byte_size`, `file_mtime`, `state`, `previous_state`, `held_reason`, `applied_locally` (nil = unknown), `single_transaction`, `origin` (JSON), `target_api_url`, `target_env`, `remote_iq_id`, `push_attempts`, `pushed_at`, `remote_checked_at`, `resolved_at`, `last_error` (4 KB), `changed_after_push`, `note`.
- `push_runs` (`Ops::PushRun`): `user_id`, `target_api_url`, `target_env`, `script_ids`, `status`, `pushed_count`, `stopped_at_script_id`, `error`, `override_order`, `job_id`, `started_at`, `finished_at`.
- Settings: `outbox.last_seq` (sequence floor), `outbox.reconciled_at` (throttle), `outbox.legacy_imported_at`. Snapshot: `outbox.remote_status`.
