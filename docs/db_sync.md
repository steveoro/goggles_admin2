# DB sync

Does the local development DB (a production copy) still mirror production? The **DB sync** check answers with a verdict (green / amber / red / unknown) and its reasons. Page: `/db_sync` (sidebar **Data quality > DB sync**); pill: **DB sync** in the top bar and in the dashboard System zone; inbox: a red verdict is a "blocked" item, an amber one a notice.

Everything shown comes from the stored checks (ops DB table `db_fingerprints`, `Ops::DbFingerprint`): the page, the pill and the inbox never call the API, so they render in an API-offline session too.

## What is compared

For the 21 whitelisted tables of the API endpoint `tools/db_fingerprint` (`Drift::Tables`: the meeting hierarchy, laps, swimmers, teams, badges, calendars, pools, cities, managed affiliations, standard timings, category types, users):

- **count** and **max id** on both sides (never timestamps for equality: the pushed scripts write `NOW()` on the server);
- the remote **max updated_at** of the import-owned tables, only against the time of the last script seen applied on the server;
- the schema versions (max of `schema_migrations`), the failed SQL batches on the server, and the local facts: Outbox scripts still to apply on the server, failed or deleted on the server, admin2's own remote-only writes (`Ops::RemoteWrite`, the `/remote_writes` log; the Outbox queue actions are not counted).

A **full** check (count + max id + max updated_at) runs every 30 minutes (`DriftCheckJob`, recurring `drift_check`, queue `default`), after each push run and on **Check now**. A **light** check (max ids only, a primary-key lookup) is taken by the gates when the last check is older than 10 minutes. The server caches each answer for 60 s. Only the last 200 checks are kept.

## Verdicts

| Verdict | When |
|---|---|
| green | same count and max id everywhere; or the local DB is ahead while scripts are still to apply on the server ("local ahead by N scripts") |
| amber | same max id, different count; remote-only writes since the last green check (or acknowledgement); an import-owned table updated on the server after the last applied script; local ahead with nothing left to push; a remote max id above the local one on a table the commits never insert into (e.g. `users`); a script deleted on the server; a green check older than 2 hours |
| red | a remote max id above the local one on a table the Phase 6 commit inserts into (e.g. laps added by users: the next commit would collide); a script failed on the server (or one that was not a single transaction: it may be partially applied); failed SQL batches on the server; different schema versions |
| unknown | no comparison: API unreachable, no or expired background JWT (sign in again), an API without the `db_fingerprint` capability (older than goggles_api 0.10.82), ops DB not ready |

The remote UPDATEs are invisible to counts and max ids: that is why admin2's own remote writes turn the verdict amber until you **Acknowledge** them (here or on `/remote_writes`), and why a red verdict is solved by restoring a fresh production dump (phase 14), not by a quick fix.

## Gates

`Drift::Gate.check(scope:, acknowledged: false, force: false, tables: nil)` returns `level` (`:ok`, `:warn`, `:block`), `allowed?`, `verdict` (the `Ops::DbFingerprint` used) and `reasons` (`{ code:, table:, local:, remote: }`, texts `db_sync.reasons.<code>`):

| Scope | Used by | red | amber / unknown |
|---|---|---|---|
| `:commit` | Phase 6 commit (phase 09, through `DataFix::Guards`) | block | warn |
| `:prepare` | phase 10 prepare job | block | warn |
| `:operation` | phase 11/13 maintenance apply (never a dry run) | block | warn |
| `:push` | Outbox push confirmation, `OutboxController#push`, `Outbox::Pusher` | warn | warn |
| `:board_write` | Season board **Link to meeting...** | warn | warn |
| `:rake` | `rake season_board:backfill simulate=0` (and 13's rake callers) | block, unless `force=1` | warn (printed) |

A warning needs the operator's tick (the push confirmation, the board link confirmation page); `allowed?` is `ok`, or `warn` with the tick, or `force` (rake only).

## The page

- the verdict with its reasons, the check time, trigger and mode, the environment and version reported by the API, the schema versions, the scripts not applied on the server yet;
- the per-table comparison (local / remote rows and max ids, max id difference, remote last update; red and amber rows highlighted);
- admin2's remote-only writes since the last green check;
- the last 20 checks (each opens as `?id=`).

**Check now** queues a full check; the page updates when it is stored.

**Restore local DB...** (0.10.91) opens the guided restore wizard: when the verdict stays red, replace the local DB with a production dump (see `docs/db_restore.md`); the restore ends with a check (trigger `post_restore`).

## After an API upgrade

The verdict stays **unknown** until the API answers its `status` with the `db_fingerprint` capability (goggles_api 0.10.82): the status refresh (every 5 minutes) stores it, then the next check compares.
