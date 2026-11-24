# Introduction & Overview

## Purpose

`goggles_admin2` is the operations console of the Goggles framework. It runs only on the operator's own computer, against a local copy of the production database, and its job is to:

*   follow the current FIN Masters season and acquire every meeting: calendars, result pages, result PDFs and meeting manifests, crawled from FIN, Microplus, FICR and Go&Swim (Season board, Sources);
*   turn those files into database rows through the Data-Fix pipeline (match, review, commit), with the preparation running in the background and every commit started by the operator;
*   push the resulting SQL scripts, in one global order, to the production API (Outbox) and follow their outcome on the server;
*   keep the data healthy: read-only checks per season, merge / fix / purge operations with a dry run before any write, the season-start checklist;
*   check that the local copy still mirrors production (DB sync) and replace it with a fresh dump when it doesn't (guided restore);
*   browse and edit the production entities (meetings, swimmers, teams, badges, users, ...) through the API.

## Target Audience

The people who maintain the Goggles data: the operator who imports the meetings every week, and the developers of the framework.

## Relationship with Other Goggles Projects

*   **`goggles_db`:** the Rails engine gem with every model, migration and shared strategy. `goggles_admin2` mounts it and works on its tables directly (local database).
*   **`goggles_api`:** the API backend. `goggles_admin2` signs in through it, edits remote rows with it and pushes its SQL scripts to its import queue.
*   **`goggles_main`:** the public site. It runs the SQL scripts queued on the server and shows the data that `goggles_admin2` imported. It still uses Bootstrap 4, which is why the GoggleCup partials of `goggles_db` keep a small scoped compatibility layer in `goggles_admin2`.
*   **`goggles_db.wiki`:** framework-wide how-tos (setup, credentials, Docker, deployment).

## Further reading

*   [Operator guide](operator_guide.md): the routine end to end (sign in, dashboard, Season board, review, commit, push, confirm), Sources, data health, operations, DB sync, the kill switches and the steps after an update.
*   [Dashboard](dashboard.md): the landing page and how inbox sources and status probes are added.
*   [Season board](season_board.md): the weekly flow for the current season, the automation, Sources and data health.
*   [Data-Fix pipeline](data_fix/README.md), [SQL Outbox](outbox.md), [DB sync](db_sync.md), [guided DB restore](db_restore.md).
*   [Crawler interaction](crawler/crawler_interaction.md), [PDF processing](pdf_processing/pdf_processing.md) and [manifest extraction](pdf_processing/manifest_extraction.md).
*   [Season start](HOWTO_prepare_new_season_at_championship_start.md) and the [merge semantics](merge/MERGE_SEMANTICS.md).
