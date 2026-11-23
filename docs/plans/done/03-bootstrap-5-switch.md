# Phase 03 — Bootstrap 5.3 switch + compatibility layer

## Goal

Replace Bootstrap 4.6.2 + jQuery + FontAwesome 4.7 (all from CDNs) with locally vendored Bootstrap 5.3, FontAwesome 6 Free (with v4 shims) and the tom-select Bootstrap 5 theme. Layout and page markup stay the same. A temporary compatibility layer keeps the Bootstrap 4 class names and `data-*` attributes working until each page group goes native in its own phase.

## Operator-visible outcome

- Pages look and behave as before, but no jQuery is loaded and the app works with no network access, assuming the API runs locally.
- Tooltips also work in content inserted later (Turbo frames and streams, cable payloads, modals).
- Flash messages appear as toasts in the top-right corner. Errors stay until dismissed. The API-offline banner and the FIN watcher alert sit in their own `#sticky-alerts` region, so a turbo-stream flash update no longer erases them.
- A light/dark toggle in the navbar, remembered per browser.

## Depends on

- **01**: the `spec/system` smoke suite, run on the Bootstrap 4 UI as the regression baseline, and the `Ops::*` wiring (not used here).
- **02**: legacy Data-Fix views, routes and controller deleted; `_modal_progress` moved out of `data_fix_legacy/` to `app/views/goggles/_modal_progress.html.haml`; jsoneditor CSS link, `font-awesome-rails` gem and the empty SCSS stubs removed. This phase assumes all of these are gone. If any remain, delete them first in a separate commit.

## Invariants that apply here

- Every phase leaves the weekly routine working (the routine gate).
- Dashboard and status surfaces make no synchronous remote call and render API-offline. This phase adds none.
- No job is added: commit, push, apply and restore jobs stay click-only (rule untouched). No admin2-only tables in MySQL, no ops table is added here. File conventions (`NNNN-<base>-lt4.sql`, `results.new/sent/done/<season>`) are untouched.
- Repo conventions: `# frozen_string_literal: true`, en and it keys, a CHANGELOG entry plus a PATCH bump in `lib/version.rb` for each user-visible step, `bundle exec rubocop -a` clean, haml-lint clean. Never run a bare `bin/rails db:prepare` or `db:migrate`.
- "Staging" means the import staging tables only. The deprecated staging environment gets no new behaviour.

## Scope

### Vendored assets (exact locations)

Propshaft adds every existing directory under `app/assets/*`, `lib/assets/*` and `vendor/assets/*` to the load path at boot. See `propshaft-1.3.2/lib/propshaft/railtie.rb:27-29` and the `paths.add "vendor/assets", glob: "*"` line in railties `engine/configuration.rb:107`. `config/application.rb:22-23` adds `app/javascript` and `vendor/javascript` explicitly. That is how `vendor/javascript/codemirror-json.js` is served through `pin 'codemirror-json', to: 'codemirror-json.js'` (`config/importmap.rb:31`). So no config change is needed, but the server must be restarted once `vendor/assets/stylesheets/` exists. `.gitignore` ignores only `/vendor/bundle` and `/vendor/assets/bower_components` (checked with `git check-ignore`).

| File | Location | Served as |
|---|---|---|
| Bootstrap CSS 5.3.x | `vendor/assets/stylesheets/bootstrap/bootstrap.min.css` (+ `.map`, optional) | `stylesheet_link_tag('bootstrap/bootstrap.min')` |
| FA 6 Free CSS | `vendor/assets/stylesheets/fontawesome/css/all.min.css`, `.../css/v4-shims.min.css` | `'fontawesome/css/all.min'`, `'fontawesome/css/v4-shims.min'` |
| FA 6 webfonts | `vendor/assets/stylesheets/fontawesome/webfonts/*` (the whole `webfonts/` folder of the package: brands, regular, solid, v4compatibility; woff2 + ttf) | resolved by the CSS |
| tom-select theme | `vendor/assets/stylesheets/tom-select/tom-select.bootstrap5.min.css` | `'tom-select/tom-select.bootstrap5.min'` |
| Bootstrap JS + Popper | `vendor/javascript/bootstrap.js`, `vendor/javascript/@popperjs--core.js` | written by `bin/importmap pin bootstrap@5.3.x --from jsdelivr`, which downloads into `vendor/javascript/` (importmap-rails 2.2.3) |
| tom-select JS, chart.js | `vendor/javascript/` through `bin/importmap pin tom-select@2.3.1 chart.js@4.4.4 --from jsdelivr` | replaces the CDN URLs at `config/importmap.rb:18-19,22` |

Keep each package's LICENSE file next to its files.

**Webfont URLs under digests.** `Propshaft::Compiler::CssAssetUrls` rewrites every relative `url(...)` against the CSS file's *logical* path. `fontawesome/css/all.min.css` has logical directory `fontawesome/css`, so `url(../webfonts/fa-solid-900.woff2)` resolves to `fontawesome/webfonts/fa-solid-900.woff2`. That file is in the same load root, so the URL is rewritten to its digested path. The `css/` and `webfonts/` folders must keep the package's relative layout, and the CSS must **not** be `@use`d into `application.scss`: dartsass would inline it into `builds/application.css`, whose logical directory is `.`, and the `../webfonts` URLs would no longer resolve. Propshaft drops a `sourceMappingURL` comment whose `.map` is missing, with a log warning (`source_mapping_urls.rb`), so vendoring the maps is optional.

**Versions to pin** (check the latest patch at implementation time): Bootstrap **5.3.x**. The design probe saw 5.3.9 on jsDelivr; not re-verified. `@fortawesome/fontawesome-free` **6.7.x** (6.7.2 seen; do not take 7.x, a new major). tom-select **2.3.1**, the version pinned today; only the CSS theme changes. chart.js **4.4.4**, unchanged. After pinning, check that the downloaded Popper file is the ESM build with no `process.env` reference (not verified).

**Network risk to note:** the master plan lists only Bootstrap JS, CSS, icons and the tom-select CSS for vendoring. The offline goal also requires the tom-select and chart.js JS pins, which are CDN URLs today (`config/importmap.rb:18-22`), so they are vendored here too.

### Layout head (`app/views/layouts/application.html.haml:12-27`)

- Replace the four CDN `stylesheet_link_tag`s and the two CDN `javascript_include_tag`s (jQuery 3.7.1, BS4 bundle) with the local tags above, followed by `stylesheet_link_tag('application')` and `javascript_importmap_tags`.
- Delete the jQuery comments at lines 23-24.
- Set `%html{ lang: I18n.locale, data: { bs_theme: current_theme } }`.
- Change `%body{ 'data-controller' => 'popover' }` (line 29) to `data: { controller: 'tooltips' }`.
- Fix the stale comment at `app/assets/stylesheets/application.scss:2` ("CDN-loaded: Bootstrap 5, Font Awesome 6"): it is wrong today.

### Compatibility layer, CSS: `app/assets/stylesheets/compat/_bs4.scss`

Loaded with `@use 'compat/bs4';` right after `custom_fonts` in `application.scss`. Each rule group is a mixin. Phase 03 includes them at the root; phase 04 adds a permanent `[data-bs4-compat] { @include ... }` scope for the goggles_db engine partials; phase 15 removes the root includes.

Counts were re-measured on 2026-11-21 with `grep -rEo` over `app/views` (excluding `app/views/data_fix_legacy`, which 02 deletes), `app/components`, `app/javascript`, `app/helpers`, `app/grids` and `app/controllers`:

| Mixin / rule | BS4 token | Occurrences / files | Rule |
|---|---|---|---|
| `bs4-spacing` | `ml-*`, `mr-*` (0-5, auto, breakpoint infixes) | 164 / 39 | `margin-left`/`margin-right` with `!important`, `@each` over 0-5 and auto |
| `bs4-spacing` | `pl-*`, `pr-*` | 3 / 3 (+ `pr-4` ×4 in the engine partials) | padding equivalents (kept because the engine needs them) |
| `bs4-text` | `text-right` / `text-left` | 77 / 21, 11 / 7 | `text-align` with `!important` |
| `bs4-badges` | `badge-{primary…dark}` | 111 / 22 | background from `--bs-<c>-rgb`; white text, except warning/info/light, which get dark text (mirrors BS5 `text-bg-*`) |
| `bs4-forms` | `form-group` | 104 / 23 (another 41 sit in `data_fix_legacy`) | `margin-bottom: 1rem` |
| `bs4-forms` | `form-row` | 16 / 3 (`data_fix/_meeting_form_card`, `_session_form_card`, `api_trainings/_form`) | flex wrap, `-5px` gutters, `5px` padding on direct `col` children |
| `bs4-forms` | `form-inline` | 4 / 4 (one is the Ruby default at `data_fix/turbo_filter_state_component.rb:24`) | `display:flex; flex-flow:row wrap; align-items:center`; inline controls from 576px |
| `bs4-behaviour` | `label` | — | `label { margin-bottom: .5rem }` (BS5 dropped it) |
| `bs4-behaviour` | links | — | `a { text-decoration: none }`, underline on hover except `.btn`, `.nav-link`, `.dropdown-item` (BS5 underlines by default) |
| `bs4-behaviour` | `.row` children | e.g. `.row.btn-toolbar` at `grid/toolbar_component.html.haml:1` | `.row > :not([class*='col']) { width:auto; max-width:none; flex-shrink:1 }` (BS5 makes every child full width) |
| `bs4-behaviour` | row backgrounds | `tr.bg-*` rows | `.table tr[class*='bg-'] > * { --bs-table-bg: transparent }` (BS5 paints the cells) |
| `bs4-behaviour` | `select.form-control` | 10 lines pair a select with `form-control` | `appearance: auto` (BS5 removes the native caret) |
| `bs4-behaviour` | `.btn-group-toggle` | 1 / 1 (`turbo_filter_state_component.html.haml:34`) | hide the radio inputs inside `.btn-group-toggle > .btn` |

The rules are about 80 lines. Zero uses, so no rule: `jumbotron`, `media`, `card-deck`, `btn-block`, `no-gutters`, `dropdown-menu-right`, `embed-responsive`, `text-hide`, `pre-scrollable`, real popovers (`popover_controller.js:48` initialises them, but no markup has `data-toggle="popover"`). `row-fluid` (46 / 31) is a Bootstrap 2 name, inert in both versions, so it is left alone.

### Compatibility layer, JS: `app/javascript/bs4_compat.js`

Pinned as `pin 'bs4_compat', to: 'bs4_compat.js'`, the same pattern as `data_fix_helpers` at `config/importmap.rb:14`. It is imported first in `app/javascript/application.js`.

```js
// copy (never move) BS4 data-* attributes to their BS5 names
const ATTRS = { toggle: 'bsToggle', dismiss: 'bsDismiss', parent: 'bsParent', placement: 'bsPlacement' }
function upgrade(el) {
  const d = el.dataset
  for (const [bs4, bs5] of Object.entries(ATTRS)) if (d[bs4] && !d[bs5] && d[bs4] !== 'buttons') d[bs5] = d[bs4]
  if (d.toggle && d.target && !d.bsTarget) d.bsTarget = d.target       // target only next to a toggle
  if (d.toggle === 'tooltip' && d.title && !d.bsTitle) d.bsTitle = d.title
}
// initial pass over document, then one MutationObserver on document.documentElement:
// { childList: true, subtree: true, attributes: true,
//   attributeFilter: ['data-toggle', 'data-target', 'data-dismiss', 'data-parent', 'data-placement', 'data-title'] }
```

- **One `MutationObserver`, not Turbo events.** BS5's data API is delegated and reads attributes at click time. The observer also catches HTML inserted by `app_notifications_channel.js:66`, by `innerHTML` renders (`verify_result_controller.js:58`, `goggles_cup_controller.js:204`, the inline script at `review_teams.html.haml:162`) and by turbo streams.
- **Copy, never move.** `data_fix/_team_form_card.html.haml:167` puts a custom `data-target` (no `data-toggle`) on `.verify-team-btn`. The inline handler at `data_fix/review_teams.html.haml:146` reads it through `btn.dataset.target`. The shim copies `data-target` only when `data-toggle` is present and never removes or renames a BS4 attribute. A unit-level system check asserts that this attribute survives.
- Measured inputs: `data-toggle` values collapse 25, tooltip 47, modal 4, dropdown 1, buttons 1; `data-dismiss` ×7 in 4 templates; `data-parent` ×5 in 4 files; `placement:` ×9 in `goggles_cup/index.html.haml` and `goggles_cup/_swimmer_list.html.haml:10`.

### Fixed directly in the switch commit (cannot be shimmed, or an edit is cheaper)

1. jQuery plugin API: delete `popover_controller.js` and rewrite `modal_controller.js` (8 jQuery calls, lines 30-58). See the Stimulus section.
2. `.close` → `.btn-close` (drop the inner `×` span; `data-dismiss` → `data-bs-dismiss` in the same element) ×5: `file_list/_file_modal.html.haml:12`, `grid/edit_modal_component.html.haml:18`, `grid/sql_create_modal_component.html.haml:14`, `federnuoto_watch_alert_component.html.haml:4`, `flash_alert_component.html.haml:2`. In these three modal templates the footer `data-dismiss` buttons also become `data-bs-dismiss`: `_file_modal:26`, `sql_create_modal:50`, `edit_modal:66`.
3. `custom-select` → `form-select` (`data_fix/review_events.html.haml:45`); `custom-control custom-checkbox`/`-input`/`-label` → `form-check`/`form-check-input`/`form-check-label` (`data_fix/_relay_enrichment_panel.html.haml:35-37`).
4. Unwrap `.input-group-append` ×2: `legacy_auto_complete_component.html.haml:32`, `data_fix/turbo_filter_state_component.html.haml:20`.
5. `thead-light` → `table-light` ×4: `season_board/index.html.haml:80`, `data_fix/_relay_program_card.html.haml:162`, `data_fix/commit_phase6_report.html.haml:53`, `data_fix/_result_program_card.html.haml:86`.
6. `badge-pill` → `rounded-pill` ×3 (`season_board/index.html.haml:57,61`, `_relay_enrichment_panel.html.haml:25`); `float-right` → `float-end` ×3 (`best_results/_best_results_list.html.haml:9`, `data_fix/_phase_metadata.html.haml:24`, `dashboard_title_component.html.haml:1`); `font-weight-bold` → `fw-bold` ×3 (`goggles_cup/_swimmer_list.html.haml:38`, `commit_phase6_report.html.haml:91`, `_relay_enrichment_panel.html.haml:94`).
7. `text-monospace` → `font-monospace` and `form-control-file` → `form-control` (`api_trainings/_form.html.haml:45,14`); drop the redundant `sr-only` at `goggles_cup/index.html.haml:8`, which already has `visually-hidden`.
8. Remove `'data-toggle': 'buttons'` at `turbo_filter_state_component.html.haml:34`. The plugin is gone in BS5, the class stays as a CSS hook, and the filter form already auto-submits.
9. `tom_select_customizations.scss:41-45`: `#007bff` → `var(--bs-primary)`.
10. `goggles/_main_navbar.html.haml`: wrap the content in `.container-fluid` (BS5 navbar padding). Everything else in the navbar works through the shim (`data-toggle` at lines 8-9 and 29) until 04 deletes the partial.
11. The progress-modal partial (moved by 02 from `data_fix_legacy/_modal_progress.html.haml` to `app/views/goggles/_modal_progress.html.haml`): drop the hand-made `.modal-backdrop#modal-progress-backdrop` (line 1) and add `.fade`. The ids `#modal-progress`, `#progress-msg`, `#di-progress` stay.

BS5 classes that are inert today start applying at the switch: `ms-*`/`me-*` (27 occurrences in 4 files), `text-end`, `fw-bold`, `form-label`, `gap-*`, `.badge.bg-warning` (`review_results.html.haml:190-194`). `review_results` and `goggles_cup` need a visual check.

### Stimulus and channel changes

| File | Change |
|---|---|
| `controllers/popover_controller.js` | **Delete.** |
| `controllers/tooltips_controller.js` (new, on `<body>`) | `this.tooltip = new Tooltip(this.element, { selector: '[data-bs-toggle="tooltip"]' })`, so frames, streams and cable inserts need no re-init. `dispose()` on disconnect. Remove stray `.tooltip` nodes on `turbo:before-cache` and `turbo:before-frame-render`. Keep the 4 s auto-hide (`popover_controller.js:53-58`) through a `shown.bs.tooltip` listener on the body (BS5 events bubble). |
| `controllers/toast_controller.js` (new) | One instance per flash element: `Toast.getOrCreateInstance(el, { autohide, delay: 5000 }).show()`; remove the element on `hidden.bs.toast`. `autohide` is false for `:error` and for sticky payloads (today errors fade after about 3 s, `popover_controller.js:62`). |
| `controllers/modal_controller.js` | `connect`: `Modal.getOrCreateInstance(this.element).show()`. `disconnect`: `dispose()` the instance (not `hide()`, which animates on a detached node), remove any `.modal-backdrop`, `document.body.classList.remove('modal-open')`, clear `body.style.overflow` and `paddingRight`. Used by `file_list/_file_modal.html.haml:2`. |
| `controllers/progress_modal_controller.js` | `Modal.getOrCreateInstance(this.modalTarget, { backdrop: 'static', keyboard: false })`. New action `update` bound with `import-status@document->progress-modal#update`: sets the message and progress (the code of `updateProgress`/`updateMessage`, lines 53-71), shows the modal, and hides it 2 s after reaching the total. |
| `channels/import_status_channel.js` | Keep the de-duplication check (lines 29-40). Replace the DOM code at lines 42-69 with `document.dispatchEvent(new CustomEvent('import-status', { detail: { msg, value, total } }))`. |
| `controllers/collapse_all_controller.js` | Keep the direct `show` class toggle (fast on hundreds of panels), but also sync each trigger's `.collapsed` and `aria-expanded` (`[data-bs-target="#id"]`). The two hard-coded labels at lines 62 and 66 become Stimulus values `expandLabel`/`collapseLabel`, defaulting to the current English text (the i18n move is in phase 12). |
| `controllers/verify_result_controller.js:43` | `Collapse.getOrCreateInstance(panel, { toggle: false }).show()`. |
| `controllers/goggles_cup_controller.js:242` | Same, so `#btn-show-precomputed` stays in sync. |
| `controllers/grid_edit_controller.js` | On `shown.bs.modal` of `#${baseModalId}-modal`, call `requestMeasure()` on each `container.codemirrorView` (a native event in BS5; BS4 fired jQuery-only events). Opening still goes through the shimmed `data-toggle="modal"`; phase 04 opens explicitly. |
| `channels/app_notifications_channel.js` | Payload HTML with `flash-sticky` goes to `#sticky-alerts` (replace by `dom_id` as today); anything else is prepended to `#flash-messages` and auto-hidden by `toast_controller`. `scheduleAutoHide` (lines 39-47) is kept only for non-toast, non-sticky payloads. |
| `controllers/theme_controller.js` (new) | Toggles `document.documentElement.dataset.bsTheme` and writes the `theme` cookie (`path=/; max-age=31536000; SameSite=Lax`). |
| `application.js` | `import "bs4_compat"` first, then `import * as bootstrap from "bootstrap"; window.bootstrap = bootstrap`, then the existing imports. Controllers import `{ Modal, Collapse, Tooltip, Toast }` from `"bootstrap"`. |

Not changed now, still working: `review_teams.html.haml:148` adds `show` inline (BS5 Collapse reads the class state; converted in 12). `filter_results_controller.js:88-89,121` and `data_fix_overwrite_controller.js:147-189` select or assign `badge-*` classes. Their markup is unchanged, so they keep working until 12.

### Flash → toasts, and `#sticky-alerts`

The layout keeps the same wrapper. Inside `.main-content`, `#flash-messages-container` is replaced by `#sticky-alerts`, which holds the API-offline banner (still skipped on `settings`) and `FedernuotoWatchAlertComponent.from_store`. A new `.toast-container.position-fixed.top-0.end-0.p-3#flash-messages-container` sits right after `<body>` and renders `goggles/_flash_messages`, whose root stays `#flash-messages`.

- `FlashAlertComponent` renders `.toast.flash-alert` with `data-controller="toast"`, `role="alert"`, the `alert_background_class` colour as `text-bg-*`, a `.btn-close` with `data-bs-dismiss="toast"`, and `flash-sticky` when sticky. The marker classes `flash-alert` and `flash-sticky` are kept: they are pinned by `spec/components/federnuoto_watch_alert_component_spec.rb:27`, `spec/services/federnuoto_watch/checker_spec.rb:104` and `spec/requests/data_fix_controller_phase3_spec.rb:288`.
- The API-offline banner (`#api-offline-banner`, pinned by `spec/requests/api_offline_session_spec.rb:20,35` and `settings_controller_spec.rb:232,266`) and the FIN alert stay inline `.alert`s.
- The five `turbo_stream.update "flash-messages-container"` templates (`file_list/edit_file`, `file_list/file_table_update`, `file_list/edit_name`, `pdf/scan`, `pdf/log_contents`; a sixth in `data_fix_legacy` goes in 02) now replace only the toasts. This fixes the erasure of the sticky alerts.

### Theme (minimal; phase 04 extends it)

- `ApplicationHelper#current_theme` (`app/helpers/application_helper.rb`) returns `cookies[:theme]` when it is `light` or `dark`, else `light`.
- A navbar button `#theme-toggle` (`theme#toggle`), with en/it keys `theme.toggle`, `theme.light`, `theme.dark` in new `config/locales/theme.{en,it}.yml`.
- New `app/assets/stylesheets/base/_tokens.scss` defines the pastel tints behind `.bg-light-*` as `--ga-tint-*` with light values. The effective winners today are in `devise_customizations.scss`, which is `@use`d after `custom_styles.scss` and overrides its `bg-light-yellow`/`-red` at lines 90-95. The partial also gives darker values under `[data-bs-theme=dark]`, and both files switch to `var(--ga-tint-*)`.

## Data model

None.

## Ordered steps

1. **Vendor and pin, no visual change.** Add the files under `vendor/assets/stylesheets/**`; pin bootstrap/popper, tom-select and chart.js locally. The layout still links the CDN files. Not user-visible: no CHANGELOG entry needed.
2. **Switch commit (user-visible).** Layout head, `compat/_bs4.scss`, `bs4_compat.js`, `application.js`, the tooltips/modal/progress-modal/collapse/grid_edit controller changes, every item under "Fixed directly", the tom-select theme, and the `sql_create_modal_component_spec.rb:90` update. jQuery and `popover_controller.js` removed. CHANGELOG + PATCH. After this step alone, non-sticky flashes no longer auto-hide; if step 3 is not ready, ship 2 and 3 in one release.
3. **Toasts and `#sticky-alerts` (user-visible).** `toast_controller`, the `FlashAlertComponent` rewrite, the layout split, channel routing, a new `spec/components/flash_alert_component_spec.rb`, request specs. CHANGELOG + PATCH.
4. **Light/dark toggle (user-visible).** Helper, `theme_controller`, the navbar toggle, `base/_tokens.scss`, locale files; the system helper gains a dark run. CHANGELOG + PATCH.
5. **Burn-down guard.** `spec/bs4_leftovers_spec.rb`, plus a short "Front-end" note in `CLAUDE.md` naming the compat files and the rule "native markup in new code". Not user-visible.

## Specs and manual verification

**The 9 spec files that pin Bootstrap 4 markup.** Because the shim copies and never moves, most of them are untouched by this phase. The master plan says all 9 are updated in 03; that is corrected here (contract: in 03 only `sql_create_modal_component_spec.rb` changes, plus one additive assertion in the turbo filter state spec; grid and season board row specs change in 04; the Data-Fix phase 2/3 request specs in 12).

| Spec | Pin | Changes in |
|---|---|---|
| `spec/components/grid/sql_create_modal_component_spec.rb:90` | `button[data-dismiss="modal"]` | **03** → `[data-bs-dismiss="modal"]` (template fixed directly) |
| `spec/components/data_fix/turbo_filter_state_component_spec.rb:58-59` | `.btn-group.btn-group-toggle` | **03**: class kept, so the assertion is unchanged; add an assertion that `[data-toggle="buttons"]` is absent. Renamed in 12. |
| `spec/components/grid/csv_export_button_component_spec.rb:27-30` | `data-toggle`, `data-title` | 04 (grid sweep) → `data-bs-toggle`, `data-bs-title` |
| `spec/components/grid/filter_show_button_component_spec.rb:10-11` | `data-target`, `data-toggle` | 04 |
| `spec/components/grid/selection_toggle_button_component_spec.rb:13-14` | `data-toggle`, `data-title` | 04 |
| `spec/components/season_board/row_component_spec.rb:69,197` | `badge-warning` | 04 (`STATE_CSS` → `text-bg-*`) |
| `spec/requests/data_fix_controller_phase2_spec.rb:62,69` | `badge-primary`, `badge-success` | 12 |
| `spec/requests/data_fix_controller_phase3_spec.rb:69,75` | same | 12 |
| `spec/requests/pull_controller_spec.rb:239` | `fa-clock-o` | none: the v4 shim keeps the name working; 15 decides |

**New and extended specs**
- `spec/requests/layout_assets_spec.rb` (new): the rendered head of `home#index` and `settings#index` contains no `jquery`, no `bootstrap@4`, no `cdn.jsdelivr`/`cdnjs`, and does contain `bootstrap/bootstrap.min`. `#sticky-alerts` is not inside `#flash-messages-container`.
- `spec/requests/api_offline_session_spec.rb`: the banner is inside `#sticky-alerts`.
- `spec/components/flash_alert_component_spec.rb` (new): toast markup, `flash-alert`, `flash-sticky` when sticky, autohide off for `:error`.
- `spec/bs4_leftovers_spec.rb` (new, at the spec root, like `spec/scenic_sqlite_schema_dumper_spec.rb`). It scans `app/views`, `app/components`, `app/javascript`, `app/helpers` and `app/grids`, excluding `app/javascript/bs4_compat.js` and `app/assets/stylesheets/compat/`. The token regex is the compat table plus `data-(toggle|target|dismiss|parent|placement)` and the HAML `toggle:`/`dismiss:`/`placement:` keys. It holds:
  - `SWEPT = []`: folders that must have zero uses (04, 05, 07, 12 and 15 add to it);
  - `BASELINE = { 'app/views/data_fix' => n, ... }`: a ratchet. The spec fails if any folder exceeds its baseline, and prints the per-folder table through `RSpec.configuration.reporter.message`.

  Reference counts from today's tree (before 02, so recompute when writing the file): `app/views/data_fix` 290, `api_issues` 56, `pull` 34, `app/javascript/controllers` 24, `components/season_board` 23, `goggles_cup` 21, `components/grid` 19, `file_list` 18, `stats` 14, `season_board` 14, `components/issue` 12, `components/data_fix` 12, `pdf` 11, `api_trainings` 11, `best_results` 7; every other folder under 6.
- System smoke suite from 01: green unchanged, then run again with `SYSTEM_THEME=dark` (the helper sets the `theme` cookie before the first visit). Add one scenario: after opening Data-Fix step 2, `.verify-team-btn` still has `data-target` (copy-never-move).

**Manual check, network unplugged:** sign in → home tooltips → navbar dropdown → `api_teams` row edit modal (CodeMirror field sized) → Season board filters and orphans collapse → Data-Fix step 1 collapse and save → step 4 TomSelect → Pull result files edit modal (no leftover backdrop) → a push confirmation → GogglesCup ranking panel → Stats chart. Toggle dark mode and repeat home and board. Visually check `review_results` and `goggles_cup` for the newly active BS5 classes.

## Exit criteria

- No jQuery, Bootstrap 4, FontAwesome 4 or CDN asset is loaded (asserted by `layout_assets_spec.rb`); `jquery`, `bootstrap.bundle` and `cdnjs` appear nowhere in `app/` or `config/importmap.rb`.
- The app renders with the network unplugged, except for API calls.
- The smoke suite is green in light and dark; the existing specs are green; `bs4_leftovers_spec.rb` prints the burn-down table.
- A turbo-stream flash update on the Pull/PDF pages leaves the API-offline banner and the FIN alert in place.
- rubocop and haml-lint clean; CHANGELOG + PATCH for steps 2-4.
- **Routine gate:** sign in → board → crawl → review → commit → report → push → confirm still works.

## Risks and mitigations

- **Popper or importmap resolution problems** with the downloaded bootstrap build. Use `--from jsdelivr`; the smoke suite's `expect_no_js_errors` catches load errors. Fallback: vendor `bootstrap.bundle.min.js` and expose `window.bootstrap`; controllers then read from one import site.
- **Silent BS5 layout changes** outside the measured classes (row children, cell backgrounds, label margins, link underlines, select caret). The explicit `bs4-behaviour` rules, the visual pass listed above, and smoke runs on the heaviest pages.
- **The shim renames a non-Bootstrap attribute.** It copies only, and copies `data-target` only next to `data-toggle`; covered by the `.verify-team-btn` scenario.
- **Toasts are easier to miss.** Errors and sticky payloads never auto-hide; persistent conditions stay inline in `#sticky-alerts`.
- **Delegated tooltips left on screen** after a Turbo cache or frame render. Dispose on disconnect, remove `.tooltip` nodes on `turbo:before-cache`/`turbo:before-frame-render`.
- **The compat layer lingers.** The ratchet spec, named sweep phases (04, 12, 15), and the files kept in one `compat/` folder plus one JS file.
- **Dark mode readability** of inline colours in Data-Fix partials, CodeMirror and Chart.js. Light is the default; dark is verified per swept group from 04 on; Data-Fix in 12.

## Decisions to confirm

- Theme: **default light with a manual toggle stored in a cookie**. The alternative, following the OS setting, needs an inline head script.
- Also vendor the tom-select and chart.js JS: **yes**. Without them the app is not usable offline.
- FontAwesome: **6.7.x Free + v4 shims**; no 7.x, and no Bootstrap Icons (306 icon tokens in 87 files, and the engine emits FA4 names at `goggles_db` `issue_decorator.rb:14-29`).
- tom-select: **stay on 2.3.1**, CSS theme swap only.
- `.btn-group-toggle` kept as a CSS hook until 12: **yes**.

## Out of scope

The shell (sidebar, top bar, breadcrumbs, page header), removing `.wrapper-body`/`.spacer-*`/`#footer.fixed-bottom`, per-view class renames, the Turbo progress bar and `#loading-indicator` (04), Data-Fix markup and JS (12), dark-mode polish of individual pages, the command palette.

## Outcome (done, 0.10.81, 2026-11-23)

Delivered on `feature/modernize-admin-console-ux` (steps 1-2, then 3-5). All five decisions confirmed with their defaults. Full suite green except one pre-existing order-dependent example (`spec/strategies/import/phase5_populator_spec.rb:614`, relay laps sorted by `length_in_meters` with ties); system specs green in light and dark and with external network blocked; rubocop clean; no new haml-lint offenses. Notes for later phases:

- Pinned: Bootstrap 5.3.9, Popper 2.11.8, Font Awesome Free 6.7.2 (+ v4 shims), tom-select 2.3.1, chart.js 4.4.4 (+ `@kurkle/color` 0.3.4). `bin/importmap pin` downloaded unusable files for Popper (`lib/index.js` re-export stub), tom-select (UMD, no default export) and chart.js (relative chunk imports): they were replaced by single-file ESM builds. Never run `bin/importmap pristine`/`update` on those pins (warning in `config/importmap.rb`).
- `compat/_bs4.scss` `.row` children rule uses a zero-specificity `:where(...)` and `--bs-gutter-x: 0`, safer than the planned version. `bs4_compat.js` also re-syncs a copied BS5 attribute when its BS4 source changes later.
- Modal-header `.btn-close` buttons inside forms need `type: 'button'` (BS5 only prevents the default on links). Modal/progress-modal controllers wait for a running transition before `dispose()`.
- Toasts: `FlashAlertComponent` renders `.toast.flash-alert` (`text-bg-*`); sticky payloads go to `#sticky-alerts` (API-offline banner, ops notice, FIN alert). The FIN checker spec now pins `text-bg-info` / `text-bg-danger`.
- Theme: navbar is `bg-body-tertiary`; tints in `base/_tokens.scss` (`--ga-tint-*`). `SYSTEM_THEME=dark` runs the system suite in dark (cookie set through CDP before each example).
- Burn-down baseline: 590 BS4 tokens in 27 folders (`app/views/data_fix` 292, `api_issues` 56, `pull` 34, `components/season_board` 23, `goggles_cup` 20, `javascript/controllers` 18, …). `SWEPT` is empty.
- Dark-mode readability still to check (hard-coded light backgrounds): `devise/sessions/new`, `home/_manage_entities`, `best_results/_best_results_list`, `pdf/_result_card`, `pdf/_log_card`, `pull/_crawler_status_box`, `pull/calendar_meetings`, `file_list/_file_table`, `goggles_cup/index`, `api_meeting_reservations/expand`, the Data-Fix review pages and form/program cards; CodeMirror, Chart.js and tom-select in dark.
- Not verified visually: `review_results` with real result cards (newly active `.badge.bg-warning`, `ms-*`/`me-*`, `text-end`), the GogglesCup ranking panel, the Stats chart. Pre-existing: `goggles_cup/index.html.haml:148` renders `data-aria-expanded`.

## Rollback note

Revert the step commits in reverse order. No data or migration is involved. The vendored files are inert if the layout links the CDN files again. A partial rollback of step 3 alone restores the old flash container, which is safe but brings back the sticky-alert erasure bug.
