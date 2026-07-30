# Goggles Admin2 Agent Notes

## DataFix V2 canonical source handling

- `DataFixController` maps LT2 inputs to persistent sibling `-lt4.json` working copies via `resolve_working_source_path` and `materialize_lt4_working_copy`.
- Reuse existing LT4 working copies when present; regenerate only when missing.
- Phase review/update/add/delete actions must use the canonical source path and propagate `file_path` in redirects.
- Phase1 fixture sources use `layoutType: 4` to keep existing phase-path assumptions stable.

## Phase 1 DataFix pool/city rehydration

- JS helpers `rehydrateSessionPoolAndCity` and `rehydrateSessionCityFromId` live in `app/javascript/packs/data_fix_helpers.js`.
- `_session_form_card.html.haml` wires the existing-pool dropdown and city hidden-id `onchange` to trigger refresh.
- `Phase1SessionUpdater` detects `swimming_pool.id` changes and overwrites pool/city fields from the DB pool/city, clearing city fields when the selected pool has no city.
- Request specs for rehydrate, city-clear, and stale-city overwrite are in `spec/requests/data_fix_controller_phase1_spec.rb`.
