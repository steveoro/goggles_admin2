---
description: Phase 1 DataFix session pool/city rehydration behavior
globs:
  - "app/javascript/packs/data_fix_helpers.js"
  - "app/**/data_fix*/**"
  - "spec/requests/data_fix*"
alwaysApply: true
---
# Phase 1 DataFix pool/city rehydration

When a `swimming_pool_id` changes in a DataFix V2 Phase 1 session edit:

- Rehydrate all pool and city fields immediately in JavaScript before save.
- Overwrite manual edits with the selected pool/city data.
- If the selected pool has no city, clear all city fields.
