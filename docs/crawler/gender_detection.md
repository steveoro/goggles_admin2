---
description: Gender detection and swimmer key format in the Microplus crawler
---

# Gender Detection & Swimmer Key Format

This document describes how the Microplus crawler handles gender detection for events and swimmers, including the key format used for swimmer identification.

## Swimmer Key Format

Swimmer keys are pipe-delimited identifiers used throughout the crawler output:

| Scenario | Format | Example |
|----------|--------|---------|
| **Known gender** | `G\|LAST\|FIRST\|YOB\|TEAM` | `F\|ROSSI\|Maria\|1980\|TeamA` |
| **Unknown gender** | `\|LAST\|FIRST\|YOB\|TEAM` | `\|VERDI\|Anna\|1990\|TeamC` |

### Key Properties

- **5 tokens** when split by `|` (first token is gender or empty)
- **Leading pipe** indicates unknown/missing gender
- Gender is normalized: only `'M'` or `'F'` are stored; `'X'`, `'N/A'`, or unknown → empty string in key

### Implementation

```javascript
// utility.js - createSwimmerKey()
// Known gender: "F|ROSSI|Maria|1980|TeamA"
// Unknown:      "|VERDI|Anna|1990|TeamC"
const key = `${gender}|${lastName}|${firstName}|${year}|${team}`;
```

## Gender Values by Context

| Context | Valid Values | Notes |
|---------|--------------|-------|
| **Event gender** (`eventGender`) | `'M'`, `'F'`, `'X'`, `''` | `'X'` only valid for relay events |
| **Swimmer gender** (in object) | `'M'`, `'F'`, `null` | Never `'X'`; stored as `null` if unknown |
| **Swimmer key** (prefix) | `'M'`, `'F'`, `''` | Empty string (leading pipe) if unknown |

## Gender Detection Priority

The crawler uses a multi-level fallback strategy:

### 1. Event List Page (Primary)

Extracts gender from `td.GaraRound.aCenter` cells in the event calendar:
- `"FEMMINE"` → `'F'`
- `"MASCHI"` → `'M'`
- `"MISTO"` / `"MISTI"` → `'X'` (relays only)

### 2. Event Header Fallback

If event list detection fails, extracts from `#tdGaraRound` in RISULTATI/RIEPILOGO pages:
- `"FEMMINE - 50 M STILE LIBERO"` → `'F'`
- `"MASCHI - 100 M RANA"` → `'M'`

### 3. Category Header Fallback

If still unknown, infers from RIEPILOGO category headers:
- `"MASTER 80F"` → `'F'`
- `"MASTER 95M"` → `'M'`

## Helper Functions

### `extractGenderFromEventHeader(headerText)`

Parses event header text to extract gender code.

```javascript
CrawlUtil.extractGenderFromEventHeader("FEMMINE - 50 M STILE LIBERO")
// Returns: 'F'
```

### `extractGenderFromCategoryHeader(categoryText)`

Parses category header to extract gender from trailing letter.

```javascript
CrawlUtil.extractGenderFromCategoryHeader("MASTER 80F")
// Returns: 'F'
```

## Mixed Relay Handling

For mixed-gender relay events (`eventGender: 'X'`):

1. **Event** keeps `eventGender: 'X'`
2. **Individual swimmers** get `gender: null` (not `'X'`)
3. **Swimmer keys** have leading pipe: `"|LAST|FIRST|YOB|TEAM"`
4. The crawler attempts to reuse existing gendered keys if the swimmer was seen in a single-gender event

## Rails Integration

The `SwimmerSolver` in Rails (Phase 4/5) handles unknown genders:

- Uses fuzzy matching to find existing swimmers
- High-confidence matches (≥90%) can infer gender from database
- Sets `gender_guessed: true` flag when gender is inferred

## Debugging

Set `MICROPLUS_DEBUG=1` to enable verbose gender detection logging:

```bash
MICROPLUS_DEBUG=1 node crawler/server/index.js
```

Logs include:
- Original and normalized gender strings
- Fallback detection attempts
- Final resolved gender values
