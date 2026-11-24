# Phase 12 — Data-Fix wizard UX

## Goal

Make the review that remains fast and native:

- every older Data-Fix view and component in Bootstrap 5, off the compatibility layer;
- the stepper polished;
- next/previous issue navigation and a "needs you only" default on every step;
- card saves in place for phases 2 and 3;
- staleness banners with a one-click rebuild and a "Verify all" button;
- inline handlers and `data_fix_helpers.js` replaced by Stimulus;
- step labels in i18n.

Phase 09 has already moved the logic (runner, verdicts, ReviewRules, commit job, persistent report). This phase changes markup and front-end behaviour only, not phase-file semantics.

## Operator-visible outcome

- Each step opens filtered to "needs you", jumps from issue to issue with Next/Previous (and keyboard `j`/`k`), and shows a banner when an upstream step changed, with "Rebuild" one click away.
- Saving a team card updates that card, the swimmer cards whose badges it cascaded to, and the stepper counts, all without a full reload. The same holds for swimmer cards.
- Step 5 has a "Verify all" button that runs the single-perfect-match fix for every flagged result as one action.
- All Data-Fix pages look native in light and dark themes, with no BS4 leftovers.

## Depends on

Hard dependencies: **04** and **09**.

- **04**: shell, BS5 tokens, themes, `Shell::PageHeaderComponent`.
- **09**: `DataFix::StepperComponent` (born native), the commit summary (`data_fix_commit_summary_path`) and the persistent report (born native), `pipeline.summary`/`stale?`, `ReviewRules`, the `confirmed` flag, `DataFix::ResultVerifier` with its POST endpoint, and the `mark_edited!` after-action.
- Softer links, satisfied through 04 and 09 (03 is a dependency of 04; 02 of 09):
  - 03: `bootstrap.*` JS API; the `verify_result`, `collapse_all` and `progress_modal` Stimulus rewrites; tom-select bootstrap5 theme.
  - 02: legacy flow and the phase flags removed. The progress-modal partial now lives at `app/views/goggles/_modal_progress.html.haml` (02). `results_chunk_v2` is gone, and with it `_results_category_v2`.

## Invariants that apply here

- There is no bulk commit. The Commit button stays only on the 09 summary page and on Step 5 (both are `button_to commit_phase6_path`). "Verify all" changes staging rows only by the existing rule (exactly one perfect match, never an overwrite merge target) and never commits.
- Operator edits win. Turbo-frame saves go through the same update actions, so `mark_edited!` (09) stamps the phase exactly as a full-page save does. A rebuild of an edited phase always asks first.
- Jobs never broadcast on `ImportStatusChannel`. Interactive builds still use the progress modal (`Import::Progress::Cable`).
- "Staging" means the `data_import_*` tables.
- Repo conventions: frozen string literal (HAML `-#` header kept), en + it keys, CHANGELOG + PATCH per user-visible step, `rubocop -a` clean, spec-pinned DOM ids kept or the specs updated in the same commit.

## Scope

### Every Data-Fix template (line counts measured now) and what happens to it

| Template | Lines | Fate in 12 |
|---|---|---|
| `app/views/data_fix/review_sessions.html.haml` | 121 | native BS5; issue nav; inline `onsubmit` removed |
| `app/views/data_fix/review_teams.html.haml` | 205 | native BS5; card list in `turbo_frame_tag`; `:javascript` block (`:138`, verify-team fetch) → `verify_team_controller.js` |
| `app/views/data_fix/review_swimmers.html.haml` | 163 | native BS5; card list in frames; `onsubmit` removed |
| `app/views/data_fix/review_events.html.haml` | 114 | native BS5; first issue counter + banner for phase 4; `#frm-add-event` kept |
| `app/views/data_fix/review_results.html.haml` | 281 | native BS5; "Verify all"; issue nav over `@programs_with_issues`; Commit → summary link + kept `button_to` |
| `app/views/data_fix/_meeting_form_card.html.haml` | 293 | native BS5; `onchange` handler string (`:117-120`) → Stimulus |
| `app/views/data_fix/_session_form_card.html.haml` | 323 | native BS5; 9 inline handlers + 2 handler strings → `session_card_controller.js` |
| `app/views/data_fix/_team_form_card.html.haml` | 176 | native BS5; frame `team-card-<key-slug>`; 4 handlers + 1 string → `team_card_controller.js` |
| `app/views/data_fix/_swimmer_form_card.html.haml` | 180 | native BS5; frame `swimmer-card-<key-slug>`; 3 handlers + 1 string → `swimmer_card_controller.js` |
| `app/views/data_fix/_event_form_card.html.haml` | 124 | native BS5; 3 handlers → `event_card_controller.js` |
| `app/views/data_fix/_result_program_card.html.haml` | 275 | native BS5; `onclick` (`:117`) → Stimulus action |
| `app/views/data_fix/_relay_program_card.html.haml` | 226 | native BS5 |
| `app/views/data_fix/_relay_enrichment_panel.html.haml` | 127 | native BS5 |
| `app/views/data_fix/_phase_metadata.html.haml` | 27 | native BS5 |
| `app/views/data_fix/_v2_phase_header.html.haml` | 18 | merged into `Shell::PageHeaderComponent` + stepper; deleted |
| `app/views/data_fix/_step_tabs.html.haml` | 51 | already replaced by `StepperComponent` in 09 (delete here if 09 left it) |
| `app/views/data_fix/commit_phase6_report.html.haml` | 284 | already replaced by the 09 report page (delete here if 09 left it) |
| `app/views/data_fix/_results_category_v2.html.haml` | 45 | deleted in 02 with `results_chunk_v2` (`events_controller.rb:382-430`); delete here if still present |
| `app/components/data_fix/turbo_filter_state_component.{rb,html.haml}` | 42 + 63 | native BS5: `.btn-group-toggle` → `.btn-check` radios; spec updated |
| `app/components/data_fix/result_details_card_component.{rb,html.haml}` | 102 + 25 | used only through `ResultDetailsSetComponent`, which `data_fix_legacy/result_details.turbo_stream.erb:6` renders: legacy orphan, deleted in 02; delete here if still present |
| `app/components/data_fix/result_details_set_component.{rb,html.haml}` | 67 + 3 | same as above |

The 18 templates under `app/views/data_fix` total 3,033 lines today.

Measured compat markers in `app/views/data_fix` and `app/components/data_fix` (03 may already have fixed the low-count ones):

- 13 `data: { toggle: }` uses (10 collapse, 1 tooltip);
- 65 `form-group` and 14 `form-row` lines;
- 83 `ml-*` and 35 `mr-*`;
- 66 `badge-*`;
- 15 `text-left`/`text-right`;
- 4 `custom-*`;
- 1 `input-group-append`;
- 1 `float-*`;
- 2 `font-weight-*`.

### Inline handlers to replace (re-counted)

- **24 inline handler attributes in 9 files:** 8 `onclick`, 7 `onsubmit`, 9 `onchange`.
  - `_session_form_card` 9 (`:36, 39, 63, 136, 169, 194, 211, 261, 279`)
  - `_team_form_card` 4 (`:61, 70, 103, 166`)
  - `_swimmer_form_card` 3 (`:79, 89, 127`)
  - `_event_form_card` 3 (`:21, 25, 74`)
  - `_meeting_form_card` 1 (`:120`)
  - `_result_program_card` 1 (`:117`)
  - `review_sessions` 1 (`:88`), `review_teams` 1 (`:55`), `review_swimmers` 1 (`:63`)
- **5 handler strings** built in HAML and passed into those attributes:
  - `_meeting_form_card.html.haml:117`
  - `_session_form_card.html.haml:115, 168`
  - `_team_form_card.html.haml:102`
  - `_swimmer_form_card.html.haml:123`
- **1 inline script block**: `review_teams.html.haml:138` (`:javascript`).
- **`window.DataFix`** (`app/javascript/application.js:5-7`): 9 exported functions of `app/javascript/data_fix_helpers.js` (443 lines), each called once from the views:
  - `resetMeetingFormToOriginal`, `resetTeamFormToOriginal`, `resetSwimmerFormToOriginal`, `resetSessionPoolAndCityToOriginal`;
  - `rehydrateSessionPoolAndCity`, `rehydrateSessionCityFromId`;
  - `copySessionPoolAndCity`, `populateSessionFromExisting`, `populateEventFromExisting`.

The functions move into the card controllers (shared DOM helpers in `app/javascript/lib/form_fields.js`). The importmap pin (`config/importmap.rb:14`), the import and the global are removed. `onsubmit: "return confirm(…)"` becomes `data: { turbo_confirm: t(…) }`.

Existing Stimulus controllers touched:

- `verify_result_controller.js` (316 lines): calls the 09 POST endpoint; gains "verify all" progress.
- `data_fix_overwrite_controller.js` (239);
- `data_fix_filter_state_controller.js` (61);
- `filter_results_controller.js` (144);
- `collapse_all_controller.js` (69): BS5 Collapse API, if 03 did not already move it;
- `autocomplete_lookup_controller.js` (677): only the BS5 class names it toggles.

### DOM ids and selectors pinned by specs (keep, or update the spec in the same commit)

- `spec/requests/data_fix_controller_phase1_spec.rb`:
  - `#meeting_search` (`:69`), plus the **content of its `onchange` attribute** (`:70-73`). This must be rewritten to assert the Stimulus `data-action` and the targets instead, because the attribute disappears.
  - `#meeting_search option[selected]` (`:1142`).
  - `#meeting_meeting_id`, `#meeting_meeting` and `#meeting-desc`, each with `data-legacy-autocomplete-target` (`:80-92`).
  - `id="meeting_description|code|season_id|header_year|header_date|edition|edition_type_id|timing_type_id|cancelled|confirmed"` (`:99-108`).
  - `#meeting_description[value]` (`:1141`).
- `spec/requests/data_fix_controller_phase4_spec.rb`:
  - `div[id^="event-card-"]` with `input[name="session_index"]` / `input[name="event_index"]` (`:52-56, 83-87`);
  - `form#frm-add-event` (`:136`);
  - `.row.align-items-end.add-event-controls-row`, `div.w-100.autocomplete-lookup-fixed.autocomplete-lookup`, `select#event_type_select.autocomplete-lookup__select` (`:138-140`).
- `spec/requests/data_fix_controller_phase2_spec.rb:62,69` and `data_fix_controller_phase3_spec.rb:69,75`: `badge-primary` (NEW badge) and `badge-success` (ID badge) in the body. These are BS4 class names (03's table assigns them to this phase): update them to `text-bg-primary` / `text-bg-success` in the same commit as the team/swimmer card conversion (step 3).
- `spec/requests/data_fix_controller_phase5_spec.rb:576`: `#program-card-0` in the body.
- `spec/requests/data_fix_controller_structure_commit_spec.rb:113-127`: `form[action='<commit_phase6_path(file_path:)>'] button[type=submit]` and its `disabled` attribute on Step 5.
- `spec/components/data_fix/turbo_filter_state_component_spec.rb`:
  - `form[data-controller='data-fix-filter-state']`;
  - hidden `file_path`/`phase2_v2` inputs;
  - text `q` and `button[aria-label='Search'] i.fa.fa-search`;
  - radios `filter_state` none/review/diff_key;
  - `select[name='teams_per_page']`;
  - `.btn-group.btn-group-toggle .btn.btn-outline-secondary` × 3 (`:58-59`). This is a BS4 class, so update it to the BS5 `.btn-check` + label markup.
- Card ids used by anchors and the JS: `team-card-N`, `swimmer-card-N`, `event-card-N`, `*-header-N`, `*-panel-N`, `team_N_*`/`swimmer_N_*` fields, `fuzzy_select_N`.
  - The new Turbo frames for phase 2/3 cards use a **key-based** id (`team-card-k-<sha1(key)[0,10]>`), because `N` is the position in the filtered page and changes when a saved card leaves the filter.
  - The `N`-based ids stay on the inner elements the specs and helpers address.
- Season board pins (`spec/requests/season_board_controller_spec.rb:126-133`) are not touched.

### Feature work

- **Stepper polish** (`DataFix::StepperComponent` from 09): verdict pill and count per step, a "stale" state with reason, a "being prepared" state (the 09 lease, taken by the 10 prepare job), the current step's rescan inside a dropdown with a confirmation that names the edits it would discard, and a responsive collapsed layout.
- **Next/previous issue:** `issue_nav_controller.js` reads `data-issue` markers that each card gets from `ReviewRules`/`IssueDetector`. It scrolls to, focuses and expands the card, and crosses pages using a `page` param plus an `#anchor`. Shortcuts are `j`/`k` (ignored while typing).
- **"Needs you only" default:**
  - phases 2-3: `filter_state` defaults to `review` when there is no cookie;
  - phase 5: the existing auto-on (`results_controller.rb:96`) stays;
  - phases 1 and 4: a new "issues only" toggle, backed by the 09 verdict issues;
  - the cookie scope is unchanged (`base_controller.rb:156-163`).
- **Turbo-frame card saves, phases 2 and 3 only:**
  - `update_phase2_team` and `update_phase3_swimmer` respond to `turbo_stream`. The response replaces the saved card. For phase 2, it also replaces every swimmer card whose badge `team_key` matches, which is the set `TeamCascade.cascade_team_to_phase3` touched (`team_cascade.rb:12-59`). It also replaces the stepper and updates the flash in `#flash-messages-container` (or the 03 toast region).
  - HTML redirects stay for non-Turbo requests, so the existing request specs keep passing.
  - Delete and add actions keep full-page redirects.
- **Staleness banners:** every step reads `pipeline.stale?(n)`.
  - When the stale phase is unedited, "Rebuild" is a POST to a new `data_fix/rebuild_phase` action (`build_phase!(n)`), with progress modal and redirect.
  - When it is edited, the button asks for confirmation and passes `force`.
  - Step 4 gets its first banner (P1 sessions changed); Step 5 keeps the 09 auto-rebuild rule.
- **"Verify all":** a POST to the 09 `ResultVerifier` endpoint. It shows counts (fixed, partial, none) and refreshes the program cards that changed. Partial matches stay as review items.
- **i18n:** step labels, banner texts, button labels and the hard-coded flash strings in the touched views and in `swimmers_controller.rb:77-90` / `teams_controller.rb:210,219` go to `data_fix.*` keys in en and it.

### Files

- Modified: the templates and components above, `app/controllers/data_fix/{teams,swimmers,base}_controller.rb` (turbo_stream formats, `rebuild_phase`), `config/routes.rb`, `app/javascript/application.js`, `config/importmap.rb`, the Stimulus controllers listed above, `config/locales/data_fix*.{en,it}.yml`.
- New:
  - `app/javascript/controllers/{team_card,swimmer_card,session_card,meeting_card,event_card,issue_nav,verify_team}_controller.js`
  - `app/javascript/lib/form_fields.js`
  - `app/views/data_fix/update_phase2_team.turbo_stream.haml`, `update_phase3_swimmer.turbo_stream.haml`
  - `spec/system/data_fix_review_journey_spec.rb`
- Deleted: `app/javascript/data_fix_helpers.js`, `_v2_phase_header.html.haml`, and any leftovers listed in the table.

## Data model

None.

## Ordered steps

1. **Stimulus extraction, same markup** (no visible change): card controllers and `form_fields.js`, the 24 handler attributes, 5 strings and the `:javascript` block replaced, `window.DataFix` and `data_fix_helpers.js` removed, phase 1 spec `:70-73` rewritten. No CHANGELOG entry: internal.
2. **Native BS5 for phase 1 and phase 4 views** (`review_sessions`, `_meeting_form_card`, `_session_form_card`, `review_events`, `_event_form_card`, `_phase_metadata`). Pins kept. User-visible: CHANGELOG + PATCH.
3. **Native BS5 for phases 2-3** (`review_teams`, `_team_form_card`, `review_swimmers`, `_swimmer_form_card`, `_relay_enrichment_panel`, `TurboFilterStateComponent` + its spec, and the phase 2/3 request-spec `badge-*` assertions). CHANGELOG + PATCH.
4. **Native BS5 for phase 5** (`review_results`, `_result_program_card`, `_relay_program_card`); `_v2_phase_header` folded into the page header. CHANGELOG + PATCH.
5. **Stepper polish + i18n labels + staleness banners + `rebuild_phase`.** CHANGELOG + PATCH.
6. **"Needs you only" defaults + next/previous issue navigation.** CHANGELOG + PATCH.
7. **Turbo-frame card saves for phases 2 and 3**, with the cascade updates. CHANGELOG + PATCH.
8. **"Verify all"** in Step 5. CHANGELOG + PATCH.
9. **Clean-up and docs:** delete leftovers, add `app/views/data_fix` and `app/components/data_fix` to `SWEPT` in `spec/bs4_leftovers_spec.rb` (at zero, nothing in `BASELINE`), update `docs/data_fix/PHASES.md` (operator flow) and the `AGENTS.md` pool/city rehydration note (the helpers moved to `session_card_controller.js`). No version bump.

## Specs and manual verification

- Existing request specs for phases 1-5 and structure commit pass. The only edits are the pinned items listed above (phase 1 `onchange`, the phase 2/3 `badge-*` assertions, the filter-state `.btn-group-toggle`).
- New request specs:
  - `PATCH update_phase2_team` with `Accept: text/vnd.turbo-stream.html` returns `<turbo-stream action="replace">` for the team card, the cascaded swimmer cards and the stepper, and the phase file content is identical to the HTML path's;
  - same for `update_phase3_swimmer`;
  - `POST rebuild_phase` refuses an edited phase without `force`.
- `spec/system/data_fix_review_journey_spec.rb`, run in light and dark themes: on a needs-review fixture,
  1. open Step 3 (needs you only);
  2. fix two swimmers with Next;
  3. save in place (no reload);
  4. edit an event in Step 4;
  5. see the Step 5 stale banner and rebuild;
  6. use Verify all;
  7. open the commit summary and commit;
  8. see the report reach "committed";
  9. follow the link to the Outbox.
- `spec/bs4_leftovers_spec.rb`: zero hits under both Data-Fix folders. A grep spec checks that there is no `onclick=|onchange=|onsubmit=|:javascript` under them.
- Manual check: keyboard navigation, both themes, a 500-swimmer source (page and anchor jumps), a phase 2 save cascading to 30 swimmer cards.

## Exit criteria

- No compat-layer use left under `app/views/data_fix` and `app/components/data_fix` (`bs4_leftovers_spec` allow-list empty for them). No inline handler or inline script left there. `data_fix_helpers.js` and `window.DataFix` are removed.
- The system journey (fix two swimmers, rebuild stale Phase 5, commit summary, commit, report, Outbox) passes in both themes.
- A team save updates its card, the dependent swimmer cards and the stepper without a full page load, and writes the same phase file as before.
- Every step defaults to "needs you only" and has Next/Previous issue navigation.
- Routine gate passes: sign in → board → crawl → review → commit → report → push → confirm.

## Risks and mitigations

- **Hidden coupling between the inline strings and `LegacyAutoCompleteComponent`.** The strings dispatch `change` events on hidden fields, and the component listens. Step 1 keeps the markup, so only the trigger mechanism changes; phases 1-3 request specs and the system journey cover it.
- **Positional card indexes break frame replacement under filters.** Key-based frame ids, with `N` ids kept inside.
- **Cascade fan-out is large** (a team with 40 swimmers). The stream replaces only cards on the current page. Off-page cards are refreshed on navigation, and the stepper counts come from the recomputed verdict.
- **Visual regressions in dense cards.** Convert one step per commit (steps 2-4), each checked in both themes.
- **Turbo-stream flash messages erasing sticky alerts.** Fixed in 03 (separate `#sticky-alerts`); the streams target the toast region only.

## Decisions to confirm

- Keyboard shortcuts `j`/`k` for issue navigation: **default yes**, ignored inside inputs.
- Turbo-frame saves only for phases 2-3 (not 1, 4, 5): **default yes**, per the master plan.
- "Needs you only" default for phases 2-3 when no cookie is set: **default yes**. An explicit `filter_state=none` still wins and is remembered.
- Legacy-only `ResultDetails*Component`s: **default delete** (in 02; here only if still present).

## Out of scope

Logic changes to solvers, verdicts, ReviewRules or the commit runner (09); automation (10); grid chrome and the command palette (15); goggles_db engine partials (scoped compat subset, 03/15).

## Outcome (done, 0.10.92, 2026-11-24)

Delivered on `feature/modernize-admin-console-ux` (steps 1-9 in one pass, shipped as one PATCH; phase 13 was implemented in the same working tree meanwhile). All four decisions confirmed with their defaults (`j`/`k` shortcuts, ignored inside inputs; Turbo-frame saves only for Steps 2-3; "needs you only" default for Steps 2-3 without a cookie, an explicit `filter_state=none` wins and is remembered; the legacy `ResultDetails*Component`s were already gone in 02). No solver, verdict, `ReviewRules` or commit-runner change. The 01 characterization spec `spec/requests/data_fix/phase_orchestration_characterization_spec.rb` passes **unchanged**. Targeted runs only (the full suite is the coordinator's), with a private ops test DB (`OPS_DATABASE_URL=sqlite3:tmp/ops_p12.sqlite3`): Data-Fix requests (incl. `spec/requests/data_fix/**`), components, `spec/services/data_fix`, Data-Fix helper and views, navigation, BS4 ratchet, i18n parity, inline-handler grep, routing, layout assets, season board requests: **544 examples, 0 failures, 1 pending**; after the lint fixes the same set plus all of `spec/components`: **864 examples, 1 failure, 4 pending** (the failure, `spec/requests/data_fix/commits_controller_helpers_spec.rb:289`, category normalization of the source resolver, untouched here, is intermittent: the file alone 26 examples, 0 failures). New spec files: `requests/data_fix/wizard_ux_spec` 13 (16 after the review fixes), `components/data_fix/issue_nav_component_spec` 2, `services/data_fix/issue_nav_spec` 4, `services/data_fix/issue_markers_spec` 3, `helpers/data_fix_helper_spec` 3 (was empty), `data_fix_inline_handlers_spec` 4, `system/data_fix_review_journey_spec` 1; `components/data_fix/stepper_component_spec` 4 → 8. All of `spec/system`: **26 examples, 0 failures** in light and **26, 0** in dark (`SYSTEM_THEME=dark`). Rubocop clean on every Ruby file touched; the new templates are haml-lint clean and every touched template has fewer offenses than before (e.g. `_team_form_card` 52 → 6, `_swimmer_form_card` 41 → 2, `review_results` 39 → 19; `_relay_enrichment_panel` unchanged at 21).

- **Review fixes** (independent read-only review after the first pass; all four findings confirmed against the code and fixed): (1) Step 5 overwrite candidates: `data_fix_overwrite_controller.js` still toggled `bg-light` / `text-muted` while the converted card renders `bg-body-tertiary text-body-secondary` (both `!important`, later in the CSS), so a ticked row never turned red/blue; it now toggles the rendered classes (`IGNORED_ROW_BG` / `IGNORED_ROW_TEXT`), system example in `spec/system/data_fix_spec.rb`; (2) Step 1 "copy pool & city": with "needs you only" the hidden sessions were still offered and `copyFromSibling` copied nothing silently; the select now lists only the rendered sessions (`copy_sources:` local), a hint counts the hidden ones with a "Show all" link (`#copy-from-session-hidden-N`), and `session-card` shows "Copied." / "Nothing copied" (`#copy-from-session-feedback-N`, target `copyFeedback`); request + system examples; (3) a Step 2 save runs `pipeline.harmonize!`, which may add Phase 3 hints to OTHER teams whose cards the stream did not replace: the stream now compares the hints before / after (`TeamsController#conflict_hints_by_key`) and adds a warning toast naming those teams and asking for a reload (`data_fix.flash.team_hints_changed`); their frames are not replaced because their positional ids on the client page (filter, page) are not known server-side; request examples; (4) the debug `console.log` calls of the unused `filter_results_controller.js` removed (its relay check now reads `.data-fix-relay-issue` instead of the former inline border style). After the fixes: the Data-Fix request / component / service / helper / ratchet / parity / inline-handler / navigation set 466 examples, 0 failures; `data_fix_spec`, `data_fix_review_journey_spec`, `pdf_to_data_fix_spec`, `outbox_spec` 9 examples, 0 failures in light and in dark; `wizard_ux_spec` 13 → 16 examples, `data_fix_spec` 4 → 6.
- **Names as shipped.**
  - Stimulus: `meeting_card` (`selectMatch` with the baseline as action param, `copyMeetingId` on the rescan form), `session_card` (`populateFromExisting`, `copyFromSibling`, `selectPool`, `refreshMapsLink`, `cityIdChanged`, `stop`), `team_card` / `swimmer_card` (`selectMatch`, `stop`, baseline value), `event_card` (`populateFromExisting`, `stop`), `verify_team` (`verify`; the panel HTML escapes every value), `issue_nav` (`next`, `previous`, `keydown@window`; values `selector`, `total`, `offset`, `prevUrl`, `nextUrl`, label templates with `__CURRENT__` / `__TOTAL__`); shared module `app/javascript/lib/form_fields.js` (`setFieldValue`, `setCheckboxValue`, `fieldValue`, `dispatchChange`, `copyFieldValue`, `present`, `fetchEntityDetails`, `escapeHtml`), pinned by `pin_all_from 'app/javascript/lib', under: 'lib'`. `data_fix_helpers.js`, its pin and `window.DataFix` are deleted.
  - Ruby: `DataFix::IssueNav` (`single_page`, `for_list(flags, page:, per_page:) { |page, position| url }`, `for_pages(counts, page:) { |page, edge| url }`), `DataFix::IssueMarkers` (`phase1`, `team`, `swimmer`, `phase4`), `DataFix::IssueNavComponent`, `DataFixHelper#data_fix_card_frame_id` / `#data_fix_issue_marker` / `#data_fix_issue_title`; `DataFix::BaseController#data_fix_stepper` (helper), `#data_fix_prepare_state`, `#phase_edit_marker`, `#issues_only_switch`, `#mark_phase_edited_now!`, `#render_flash_stream`; `apply_review_filters(default_filter_state:)` + `@filtered_collection`; `DataFix::SessionsController#rebuild_phase` (`POST data_fix/rebuild_phase`, `data_fix_rebuild_phase_path`); `DataFix::StepperComponent` new params `retry_needed:`, `being_prepared:` (true or the pending `Ops::PipelineRun`), `edit_marker:`, constant `DOM_ID` (`data-fix-stepper`).
  - Views: `data_fix/_team_card_frame`, `_swimmer_card_frame` (key-based frames, `target="_top"`), `_team_scores_card` (`#phase2-team-scores-card`), `_issues_only_toggle` (`#btn-data-fix-issues-only`), `update_phase2_team.turbo_stream.haml`, `update_phase3_swimmer.turbo_stream.haml`; ids `#data-fix-issue-nav`, `#btn-issue-prev`, `#btn-issue-next`, `#data-fix-issue-position`, `#data-fix-retry-needed`, `#data-fix-step-rescan`, `#btn-data-fix-rebuild-phase`, `#btn-data-fix-verify-all`, `#data-fix-being-prepared-progress`. Kept: every pinned id of the plan (`#meeting_search`, the `meeting_*` ids, `div[id^="event-card-"]` + `session_index`/`event_index`, `#frm-add-event` and its row, `#program-card-0`, the Step 5 `button_to commit_phase6_path`, `team-card-N`, `swimmer-card-N`, `*-header-N`, `*-panel-N`, `team_N_*`, `swimmer_N_*`, `fuzzy_select_N`, `#data-fix-being-prepared`, `#data-fix-step-stale|edited|adopted`, `#data-fix-source-changed`).
  - Locales: `config/locales/data_fix_wizard.{en,it}.yml`. The page titles stay "Data-Fix • Step N: Name" in both languages, like the 09 step labels (the request specs pin them).
- **Deviations.**
  - **Team save cascade.** The plan's Step 2 stream also replaces "every swimmer card whose badge team_key matches", but the swimmer cards live on Step 3, never on the teams page (and their positional ids depend on the Step 3 filter): the Step 2 stream replaces the team card, the team ranking card (its "matched team" column, the dependent view on the same page), the stepper and the toasts; the cascaded swimmer badges show when Step 3 opens (the stepper counts come from the recomputed verdicts).
  - **Step 1 "needs you only"** hides only the session cards: the meeting card is always rendered (its id field feeds "rescan sessions").
  - **Step 4 markers** come from the verdict `details` (capped at 20 per issue, as stored) plus the unmatched events when the verdict reports them; Step 5 markers are the programs of the existing issue detector; Steps 2-3 use `ReviewRules.*_in_review_filter?` (the same rows as the "Needs you" filter).
  - **Lap chevron** (`_result_program_card` `onclick`): replaced by a `button` collapse toggle whose chevron turns through CSS (`.data-fix-laps-toggle`), no controller needed.
  - **`rebuild_phase`** lives in `DataFix::SessionsController` next to `discard_phase_edits` (a route needs a concrete controller), not in `BaseController`; it is not in `LEASE_GUARDED_ACTIONS` (the build raises `LeaseBusyError`, shown as the lease warning).
  - **Verify all** is a plain form POST (full redirect back to Step 5 with its filters, the progress modal fed by two progress messages) rather than a Turbo stream of the changed program cards: Turbo-frame saves were confirmed for Steps 2-3 only. `DataFix::ResultVerifier` is unchanged. Hidden on result-free sources and before Phase 5 is populated.
  - **i18n scope**: step labels, titles, banners, buttons, confirmations, filter labels, card badges and the hard-coded flashes of `swimmers_controller` / `teams_controller` / `results_controller` (populate) moved to `data_fix.*`; the form field labels of the cards (attribute names such as `editable_name`) and the English badge texts of the similarity hints (`PHASE3 HINT`, `SIMILAR ROW FOUND`, ...) and of the verify panels stay as they were.
  - **Spec changes beyond the plan's pinned list**: the phase 2/3/5 request specs assert some texts through `I18n.t` now (the specs render in Italian); `spec/system/data_fix_spec.rb` "BS4 → 5 attribute shim" became "native Bootstrap 5 markup and Stimulus wiring" (no `data-toggle` / `data-target` / inline handler on Step 2, `verify-team` wiring, key-based frames).
  - **System journey**: a structure-only source with hand-written, stamped phase files (no result-free Phase 5 auto-rebuild, so the stale banner and `rebuild_phase` are exercised); the Step 4 edit changes the event type (a Phase 5 input: the begin time alone is not one); "Verify all" is covered by the request spec, not by the journey (it is hidden on result-free sources); the interactive progress sink is stubbed (`Import::Progress::Cable` → `Null`): the "ready" broadcasts of the review GETs reach the long-lived ImportStatusChannel subscription and the progress modal would intercept the next click.
  - **Stylesheets**: `[data-page^='data_fix']` dropped from the legacy `.card { overflow: hidden }` list (the result tables now scroll in `.table-responsive`); the unused `.result-detail-card`, `.lap-swimmers`, `.lap-timings` rules removed; `bg-light` / `bg-white` / `table-light` / `text-dark` replaced by `bg-body-tertiary` / `bg-body` / `table-body-tertiary` / `text-body` (the dark-mode issues listed by 04). `app/assets/builds/application.css` rebuilt.
  - **Unused `filter_results_controller.js`** (no view uses it) only had its BS4 class selectors updated, not deleted.
- **For 15**: the grid chrome and the command palette can reuse `issue_nav_controller.js` (any page with `data-issue` markers and an id per marker); `lib/form_fields.js` is the place for shared DOM helpers of other controllers; the remaining BS4 tokens are `app/views/pull` 34, `file_list` 12, `pdf` 11, `app/javascript/controllers` 5 (four of them are the BS5 `{ toggle: false }` Collapse option matched by the ratchet regex, one a comment of `tooltips_controller`), `app/components` 2.
- **Not verified by hand** (no dev server, no real `crawler/data`): a 500-swimmer source (page and anchor jumps across pages), a Step 2 save on a team with many cascaded badges, the step menu dropdown on a narrow screen (Popper `strategy: fixed` inside the scrolling tab list), "Verify all" on real staged results and its progress modal, the "being prepared" progress bar with a running prepare job, the LegacyAutoComplete-driven fills of the session, team and swimmer cards against a live API (the Stimulus actions keep the former handlers' DOM ids and 'change' events; the request specs pin the wiring). Screenshots of Steps 1 and 2 were checked in both themes.

## Rollback note

Each conversion step is one commit per step group and reverts on its own, because phase files and routes are unchanged. Step 7 keeps the HTML redirect path, so dropping the `turbo_stream` templates restores full-page saves. Reverting step 1 means restoring `data_fix_helpers.js` and the importmap pin together with the inline attributes.
