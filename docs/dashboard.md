# Dashboard

The landing page (`/`, `DashboardController`). It never calls the API: every remote value comes from an ops snapshot written by a job, so it renders the same in an API-offline session, with the crawler down or with the ops DB missing.

| Zone | Frame (`GET`) | Reads |
|---|---|---|
| Counters | `dashboard/kpis` | `KpiRefreshJob.read(api_url)`: snapshot `kpi:<api_url>` (every 15 min, after sign-in, "Refresh counters") |
| Needs you | `dashboard/needs_you` | `Inbox::Builder` over the `Inbox::Registry` sources |
| In progress | `dashboard/in_progress` | `SeasonBoard::ActivityLog#active`, Solid Queue running/queued jobs (`Dashboard::QueueActivity`), next scheduled runs |
| Season progress | `dashboard/season_progress` | `SeasonBoard::Snapshot` state counts |
| System status | `dashboard/system` | `SystemStatus::Registry.results` (the same probes as the top bar pills) |
| Data health | `dashboard/health` | `Health::DashboardCardComponent`: open errors / warnings of the board season and of the closed seasons (`Ops::HealthFinding`), queued runs, last sweep |
| Activity | `dashboard/activity` | the last 20 `Ops::Event` rows; `/activity` lists them all |

The System status zone also holds the switches: the three automation kill switches (`automation/_switches`, `AutomationController#switch`) and the **Operations** switch (`operations/_switch`, `OperationsController#switch`, ops setting `operations.enabled`). They are `Switch::ToggleFormComponent`s (a Bootstrap `.form-switch` in a POST form; `toggle_submit_controller.js` submits on change, disables the switch while the request runs and puts it back when it fails); the answer is a turbo stream replacing the switch panels and the toasts, so the zone is not reloaded.

Each zone is a Turbo frame loaded on its own. `live_frames_controller.js` reloads them on any `AppNotificationsChannel` broadcast, or every 20 s while one of them carries `data-live-busy="true"` (something queued or running).

A counter that was never fetched is never shown as 0: it says "unreachable", "sign in to refresh", "unavailable" or "no data yet". Switching the API URL in Settings shows "no data yet for <url>" until the counters of that server are fetched.

## Needs you: inbox sources

Each source turns local facts into `Inbox::Item`s; `Inbox::Builder` merges them:

- one item per `key` (the most urgent one wins), then one item per source file (`subject[:file_path]`, whatever its LT2 / LT4 / phase-file spelling; a Season board item beats any other);
- sorted by band (`blocked`, `failed`, `push`, `review`, `acquire`, `notice`), then oldest `since` first;
- 25 items shown, the rest counted per source ("N more", linking to the source's `more_path`);
- a source that raises becomes one `failed`-band item ("Inbox source X failed: ..."), never an error page.

v1 sources (`app/services/inbox/sources/`, registered in `config/initializers/inbox.rb`, in this order): `blockers`, `failed_jobs`, `pending_sql`, `board_rows`, `unmatched_sources`, `data_fix_sessions`, `fin_change` (0.10.103: only while the FIN alert is shown), `fin_notice` (0.10.103: one notice per FIN change acknowledged with nothing to crawl, with **Dismiss**: ops setting `fin_watch.notice_dismissed_ids`), `drift` (since 08 `Drift::InboxSource`: the last DB sync verdict, red = blocked band, amber = notice; see `docs/db_sync.md`); phase 06 appends `health` (`Health::InboxSource`: one item per season and group with open errors, one for all the warnings, failed runs, overdue or stuck runs; never one item per finding).

### Adding a source (phases 06, 10)

```ruby
# app/services/inbox/sources/stale_badges.rb (example)
module Inbox
  module Sources
    class StaleBadges < Inbox::Source       # key: :stale_badges (from the class name)
      def self.enabled?(context) = context.ops_available?
      def self.more_path = Rails.application.routes.url_helpers.api_badges_path

      # READ-ONLY and fast (about 200 ms or less): no remote call, no file or DB write.
      def items(context)
        Array(Ops::Snapshot.read('health:stale_badges')&.payload).map do |row|
          item(key: "stale_badge:#{row['id']}", kind: :stale_badge, band: :notice,
               title: t(:title, name: row['name']),            # => 'inbox.stale_badges.title' (en + it)
               detail: row['team'], subject: { badge_id: row['id'] },
               action: action(t(:open), url_helpers.api_badges_path(badges_grid: { id: row['id'] })),
               since: Time.zone.parse(row['found_at']))
        end
      end
    end
  end
end

# config/initializers/inbox.rb, inside the to_prepare block:
Inbox::Registry.register(Inbox::Sources::StaleBadges)
```

- `Inbox::Item`: `key` (stable String), `source`, `kind`, `band`, `title`, `detail`, `subject` (Hash), `action`, `since`, `count` (grouped items), optional `secondary_action`. It raises without an `Inbox::Action`: exactly one primary action per item.
- `Inbox::Action`: `label`, `path` (an app path, or a full URL opened in a new tab), `http_method` (`:get` link, `:post` or `:delete` one-button form), `params` (form fields), `confirm`. Every action is a link or a form to an existing controller action, started by a click: never a commit, push, apply or restore by itself. Failed commit, push, apply and restore jobs get "Discard" only (`Inbox::Sources::FailedJobs::PROTECTED_JOBS`).
- `Inbox::Context`: `season`, `board_snapshot` (lazy, fetched once), `now`, `api_offline?`, `ops_available?`, `user`, `api_url`, `data_dir`.
- Replacing a source keeps its slot: `Inbox::Registry.replace(:pending_sql, Outbox::InboxSource)` (07); 08 put `Drift::InboxSource` directly in the `:drift` slot (the drift v0 source is gone). Phase 10 narrows `BoardRows` so that the ready-to-commit / needs-review / prepare-failed rows are emitted only by its own sources.
- Add the `inbox.sources.<key>` label (the "N more" line) and the item texts in `config/locales/inbox.{en,it}.yml`.

## System status: probes (phases 07, 08, 10)

Each row of the System zone (and each top bar pill) is a `SystemStatus::Probe`, listed in `SystemStatus::Registry::PROBES` (class names, display order). v1: `APIProbe`, `CrawlerProbe`, `QueueProbe`, `CableProbe`, `FINWatchProbe`, `OpsDbProbe`, `DbSyncProbe` (08, replaced `DriftV0Probe`: reads the last `Ops::DbFingerprint`, see `docs/db_sync.md`).

```ruby
module SystemStatus
  class OutboxProbe < Probe                  # key: :outbox, label: 'shell.status.outbox.label'
    protected

    # Never raises (#call turns any exception into :unknown) and never calls the network.
    def evaluate
      count = Ops::SqlScript.pending.count
      return result(:ok, detail: detail_text(:empty), checked_at: now) if count.zero?

      result(:warn, detail: detail_text(:pending, count:), checked_at: now,
                    action: action_for(:outbox, url_helpers.outbox_path))   # 'shell.status.actions.outbox'
    end
  end
end
```

- A result has `label`, `level` (`:ok`, `:warn`, `:error`, `:unknown`), `detail`, `checked_at` ("as of") and an optional `action` (`{ label:, path:, http_method: }`). A `:post` action is a button in the System zone; the top bar pill never runs it and links to the dashboard System zone instead.
- The top bar compacts the results (`Shell::StatusPillsComponent`): all `:ok` → a single "All OK" pill (`#status-pill-all`, tooltip listing each probe and its detail, link to `/#dashboard-system`); otherwise one `Shell::StatusPillComponent` per probe not `:ok` (`#status-pill-<key>`, `:unknown` included, registry order) followed by an "N OK" pill (same id) for the others.
- `mode`: `:inline` (cheap local reads, the default) or `:snapshot` (anything needing the network: implement `#refresh!`, run only by `SystemStatus::RefreshJob`, and read only `#snapshot` in `#evaluate`).
- Texts: `shell.status.<key>.*` in `config/locales/shell.{en,it}.yml`. Keep the labels short: the top bar shows them only from 1600 px.

## Background jobs

The dashboard counters, the DB sync check, the FIN watcher and the Season board crawls are Solid Queue jobs. The supervisor runs inside Puma (`plugin :solid_queue` in `config/puma.rb`); with `SOLID_QUEUE_IN_PUMA=false` run `bin/jobs` in another terminal. The queue database is local SQLite: `bin/rails solid:prepare` creates it. The "Jobs" status row is red while no supervisor sends heartbeats, amber while a queue of `config/queue.yml` has no worker.

## Local ops DB

The counters, the board summary, the event log, the remote-write log and every status snapshot live in the local ops DB (`db/ops/<env>.sqlite3`). Paste the `ops:` blocks of `config/database.example.yml` into `config/database.yml`, then run `bin/rails ops:prepare` (also run by `bin/rails solid:prepare`). Without it the dashboard still renders, with a setup notice.
