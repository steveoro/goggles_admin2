---
description: Microplus relay payload structure
---

# Microplus relay JSON payload overview

These notes capture the structure currently emitted by the layout-4 Microplus crawler (`crawler/server/microplus-crawler.js`). The payload is generated before any Phase processing and is the single source for relay data in Phase 3+ workflows.

## Top-level shape

Each crawl produces a single JSON object with:

- Meeting metadata fields (`name`, `meetingURL`, `dateYear1/2`, `venue1`, `season_id`, ...)
- `layoutType` (set by crawler)
- `sections`: array grouping results by relay category (gender + age bucket)

```jsonc
{
  "name": "Campionati Italiani di Nuoto Master Herbalife",
  "season_id": 242,
  "sections": [
    {
      "title": "4x50 m Misti - M80",
      "fin_sesso": "F",
      "fin_sigla_categoria": "M80",
      "rows": [ /* relay rows */ ]
    }
  ]
}
```

## Relay rows

Every row inside `sections[].rows[]` is marked with `relay: true` and contains four swimmer slots. Swimmers are expanded inline; the crawler guarantees string values.

| Field | Notes |
| --- | --- |
| `pos` | Ranking position string (e.g., "1") |
| `team` | Relay team/club name |
| `timing` | Final timing string |
| `swimmer1..4` | Full name for each leg |
| `year_of_birth1..4` | YOB per leg |
| `gender_type1..4` | Gender code per leg ("M"/"F") |
| `laps` | Array of leg splits (see below) |
| `delta50/100/150/200` | Optional per-leg cumulative splits (present in freestyle crawls) |

### Lap entries

The crawler emits lap arrays with distances and deltas keyed by a composite swimmer identifier:

```jsonc
"laps": [
  { "distance": "50m",  "delta": "27.82", "swimmer": "F|DE PIERI|Giorgia|2003|ssd Stilelibero - Preganz" },
  { "distance": "100m", "delta": "28.38", "swimmer": "F|MINTO|Giovanna|2003|ssd Stilelibero - Preganz" }
]
```

The `swimmer` string follows `G|LAST|First|YOB|Team` format:
- Known gender: `"F|ROSSI|Maria|1980|TeamA"` or `"M|BIANCHI|Marco|1975|TeamB"`
- Unknown gender: `"|VERDI|Anna|1990|TeamC"` (leading pipe indicates unknown)

This matches the identifier stored in `allResults.swimmers` within the crawler pipeline. For mixed relays (`eventGender: 'X'`), individual swimmer gender is set to `null` and the key has a leading pipe.

## Known payload variants

| File | Sessions | Row count (section 0) | Notes |
| --- | --- | --- | --- |
| `...-4X50MI-l4.json` | 23 | 22 | Mixed relay; no `deltaXX` fields |
| `...-4X50SL-l4.json` | 23 | 24 | Freestyle relay; includes `delta50/100/150/200` |

Both payloads share the `relay: true` flag, per-leg swimmer metadata, and lap arrays. Downstream Phase 3 enrichment logic can assume:

1. Exactly four swimmer slots per row.
2. `year_of_birth#`/`gender_type#` may be blank and need filling.
3. Lap `swimmer` keys can be split on `|` to recover leg attributes.

## Next steps

- Phase 3: detect incomplete relay swimmers using `year_of_birth#`/`gender_type#` presence and cached swimmer IDs.
- Phase 3 UI: surface auxiliary Phase 3 file merge when gaps exist.
- Phase 5: reuse the lap `swimmer` key for RelayLap normalization.
