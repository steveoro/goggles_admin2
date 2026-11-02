---
description: Data-fix write-back policy for Phase 2/3 authoritative IDs
globs:
  - "**/*.rb"
alwaysApply: true
---
# Data-fix write-back policy

- ID integration and coherence must come from Phase 2/3 files.
- Cascades to `data_import` rows must propagate `swimmer_id`, `team_id`, `badge_id`, and `team_affiliation_id` from those phase files.
- DB fallback lookups should happen only during solver/build or explicit refresh, not during late commit-time healing.
  - EXCEPTION (Phase-1 bound entities only): `Import::Committers::SwimmingPool` and `Import::Committers::City` must resolve find-or-create by their DB-level unique natural key (`nick_name`; `(country_code, area, name)`) after the explicit-id lookup misses — this is dedup of a create the committer itself performs, not ID healing. Multiple sessions can legitimately share one new pool/city (`id: null`) and the unique index would reject the second INSERT, rolling back the whole commit.
- A null ID alone is not an issue if the entity is new/creatable and its key data is coherent.
- Unknown gender or year of birth are issues.
- Prefer maximum coherence with stable first-defined keys; allow canonical full-key usage when available during gathering. Follow any existing late-key upgrade mechanism if present and ensure propagation consistency.
