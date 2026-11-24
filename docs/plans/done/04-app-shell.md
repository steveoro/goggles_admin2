# Phase 04 — App shell + native sweep of stable pages

## Goal

One application layout: sidebar, top bar (API target, status pills, theme, user menu), page header with breadcrumbs, toasts and the Turbo progress bar, all fed by one Ruby navigation registry. Convert the page groups that no later phase rewrites to native Bootstrap 5. Every other page keeps working inside the new shell through the phase 03 compatibility layer.

## Operator-visible outcome

- A persistent sidebar reaches every existing page, and the current page is highlighted.
- The top bar always shows which API the app talks to: URL, the operator's label, last known reachability, and a port-based guess marked "unverified". It also shows crawler, job-queue and FIN-watcher pills that never slow the page down.
- Pages have a header with breadcrumbs and a row count. The 10% side gutters are gone and pages use the full width.
- The light/dark toggle moves to the top bar. Sign-in, Settings, Stats, all entity grids, the Season board, Best results and GogglesCup are native Bootstrap 5 and checked in both themes.
- In an API-offline session the shell still renders, and unavailable areas are visibly disabled.

## Depends on

- **03**: Bootstrap 5.3, the compat layer, toasts and `#sticky-alerts`, `base/_tokens.scss`, the `theme` cookie, `spec/bs4_leftovers_spec.rb`.
- Softer links (not hard dependencies, both reached through 03): **01** provides `Ops.safely`, `Ops::Setting.fetch` / `.store!` and `Ops::Snapshot.write!` / `.read`; **02**: `home#latest_updates`, `push#prepare`, the `best50m_results/index` route and the legacy routes are already gone, so the registry does not list them.

## Invariants that apply here

- Dashboard and status surfaces make no synchronous remote call and render API-offline. The shell, the top bar and the status frame only read the session, the local DB, local files and ops snapshots.
- No admin2-only tables in MySQL: labels and snapshots live in the ops DB (`Ops::Setting`, `Ops::Snapshot`), never in `Rails.cache` (Solid Cache exists only in development).
- Every phase leaves the weekly routine working (the routine gate).
- No job commits, pushes, applies or restores without an operator click: the only job added here, `SystemStatus::RefreshJob`, is a read-only probe refresh on `default`. File conventions (`NNNN-<base>-lt4.sql`, `results.new/sent/done/<season>`) are untouched.
- Repo conventions: `# frozen_string_literal: true`, en and it keys, CHANGELOG + PATCH bump in `lib/version.rb` per user-visible step, `bundle exec rubocop -a` and haml-lint clean. Never run a bare `db:prepare`/`db:migrate`.
- "Staging" means the import staging tables. The port guess may say only "production" or "unknown"; it never says "staging".

## Scope

### Layout (`app/views/layouts/application.html.haml`, replaces the 03 version)

```haml
!!!
%html{ lang: I18n.locale, data: { bs_theme: current_theme } }
  %head
    -# meta, csrf_meta_tags, csp_meta_tag, vendored CSS + importmap tags as in 03
    %title= [content_for(:title), 'Goggles Admin2'].compact_blank.join(' · ')
  %body{ data: { controller: 'tooltips shell' } }
    - if user_signed_in?
      .app-shell{ class: sidebar_collapsed? ? 'app-shell--collapsed' : nil }
        %aside.app-sidebar.offcanvas-lg.offcanvas-start#app-sidebar{ tabindex: '-1' }
          = render(Shell::SidebarComponent.new(current: current_nav_item, offline: api_offline_session?))
        .app-main
          %header.app-topbar.sticky-top
            = render(Shell::TopBarComponent.new(api_target: Shell::ApiTarget.current,
                                                offline: api_offline_session?, user: current_user))
          %section#notify
            #sticky-alerts
              = render('goggles/api_offline_banner') if api_offline_session? && controller_name != 'settings'
              = render(FedernuotoWatchAlertComponent.from_store)
          %main.app-content#content= yield
    - else
      %main.app-auth#content= yield
    .toast-container.position-fixed.top-0.end-0.p-3#flash-messages-container
      = render('goggles/flash_messages')
    -# kept until phase 15 (pdf/scan.turbo_stream.erb:2-6 replaces it):
    .fixed-top.text-center.mt-2.d-none#loading-indicator
      .spinner-border.text-primary{ role: 'status', 'aria-hidden' => 'true' }
```

- `goggles/_main_navbar.html.haml` is deleted. Its dropdown links (Settings, API stats, Import queues, Issues, Users) and the Season board link move to the sidebar. The user name and avatar move to the user menu.
- `current_nav_item` and `sidebar_collapsed?` (cookie `sidebar`) are new helpers in `app/helpers/shell_helper.rb`.
- The `#loading-indicator` caller at `kaminari/_page.html.haml:15` is removed in the grid sweep. The PDF callers (`pdf/extract_txt.html.haml:8`, `pdf/scan.turbo_stream.erb:2-6`) stay until 15.
- Turbo progress: style `.turbo-progress-bar` with `--bs-primary` and set the delay to 150 ms in `application.js`. Use `Turbo.config.drive.progressBarDelay` or `Turbo.setProgressBarDelay`, depending on the Turbo version bundled by turbo-rails 2.0.23 (not verified). Dim `turbo-frame[busy]`.

### Neutralising the per-view wrappers (no view edits)

`app/assets/stylesheets/shell/_legacy_wrappers.scss`:

```scss
.app-content .wrapper-body { display: block; }
.app-content .spacer-left, .app-content .spacer-right { display: none; }
.app-content #footer.fixed-bottom { display: none; }
```

This covers 41 views plus the old layout carrying `.wrapper-body` (47 before 02 deleted the 5 legacy views) and 21 `fixed-bottom` footers. Most of the footers are a `&nbsp;` placeholder, as in `api_teams/index.html.haml:23-24`. The one with content, `Footer::MainComponent` in `home/index.html.haml:11-12` (locale switch `#href-locale-switch`, copyright, `Version::FULL`), is superseded by the user menu. Footer rule: each view drops its `Footer::MainComponent` render in the phase that sweeps or rewrites that view; the locale switch and version move to the user menu here; the component itself is deleted in phase 15 once grep finds no caller. Each view drops its wrappers in the phase that rewrites it; the swept groups below drop them now. `full_bleed_layout.scss` stays until 15.

### Navigation registry: `app/services/shell/navigation.rb`

```ruby
# frozen_string_literal: true

module Shell
  # Single source for the sidebar, breadcrumbs and (phase 15) the command palette.
  # Each later phase adds or replaces only its own entries.
  class Navigation
    GROUPS = %i[dashboard import data_quality entities reports support system].freeze
    Item = Data.define(:key, :group, :icon, :label_key, :path, :match, :parent, :offline_ok, :sidebar, :keywords)

    def self.item(key, group, icon, label_key, path, match:, parent: nil, offline_ok: false, sidebar: true, keywords: [])
      Item.new(key:, group:, icon:, label_key:, path:, match:, parent:, offline_ok:, sidebar:, keywords:)
    end

    ITEMS = [
      item(:dashboard, :dashboard, 'fa-gauge', 'dashboard.title', -> { root_path }, match: %w[home], offline_ok: true),
      # Import
      item(:season_board, :import, 'fa-table-list', 'season_board.nav', -> { season_board_path }, match: %w[season_board]),
      item(:crawler, :import, 'fa-spider', 'data_import.calendar.crawler_status_page_title', -> { pull_index_path }, match: %w[pull#index]),
      item(:calendar_files, :import, 'fa-calendar', 'data_import.calendar.calendar_files_page_title', -> { pull_calendar_files_path },
           match: %w[pull#calendar_files pull#calendar_meetings]),
      item(:pdfs, :import, 'fa-file-pdf', 'data_import.calendar.pdfs_page_title',
           -> { pull_result_files_path(filter: '*.pdf', parent_folder: 'pdfs') }, match: %w[pull#result_files?parent_folder=pdfs pdf]),
      item(:result_files, :import, 'fa-file-pen', 'data_import.calendar.result_files_page_title', -> { pull_result_files_path },
           match: %w[pull#result_files]),
      item(:data_fix, :import, 'fa-wand-magic', 'shell.nav.data_fix', -> { pull_result_files_path },
           match: %w[data_fix data_fix/sessions data_fix/teams data_fix/swimmers data_fix/events data_fix/results data_fix/commits],
           parent: :result_files, sidebar: false),
      item(:push, :import, 'fa-upload', 'shell.nav.push', -> { push_index_path }, match: %w[push]), # replaced by :outbox in 07
      # Entities
      item(:meetings, :entities, 'fa-flag-checkered', 'dashboard.meetings.title', -> { api_meetings_path }, match: %w[api_meetings]),
      item(:calendars, :entities, 'fa-calendar-days', 'dashboard.calendars.title', -> { api_calendars_path }, match: %w[api_calendars]),
      item(:reservations, :entities, 'fa-clipboard-list', 'dashboard.meeting_reservations.title', -> { api_meeting_reservations_path },
           match: %w[api_meeting_reservations]),
      item(:swimmers, :entities, 'fa-person-swimming', 'dashboard.swimmers.title', -> { api_swimmers_path }, match: %w[api_swimmers]),
      item(:teams, :entities, 'fa-people-group', 'dashboard.teams.title', -> { api_teams_path }, match: %w[api_teams]),
      item(:badges, :entities, 'fa-id-badge', 'dashboard.badges.title', -> { api_badges_path }, match: %w[api_badges]),
      item(:team_affiliations, :entities, 'fa-link', 'dashboard.team_affiliations.title', -> { api_team_affiliations_path },
           match: %w[api_team_affiliations]),
      item(:team_managers, :entities, 'fa-user-tie', 'dashboard.team_managers.title', -> { api_team_managers_path }, match: %w[api_team_managers]),
      item(:seasons, :entities, 'fa-calendar-check', 'dashboard.seasons.title', -> { api_seasons_path }, match: %w[api_seasons]),
      item(:categories, :entities, 'fa-layer-group', 'dashboard.categories.title', -> { api_categories_path }, match: %w[api_categories]),
      item(:standard_timings, :entities, 'fa-stopwatch', 'dashboard.standard_timings.title', -> { api_standard_timings_path },
           match: %w[api_standard_timings]),
      item(:swimming_pools, :entities, 'fa-water', 'dashboard.swimming_pools.title', -> { api_swimming_pools_path }, match: %w[api_swimming_pools]),
      # Reports: the six best_results pages (labels best_results.<action>.button_label) + GogglesCup
      *%i[best_50m best_50_and_100 best_50_and_100_5y best_in_3y best_in_5y all_time_best].map do |act|
        item(:"best_#{act}", :reports, 'fa-ranking-star', "best_results.#{act}.button_label",
             -> { public_send(:"#{act}_results_path") }, match: ["best_results##{act}"])
      end,
      item(:goggles_cup, :reports, 'fa-trophy', 'goggles_cup.button_label', -> { goggles_cup_preview_path }, match: %w[goggles_cup]),
      # Support
      item(:users, :support, 'fa-users', 'dashboard.users.title', -> { api_users_path }, match: %w[api_users]),
      item(:issues, :support, 'fa-bug', 'dashboard.issues.title', -> { api_issues_path }, match: %w[api_issues]),
      item(:import_queues, :support, 'fa-list-check', 'dashboard.import_queues.title', -> { api_import_queues_path }, match: %w[api_import_queues]),
      item(:api_stats, :support, 'fa-chart-line', 'dashboard.stats.title', -> { stats_path }, match: %w[stats]),
      item(:trainings, :support, 'fa-camera', 'api_trainings.title', -> { api_trainings_path }, match: %w[api_trainings]),
      item(:user_workshops, :support, 'fa-chalkboard-user', 'dashboard.user_workshops.title', -> { api_user_workshops_path },
           match: %w[api_user_workshops]),
      # System
      item(:settings, :system, 'fa-gear', 'dashboard.settings.title', -> { settings_path }, match: %w[settings], offline_ok: true)
    ].freeze

    # API: groups(offline:) (non-empty groups, sidebar: true items only), item_for(controller_path, action_name, params),
    #      breadcrumbs_for(controller_path, action_name, params) => [[label, path], ...], palette_entries (stub for 15)
  end
end
```

- Paths are lambdas evaluated against `Rails.application.routes.url_helpers`. Every helper above exists in `config/routes.rb`: lines 9, 17-23, 39, 44-46, 118, 123-171 and 178-182; `pull_*_path` come from the `get 'pull/...'` lines 44-46.
- Children reached from a parent page: `api_meetings_no_mirs` (`api_meetings#no_mirs`) and `api_meeting_reservations_expand`. They match their parent controller, so the parent is the active item and the action name is the last crumb.
- `match` entries are `controller_path` or `controller_path#action`, with an optional `?param=value`. The most specific match wins. The `?parent_folder=pdfs` form separates the PDFs tab from Result files, which share `pull#result_files` (see `pull/_crawler_tabs.html.haml:13,18`).
- The `data_quality` group has no items yet and is hidden. Phase 05 adds the `remote_writes` (System group) and `data_fix_sessions` entries and the dashboard content; 06, 07, 08, 11, 13 and 15 add or replace their entries (`health`, `outbox` replacing `push`, `db_sync`, `operations` (extended in 13), `sources`). Each of those phase files says so.
- Dropped from navigation: the six disabled placeholders (`home/_manage_entities.html.haml:41-53`). The `DashboardController`-style KPI cards stay on home until 05.
- New label keys: `shell.nav.data_fix`, `shell.nav.push`, plus group titles `shell.groups.*` in `config/locales/shell.{en,it}.yml`. `dashboard.team_affiliations.title` relies on the 01 fix: today the key is `dashboard.team_affiliation` (singular).
- New-style icon names (`fa-gauge`, `fa-table-list`, ...) use FA 6 classes with the `fa-solid` prefix. Check each name against the vendored 6.7.x CSS; not verified one by one.

### Components (`app/components/shell/`)

| Component | Params | Slots / notes |
|---|---|---|
| `Shell::SidebarComponent` | `current:` (Item or nil), `offline:` | none; renders `Shell::Navigation.groups`; active item `.nav-link.active` + `aria-current="page"`; when `offline` and not `offline_ok`: `.nav-link.disabled`, `aria-disabled="true"`, tooltip `shell.nav.offline_disabled` |
| `Shell::TopBarComponent` | `api_target:`, `offline:`, `user:` | `renders_one :search` (empty; command-palette trigger in 15); contains the sidebar toggle (`data-bs-toggle="offcanvas"` below lg, `shell#toggleSidebar` cookie above), `Shell::ApiTargetBadgeComponent`, the API pill, `turbo-frame#shell-status` (`src: shell_status_path`, `loading: 'lazy'`), theme toggle `#theme-toggle`, `Shell::UserMenuComponent` |
| `Shell::ApiTargetBadgeComponent` | `api_target:` | URL, operator label, guess (`production` = red accent, `unknown` = secondary) with the suffix "unverified", reachability and age from the ping snapshot |
| `Shell::StatusPillComponent` | `result:` (`SystemStatus::Result`) | one pill: icon, label, tooltip with detail and "as of" time |
| `Shell::UserMenuComponent` | `user:` | dropdown: name/avatar, locale switch (keeps `#href-locale-switch`; `other_locale_code`/`unicode_locale_flag` move from `Footer::MainComponent` private methods into `ShellHelper`), `Version::FULL`, log out (`destroy_user_session_path`, `turbo_method: :delete`) |
| `Shell::PageHeaderComponent` | `title:`, `count: nil`, `subtitle: nil`, `crumbs: nil` | `renders_one :actions`; crumbs default to `Shell::Navigation.breadcrumbs_for(...)`; calls `content_for(:title, title)` unless already provided (8 views already `provide(:title)`, e.g. `best_results/best_50m.html.haml:5`, `goggles_cup/index.html.haml:9`) |
| `Shell::BreadcrumbsComponent` | `crumbs:` | `nav[aria-label=breadcrumb] ol.breadcrumb` |

- `DashboardTitleComponent` (22 call sites in 22 views: 20 `api_*` views plus `settings` and `stats`) first becomes a thin wrapper rendering `Shell::PageHeaderComponent.new(title:, count: row_count)`. Its call sites are replaced during the sweep, then the component and `spec/components/dashboard_title_component_spec.rb` are deleted.
- `Shell::StatusController` (`app/controllers/shell/status_controller.rb`, route `get 'shell/status', to: 'shell/status#show', as: 'shell_status'`) renders only the frame. `api_offline_allowed?` is true; it makes no `APIProxy` call.

### Status probes: `app/services/system_status/`

- `SystemStatus::Probe` is the base class. Each probe has `key`, `label_key`, `mode` (`:inline` for cheap local reads, `:snapshot` for anything touching the network) and `call` → `SystemStatus::Result(key:, label:, level: :ok|:warn|:error|:unknown, detail:, checked_at:, action: nil)`. `call` never raises: every exception becomes `:unknown`.
- `SystemStatus::Registry` lists the probes in order. Phase 05 extends it (cable, ops DB, watcher age, `SOLID_QUEUE_IN_PUMA=false`).

| Probe | Mode | Source |
|---|---|---|
| `api` | snapshot | `Ops::Snapshot` `api.status:<base_url>` (the one key for ping/reachability; 08 extends its payload with `environment` and `capabilities`); written by `SystemStatus::RefreshJob` (`APIProxy.ping`, `api_proxy.rb:130`), by `SettingsController` where it already pings (`settings_controller.rb:191,199`), and by the sign-in outcome in `users/sessions_controller.rb:91-100` |
| `crawler` | snapshot | `CrawlerClient.new(timeout: 2, open_timeout: 1).status` (`crawler_client.rb:82,89`) in the job |
| `queue` | inline | `SolidQueue::Process.where(last_heartbeat_at: 5.minutes.ago..).exists?` (column in `db/queue_schema.rb:96`). Inline because a dead queue would never refresh its own snapshot |
| `fin_watch` | inline | `FedernuotoWatch::StateStore.new.pending_change` (`state_store.rb:60`) → `:warn` when present |

- `SystemStatus::RefreshJob` (`queue_as :default`, a worker that already exists) runs the snapshot probes and writes `Ops::Snapshot` rows `system_status.<key>` through `Ops.safely`. It is recurring in `config/recurring.yml` (`system_status_refresh`, `queue: default`, `schedule: every 5 minutes`). `Shell::StatusController#show` also enqueues it when the newest snapshot is older than 2 minutes. It is not a commit, push or apply job, so the click-only invariant does not apply.
- `Shell::ApiTarget` (`app/services/shell/api_target.rb`) is a value object: `url` (`APIProxy.configured_base_url`, `api_proxy.rb:135`), `label` (`Ops::Setting` key `api_target.labels`, a JSON hash URL → label), `guess` (`:production` when the URL ends in `:447`, else `:unknown`; always shown with "unverified" until 08 replaces it with the API-reported environment), `reachability` (`:reachable`/`:unreachable`/`:unknown` + `taken_at` from the ping snapshot; forced to `:unreachable` in an API-offline session). A missing ops DB gives label nil and reachability `:unknown`.
- Settings page: a small form `#api-target-label-form` to set the label for the current URL (new route `post 'settings/api_target_label'`, also allowed API-offline). It replaces the copies of the guess in `home/_top_header.html.haml:5-10` (home is converted in 05; until then home keeps its header) and `home_controller.rb` (`latest_updates` port assumptions, removed in 02).

### Theme tokens (extend `app/assets/stylesheets/base/_tokens.scss`)

Under `:root, [data-bs-theme=light]` and `[data-bs-theme=dark]`:
- `--ga-sidebar-width: 15rem`, `--ga-sidebar-collapsed-width: 4rem`, `--ga-topbar-height: 3.5rem`.
- `--ga-tint-blue|green|yellow|red|grey|cyan|brown`: light values from the effective rules today (`devise_customizations.scss`: `#d8ecff`, `#e8ffee`, `#feffd6`, `#ffa1a1`, `#e6e6e6`, `#dbeeff`, `#ffdfcc`), dark values chosen for contrast.
- `--ga-env-production: var(--bs-danger)`, `--ga-env-unknown: var(--bs-secondary)`.
- `--ga-grid-order-bg` / `--ga-grid-order-fg`, replacing `#cebca630` / `#eab000`. Retarget `datagrid_customizations.scss:17-29` from the dead Datagrid 1.x selectors (`th.ordered.asc`) to `.datagrid-order-active-asc/-desc`, which `datagrid/_head.html.haml:5-6` emits.
- `--ga-font-mono: 'Share Tech Mono', var(--bs-font-monospace)`. Keep only its woff2 and Saira Stencil One's (used by `.cancelled`, `custom_styles.scss:13`); drop Roboto and the eot/svg/ttf/woff files under `app/assets/stylesheets/fonts/`.
- In swept views: `bg-light` → `bg-body-tertiary`, `text-muted` → `text-body-secondary`. Keep the Bootstrap default palette. Delete `dashboard.scss` (global `.card { overflow:hidden }`; check the home cards) and `home.scss` (`.alert { z-index }`). Regroup stylesheets into `base/`, `shell/`, `components/`, `pages/`, `compat/`.

### Permanent engine compat scope

`app/views/goggles_cup/_ranking.html.haml:7` and `goggles_cup/base_timings.html.haml:10` render the goggles_db partials `goggles_db/goggle_cups/_ranking` and `_base_timings`. In the installed engine these carry `text-right`, `pr-4` (×4), `ml-2`/`ml-3`, `mr-2`/`mr-3`, `badge-primary`, `toggle: 'collapse'` and FA4 `-o` icons. goggles_main stays on Bootstrap 4, so wrap both renders in `%div{ data: { bs4_compat: true } }`. Add `[data-bs4-compat] { @include bs4-spacing; @include bs4-text; @include bs4-badges; }` to `compat/_bs4.scss`. The `data-toggle` there is handled by the global JS shim until 15, which then restricts it to `[data-bs4-compat]` subtrees.

### Sweep groups (native Bootstrap 5)

**Per-group checklist:**
1. Remove `.wrapper-body`/`.spacer-left`/`.main-content`/`.spacer-right`, `.row-fluid`, `#footer.fixed-bottom` and stray `%meta` lines (19 views start with one, e.g. `api_teams/index.html.haml:1`). Add `Shell::PageHeaderComponent`.
2. Rename classes: `ml-`/`mr-` → `ms-`/`me-`, `pl-`/`pr-` → `ps-`/`pe-`, `text-right/left` → `text-end/start`, `badge-x` → `text-bg-x`, `form-group` → `mb-3`, `form-row` → `row g-2`, selects → `form-select`, `bg-light` → `bg-body-tertiary`, `text-muted` → `text-body-secondary`.
3. Rename `data: { toggle:, target:, parent:, placement:, title:, dismiss: }` → `bs_*`; `'data-toggle' =>` → `'data-bs-toggle' =>`.
4. Check the page in dark mode.
5. Move any hard-coded string you touch to i18n (en + it).
6. Update specs and JS selectors in the same commit, and add the group's folders to `SWEPT` in `spec/bs4_leftovers_spec.rb`.
7. Run rubocop, haml-lint, the group's specs and the system smoke suite. One CHANGELOG entry + PATCH per group.

| Group | Folders | DOM ids, classes and text that must survive |
|---|---|---|
| G1 devise, settings, stats | `app/views/devise/**`, `settings`, `stats` | `#login-box`, `#login-btn`, `#email-help`; `#api-offline-help` (`settings_controller_spec.rb:231`), text "API unreachable" (`:187,238`), **no** literal `REMOTE ` in API-offline mode (`:234`) and no `api-offline-banner` on settings (`:232,266`): the top bar must not print either; `#curr-config-box`, `#frm-curr-config`, `#btn-save-config`, `#settings-source`, `#data-grid`; `summary-panels` (`stats_controller_spec.rb:56`), `#api-chart`, `#clear-stats-panel`, `#btn-clear` |
| G2 grid chrome | `app/components/grid/**`, `app/components/issue/**`, `switch/**`, `legacy_auto_complete_component`, `page_links_for_array_component`, `combo_box/**`, `app/views/datagrid/**`, `kaminari/**`, all 17 `app/views/api_*` folders | `#data-grid`, `#filter-panel`, `#filter-show-btn`, `#sel-toggle-btn`, `#new-btn`, `#delete-btn`, `#csv-btn` (`toolbar_component_spec.rb:170`), `.row-edit-btn a` with `href="#grid-edit-modal"`, `data-controller="grid-edit"`, `data-grid-edit-base-modal-id-value`, `data-action="click->grid-edit#handleEdit"`; `#frm-delete-selection`, `input#ids`, `#btn-delete-selection`; `frm-delete-row-<id>`, `frm-clone-row-<id>`, `btn-expand-row-<id>`; `#<base>-modal.modal.fade` (not `.show`), `#frm-<base>`, `#<base>-modal-title`, `#<base>-modal-body`, `#btn-<base>-submit-save`; `#sql-create-modal.modal.fade`, `form#frm-sql-create`, `#sql-create-modal-title`, `#btn-sql-create-submit-generate`; `.legacy-auto-complete` with its `data-legacy-autocomplete-*` values; `.autocomplete-lookup` absent |
| G3 Season board | `app/views/season_board`, `app/components/season_board` | `turbo-frame#season-board-rows #season-board-table`, `[data-controller="season-board"]`, `#season-board-sql-pending`, `#season-board-row-N`, `#season-board-empty`, `#orphans-collapse`, `tr[data-orphan-id]`, `[data-state-chip]`, `[data-flag]`, `[data-season-board-busy="true"]`, `#btn-season-board-check`, `span.badge`, `small.text-muted` (`row_component_spec.rb:132`: keep that class on the note, or update the spec), the `d-flex flex-nowrap` link form, texts asserted in `season_board_controller_spec.rb:102-183` |
| G4 Reports | `app/views/best_results`, `app/views/goggles_cup`, `goggles_cup_controller.js` | `#result-list`; the literal `id='badge-readonly'` (`goggles_cup_preview_spec.rb:260,279`: HAML single-quote attribute output must not change); the literal class string `btn btn-outline-secondary btn-lg w-100 d-none` in this exact order (`:622-635`); `#ranking-panel`, `#select-cup`, `#btn-show-precomputed`, `#goggles-cup-overlay`, `#goggles-cup-ranking-container`; engine partials wrapped in `[data-bs4-compat]` |

Spec updates in this phase:
- `csv_export_button_component_spec.rb:27-30` → `data-bs-toggle`/`data-bs-title`.
- `filter_show_button_component_spec.rb:10-11` → `data-bs-target`/`data-bs-toggle`.
- `selection_toggle_button_component_spec.rb:13-14` → `data-bs-*`.
- `row_component_spec.rb:69,197` → `text-bg-warning`, with `SeasonBoard::RowComponent::STATE_CSS` (`row_component.rb:16-21`) moved to `text-bg-*` and `border` kept for the light chips.
- `sql_create_modal_component_spec.rb:90` was already updated in 03.

In G2, `grid_edit_controller.js` opens the modal explicitly (`Modal.getOrCreateInstance(el).show()` after filling the form). `data-bs-toggle="modal"` is dropped from `row_edit_button_component.html.haml:3`, `create_new_button_component.html.haml:3` and `api_team_managers/index.html.haml:17`; the `href="#grid-edit-modal"` pins stay.

**Left on the compat layer on purpose:** `home` (05), `push` (07), `app/views/data_fix` + `app/components/data_fix` (12), `pull`, `pdf`, `file_list` (15). They render inside the shell with neutralised wrappers.

### API-offline behaviour

- The shell renders fully. Sidebar items without `offline_ok` (all except Dashboard and Settings) are disabled links with a tooltip, matching the `api_offline_allowed?` overrides in `home_controller.rb:49` and `settings_controller.rb:175`. Clicking one would redirect to Settings anyway (`api_session.rb:61-66`).
- The API pill shows "offline" from `api_offline_session?` alone. `Shell::ApiTarget` reports `:unreachable` with the session's `api_offline_info['at']`.
- `turbo-frame#shell-status`, the user menu, the theme toggle and the API label form all work (`Shell::StatusController` allows offline sessions).
- `#api-offline-banner` stays in `#sticky-alerts` except on Settings.
- No `APIProxy` method is called while rendering the shell (spec-asserted).

## Data model

No new tables. Uses `Ops::Setting` (`api_target.labels`) and `Ops::Snapshot` (`api.status:<url>`, `system_status.<key>`) from phase 01, through `Ops.safely`. With the ops DB missing, the shell renders with "unknown" values.

## Ordered steps

1. **Registry and services (not user-visible).** `Shell::Navigation`, `Shell::ApiTarget`, `SystemStatus::{Probe,Result,Registry}` and probes, `shell.{en,it}.yml`, unit specs.
2. **Shell layout (user-visible).** Layout, the Sidebar/TopBar/ApiTargetBadge/UserMenu/PageHeader/Breadcrumbs components, `shell_controller.js` (sidebar toggle cookie), the theme toggle moved to the top bar, `_legacy_wrappers.scss`, tokens, Turbo progress, navbar partial deleted, `DashboardTitleComponent` as a wrapper. The status frame shows the API pill only. CHANGELOG + PATCH.
3. **Status pills (user-visible).** `Shell::StatusController`, route, `SystemStatus::RefreshJob`, recurring entry, snapshot writers in Settings and sign-in, the Settings label form. CHANGELOG + PATCH.
4. **G1** devise, settings, stats. CHANGELOG + PATCH.
5. **G2** grid chrome and `api_*` views; call sites switched to PageHeader; `DashboardTitleComponent` deleted; `kaminari/_page` loading-indicator caller removed. CHANGELOG + PATCH.
6. **G3** Season board. CHANGELOG + PATCH.
7. **G4** Best results and GogglesCup, plus the engine compat scope. CHANGELOG + PATCH.
8. **Stylesheet clean-up (not user-visible):** regroup folders, delete `dashboard.scss`/`home.scss`/unused fonts, add `CLAUDE.md` notes on the shell and the registry.

## Specs and manual verification

- `spec/services/shell/navigation_spec.rb`:
  - every item's path resolves with `Rails.application.routes.recognize_path` to a GET route whose controller matches one of its `match` entries;
  - every GET route of an app controller that renders HTML maps to an item via `item_for`, with an explicit allow-list for JSON/action endpoints (`lookup`, `pull/extraction_status`, `data_fix/verify_*`, `data_fix/coded_name`, `data_fix/teams_for_swimmer`, `api_issues/check`, `goggles_cup/{smart_selection,compute,base_timings}`);
  - every `label_key` exists in en and it;
  - `breadcrumbs_for('data_fix/teams', 'review_teams', {})` → Import › Result files › Data-Fix.
- `spec/services/shell/api_target_spec.rb`: guess `:production` only for `:447`, else `:unknown`, never "staging"; label round-trip; missing ops DB → `:unknown`.
- `spec/services/system_status/*_spec.rb`: each probe never raises; snapshot probes read only `Ops::Snapshot`; `RefreshJob` writes snapshots and calls `APIProxy.ping` once.
- `spec/components/shell/*_spec.rb`: sidebar active state and offline disabling; the top bar never prints `REMOTE ` or `api-offline-banner`; `expect(APIProxy).not_to have_received(:call)` / `(:ping)` while rendering; page-header crumbs and title.
- `spec/requests/shell/status_controller_spec.rb`: 200 in normal and API-offline sessions, no `APIProxy` call, enqueues `RefreshJob` when stale.
- Request specs: `season_board_controller_spec.rb`, `settings_controller_spec.rb`, `stats_controller_spec.rb`, `goggles_cup_preview_spec.rb`, `home_controller_spec.rb` (`Data-Fix v2 sessions: N`, `Clean slate`) and `api_offline_session_spec.rb` stay green unchanged. Add an assertion that `.app-sidebar a.active` points at the current page for `season_board`, `api_teams` and `settings`.
- `spec/bs4_leftovers_spec.rb`: `SWEPT` gains `app/views/{devise,settings,stats,season_board,best_results,goggles_cup,datagrid,kaminari,api_*}`, `app/components/{grid,issue,switch,combo_box,season_board}` and the two single-file components. Each must report zero.
- System smoke suite (01) in light and dark, plus new journeys: sidebar → every group's first item; collapse/expand the sidebar and reload (state kept); offcanvas at a narrow window; an API-offline session sees disabled items and a working Settings page.
- Manual: unplug the network and load the board (the status frame shows stale or unknown values, and the page is not slowed); stop the queue (`SOLID_QUEUE_IN_PUMA=false` with no `bin/jobs`) → queue pill red; set an API label in Settings → the top bar shows it.

## Exit criteria

- Every HTML route is reachable from the sidebar, or is a declared contextual child, with a correct active state and breadcrumbs (navigation spec).
- The shell renders in an API-offline session and with the ops DB missing; rendering it makes no `APIProxy` call.
- Zero compat uses in the swept folders; component and request specs keep their DOM ids (only the listed `data-bs-*` and `text-bg-*` assertions changed).
- No view outside the left-on-compat groups still contains `.wrapper-body`; `DashboardTitleComponent` and `_main_navbar` are deleted.
- Smoke suite green in both themes; rubocop and haml-lint clean; CHANGELOG + PATCH for steps 2-7.
- **Routine gate:** sign in → board → crawl → review → commit → report → push → confirm still works.

## Risks and mitigations

- **The status frame slows pages, or fails when the crawler or queue DB is absent.** It is a lazy frame; snapshot probes are read-only; inline probes are local and wrapped so they never raise.
- **Neutralising CSS hides content** in an un-swept page that uses `#footer.fixed-bottom` for real content. Only home's footer has content, and its items move to the user menu. The smoke suite and the manual pass cover home, push, pull, pdf and data_fix.
- **Registry drift** as later phases add pages. The navigation spec fails on any unmapped HTML route.
- **Byte-exact pins** (`id='badge-readonly'`, the GogglesCup class string). Listed in the G4 checklist; the spec runs in the same commit.
- **Dark-mode contrast** of the tints, Chart.js (`chart_api_controller.js`) and CodeMirror. Token dark values, checklist item 4; Chart.js colours read from CSS variables in G1.
- **Grid modal opening change** (explicit `show()`). Covered by the smoke scenario "row edit opens `#grid-edit-modal` with the name pre-filled".

## Decisions to confirm

- Sidebar groups and placement (Trainings and User workshops under Support; Push under Import until 07): **as in the registry above**.
- Sidebar collapsed state: **cookie, server-rendered** (no flash on load); offcanvas below the lg breakpoint.
- Status pills in 04: **API, crawler, queue, FIN watcher**; the rest in 05.
- Probe refresh: **every 5 minutes, plus on demand when older than 2 minutes**.
- API label storage: **`Ops::Setting` JSON keyed by URL**, so switching URLs in Settings shows the matching label.
- Engine partials: **permanent `[data-bs4-compat]` scope**; no goggles_db change.
- `full_bleed_layout.scss` and the old `.wrapper-body` CSS: **kept until 15**.

## Out of scope

Deleting `Footer::MainComponent` (phase 15). Converting home (05), push (07), Data-Fix (12), pull/pdf/file_list (15); the inbox and KPI changes (05); the command palette (15; only the `search` slot and `palette_entries` stub exist); the API-reported environment name (08); new pages for health, outbox, operations or DB sync.

## Outcome (done, 0.10.83, 2026-11-23)

Delivered on `feature/modernize-admin-console-ux` in three commits (steps 1-3; steps 4-7, the four sweep groups; step 8). All seven decisions confirmed with their defaults. Full suite green (3143 examples, 0 failures), system suite green in light and dark, rubocop clean, no new haml-lint offenses. Every page group was screenshotted in both themes. Notes for later phases:

- **Names**: `API` and `FIN` are inflection acronyms, so the shipped classes are `Shell::APITarget`, `Shell::APITargetBadgeComponent`, `SystemStatus::APIProbe`, `SystemStatus::APISnapshot`, `SystemStatus::FINWatchProbe` (plus `CrawlerProbe`, `QueueProbe`); probe keys `api`, `crawler`, `queue`, `fin_watch`. New probes go in `SystemStatus::Registry::PROBES`. The best-results navigation keys are the action names (`:best_50m` ... `:all_time_best`). Plans 05, 07, 08 and `contracts.md` were updated to these names.
- **Probe levels as shipped**: API reachable with code < 500 = ok (a 401 counts as reachable), 5xx = warn, unreachable or API-offline session = error, snapshot older than 15 min = unknown; crawler not running = unknown ("off", it starts on demand); queue = unknown unless the Active Job adapter is `solid_queue` (always unknown in test). Phase 05 refines these.
- **Snapshots**: only `api.status:<url>` (payload `url`, `reachable`, `code`, `version`, `msg`, `error`; a later answer without a version keeps the known one) and `system_status.crawler`. `SystemStatus::RefreshJob` drops duplicates (`limits_concurrency ... on_conflict: :discard`), skips snapshots younger than 1 minute unless `force: true`, and does nothing without the ops DB.
- **Risk left**: `APIProxy.ping` has no read timeout (RestClient default 60 s), so a hung API can hold the single `default` worker for up to about a minute per refresh. Not changed here; worth a short timeout when phase 05 adds more `default` jobs.
- **Navigation spec allow-list** (the real one): `users/sessions#new`, `lookup#index/show`, `pull#extraction_status`, `pull#edit_name`, `pull#edit_file` (turbo-stream GETs) and `shell/status#show`; the other endpoints the plan listed map to their controller item anyway. An action crumb (`shell.actions.*`) is added only for a non-landing action of the item's own controller (`no_mirs`, `expand`, trainings `new`/`edit`, cup `base_timings`).
- **Layout**: `#flash-messages-container` stays the first child of body; the sign-in page is `%main.app-auth` without `#content`/`#sticky-alerts`; `main.app-content#content` carries `data-page=<controller_path>`. `Footer::MainComponent` is no longer rendered anywhere (the home render was removed); the component is deleted in 15.
- **Compat pages**: the old global `.card { overflow: hidden }` (Data-Fix result cards need it) survives only for `[data-page=home|push|pull|pdf|data_fix*]` in `shell/_legacy_wrappers.scss`; each rewriting phase drops its page. `home.scss` became `pages/_home.scss` (the `.rotate` icon rules); `.alert { z-index: 1060 }` was deleted (it covered the top bar and modals).
- **Plan error**: the G2 note about `api_team_managers/index` line 17 was wrong: that link opens `#sql-create-modal`, so it keeps `data-bs-toggle="modal"`. Only the row-edit and create-new buttons open the edit modal explicitly.
- **Shared markup changed outside the swept folders**: kaminari pagination (`li.page-item > .page-link`) and the ComboBox autocomplete (`form-select`, no `.form-group`) also render on Data-Fix and Pull pages.
- **Fixed on the way**: toast disposal during fade-in; trainings delete confirm (the Italian apostrophe broke the inline `confirm`); issue type 1a link; status-button tooltips; modal `aria-labelledby`; `data-aria-expanded` on GogglesCup; best-results list lazy i18n keys (raised once a team was selected); tom-select text unreadable in dark (the vendored theme hard-codes `#343a40`).
- **New helpers**: `.table-body-tertiary` / `.table-body-secondary` (Bootstrap's `.table-light` stays light in dark); `theme_controller.js` dispatches `theme:changed` (the Stats chart redraws on it); tokens `--ga-grid-order-bg/-fg`, `--ga-font-mono`, `--ga-switch-off-bg`, sidebar/topbar sizes, env colours.
- **Burn-down**: `SWEPT` holds 33 folders; remaining baseline: `app/views/data_fix` 292, `pull` 34, `app/javascript/controllers` 17, `file_list` 15, `app/components/data_fix` 11, `pdf` 11, `home` 6, `app/components` (root) 2 (`mr-2` in `federnuoto_watch_alert_component`).
- **Dark-mode issues left for the rewriting phases**: 05 home: `.text-dark` card titles on the dark-blue tint, dim flashing port badge. 12 Data-Fix: matched Teams/Swimmers cards and the Events session header use `bg-light` (unreadable); result program cards clip the Status/Timing columns (pre-existing). 15: the Pull crawler log textarea autofocus scrolls the page; `pull/calendar_meetings` and `file_list/_file_table` use `bg-light`/`text-dark`; the PDF page has no page header.
- **Not verified by hand**: the queue pill turning red with the queue stopped, the status frame with the network unplugged, and the live 20-second Season board reload in the new markup.

## Rollback note

Steps 2-3 can be reverted as a pair: restore the 03 layout and `_main_navbar`. The neutralising CSS is then unused, and the views still carry their wrappers, except swept groups, which render without gutters in the old layout and stay usable. Steps 4-7 revert per group; revert the group's `SWEPT` entry in `bs4_leftovers_spec.rb` with it. Snapshots and labels in the ops DB are harmless if left behind. Remove the `system_status_refresh` entry from `config/recurring.yml` when reverting step 3.
