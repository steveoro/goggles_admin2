# Data-Fix: Data Structures Reference

**Last Updated**: 2025-11-15  
**Version**: 2.1

This document provides comprehensive reference for all data structures used in the Data-Fix pipeline, from source JSON through phase files to database tables.

---

## Table of Contents

1. [Source Data Formats](#source-data-formats)
2. [Phase File Structures](#phase-file-structures)
3. [Temporary Database Tables](#temporary-database-tables)
4. [Production Database Entities](#production-database-entities)
5. [Import Keys](#import-keys)
6. [Quick Reference](#quick-reference)

---

## Source Data Formats

### Layout Type 4 (LT4) - Microplus Format

The primary source format used by the Microplus timing system.

#### Individual Result Structure
```json
{
  "sections": [
    {
      "title": "200 m Stile Libero - M45",
      "fin_sigla_categoria": "M45",
      "fin_sesso": "M",
      "rows": [
        {
          "pos": "1",
          "name": "ROSSI MARIO",
          "year_of_birth": "1978",
          "team": "CSI OBER FERRARI",
          "timing": "2'05.45",
          "std_score": "812,45",
          "laps": [
            {"distance": "50m", "timing": "28.45"},
            {"distance": "100m", "timing": "30.12"},
            {"distance": "150m", "timing": "31.88"},
            {"distance": "200m", "timing": "35.00"}
          ]
        }
      ]
    }
  ]
}
```

**Field Reference**:
- `title`: Event description (Italian format)
- `fin_sigla_categoria`: FIN category code (e.g., "M45", "U25")
- `fin_sesso`: Gender code ("M", "F", "X" for mixed)
- `pos`: Ranking position or status ("SQ", "RT", "NP")
- `name`: Swimmer full name (UPPERCASE)
- `year_of_birth`: 4-digit year
- `team`: Team name (as appears on results)
- `timing`: Final time in format "M'SS.hh" or "SS.hh"
- `std_score`: FIN standard points (optional)
- `laps`: Array of split times

#### Relay Result Structure
```json
{
  "sections": [
    {
      "title": "4x50 m Misti - M320",
      "fin_sigla_categoria": "M320",
      "fin_sesso": "X",
      "rows": [
        {
          "pos": "1",
          "relay": true,
          "team": "DLF Nuoto Livorno",
          "timing": "4'07.25",
          "swimmer1": "CORTI Delia",
          "year_of_birth1": "1938",
          "gender_type1": null,
          "swimmer2": "PAGLI Linda",
          "year_of_birth2": "1950",
          "gender_type2": "F",
          "swimmer3": "FRATTINI Emilio",
          "year_of_birth3": "1946",
          "gender_type3": "M",
          "swimmer4": "BECCHETTI Romolo",
          "year_of_birth4": "1946",
          "gender_type4": null,
          "laps": [
            {
              "distance": "50m",
              "delta": "1'46.01",
              "swimmer": "CORTI|Delia|1938|DLF Nuoto Livorno"
            },
            {
              "distance": "100m",
              "delta": "1'02.46",
              "swimmer": "F|PAGLI|Linda|1950|DLF Nuoto Livorno"
            },
            {
              "distance": "150m",
              "delta": "40.49",
              "swimmer": "M|FRATTINI|Emilio|1946|DLF Nuoto Livorno"
            },
            {
              "distance": "200m",
              "delta": "38.29",
              "swimmer": "BECCHETTI|Romolo|1946|DLF Nuoto Livorno"
            }
          ]
        }
      ]
    }
  ]
}
```

**Relay-Specific Fields**:
- `relay`: Boolean flag (always `true` for relay rows)
- `swimmer1` through `swimmer8`: Relay leg swimmer names
- `year_of_birth1` through `year_of_birth8`: Birth years for each leg
- `gender_type1` through `gender_type8`: Gender codes (may be null)
- `laps[].swimmer`: Pipe-separated format with 2 variants:
  - **With gender**: `"GENDER|LAST|FIRST|YEAR|TEAM"` (5 tokens)
  - **Without gender**: `"LAST|FIRST|YEAR|TEAM"` (4 tokens)
- `laps[].delta`: Lap time (not cumulative)

**Important Notes**:
- Gender in lap data may be prefixed (e.g., `"F|PAGLI|Linda..."`) or missing
- The system handles both 4-token and 5-token lap swimmer formats
- Relay category codes like "M320" represent sum of ages (4 swimmers × ~80 years avg)

### Layout Type 2 (LT2) - Legacy Format

Older format still used by some timing systems.

```json
{
  "category": "M45",
  "results": [
    {
      "rank": 1,
      "swimmer_name": "ROSSI MARIO",
      "year": 1978,
      "team_name": "CSI OBER FERRARI",
      "time": "2:05.45",
      "splits": ["28.45", "30.12", "31.88", "35.00"]
    }
  ]
}
```

**Key Differences from LT4**:
- Simpler structure
- Less metadata
- No embedded swimmer keys in laps
- Requires more parsing logic

---

## Phase File Structures

All phase files share a common metadata structure:

```json
{
  "_meta": {
    "schema_version": "1.0",
    "created_at": "2025-11-15T10:00:00Z",
    "generator": "Import::Solvers::Phase3Solver",
    "source_path": "/path/to/source.json",
    "parent_checksum": "abc123...",
    "layoutType": 4
  },
  "data": {
    // Phase-specific data here
  }
}
```

### Phase 1: Meeting & Sessions

```json
{
  "_meta": { /* ... */ },
  "data": {
    "season_id": 242,
    "name": "Campionati Italiani di Nuoto Master",
    "code": "regit",
    "header_date": "2025-06-24",
    "id": 12345,
    "meeting_fuzzy_matches": [
      {
        "id": 12345,
        "description": "Campionati Italiani 2025",
        "score": 0.95
      }
    ],
    "meeting_session": [
      {
        "id": 5678,
        "session_order": 1,
        "scheduled_date": "2025-06-24",
        "day_part_type_id": 1,
        "swimming_pool": {
          "id": 22,
          "name": "Stadio Nuoto",
          "nick_name": "riccionestadio50",
          "pool_type_id": 2,
          "lanes_number": 10,
          "city": {
            "id": 38,
            "name": "Riccione",
            "zip": "47838",
            "country_code": "IT"
          }
        }
      }
    ]
  }
}
```

**Required Fields**:
- `season_id`: Must match active season
- `name`: Meeting name
- `header_date`: Meeting start date (YYYY-MM-DD)

**Resolved IDs**:
- `id`: Meeting ID (if matched)
- `meeting_session[].id`: Session IDs
- `swimming_pool.id`: Pool ID
- `city.id`: City ID

### Phase 2: Teams & Affiliations

```json
{
  "_meta": { /* ... */ },
  "data": {
    "season_id": 242,
    "teams": [
      {
        "key": "CSI OBER FERRARI",
        "name": "CSI OBER FERRARI",
        "editable_name": "CSI Ober Ferrari",
        "team_id": 123,
        "city_id": 38,
        "name_variations": 5,
        "fuzzy_matches": [
          {
            "id": 123,
            "complete_name": "CSI OBER FERRARI",
            "score": 0.98,
            "auto_assigned": true
          }
        ]
      }
    ],
    "team_affiliations": [
      {
        "team_key": "CSI OBER FERRARI",
        "team_id": 123,
        "season_id": 242,
        "team_affiliation_id": 456,
        "name": "CSI OBER FERRARI",
        "number": "01234"
      }
    ]
  }
}
```

**Key Concepts**:
- `key`: Unique identifier within phase file (usually uppercase team name)
- `team_id`: Matched Team record ID
- `team_affiliation_id`: Pre-matched TeamAffiliation ID (if exists)
- `name_variations`: Count of different name formats found in source

### Phase 3: Swimmers & Badges

```json
{
  "_meta": { /* ... */ },
  "data": {
    "season_id": 242,
    "swimmers": [
      {
        "key": "ROSSI|MARIO|1978",
        "last_name": "ROSSI",
        "first_name": "MARIO",
        "complete_name": "ROSSI MARIO",
        "year_of_birth": 1978,
        "gender_type_code": "M",
        "swimmer_id": 789,
        "fuzzy_matches": [
          {
            "id": 789,
            "complete_name": "ROSSI MARIO",
            "year_of_birth": 1978,
            "gender_type_code": "M",
            "weight": 0.98,
            "percentage": 98.0
          }
        ]
      }
    ],
    "badges": [
      {
        "swimmer_key": "ROSSI|MARIO|1978",
        "team_key": "CSI OBER FERRARI",
        "swimmer_id": 789,
        "team_id": 123,
        "season_id": 242,
        "category_type_id": 1425,
        "badge_id": 999
      }
    ]
  }
}
```

**Swimmer Key Format**: `"LAST|FIRST|YEAR"`
- All uppercase
- Pipe-separated
- Year is 4-digit

**Pre-Calculated Fields**:
- `category_type_id`: Calculated from age at meeting date
- `badge_id`: Pre-matched existing Badge (if found)

**Required Fields for New Swimmers**:
- `last_name` OR `first_name` (at least one)
- `year_of_birth` (4-digit year, > 0)
- `gender_type_code` ("M" or "F")

### Phase 4: Events

```json
{
  "_meta": { /* ... */ },
  "data": {
    "season_id": 242,
    "sessions": [
      {
        "session_order": 1,
        "meeting_session_id": 5678,
        "events": [
          {
            "key": "200SL-M45",
            "event_code": "200SL",
            "distance": 200,
            "stroke": "SL",
            "relay": false,
            "category": "M45",
            "gender": "M",
            "event_type_id": 15,
            "meeting_event_id": 1234
          },
          {
            "key": "S4X50MI-F",
            "event_code": "S4X50MI",
            "distance": 200,
            "stroke": "MI",
            "relay": true,
            "category": null,
            "gender": "F",
            "event_type_id": 26,
            "meeting_event_id": 1235
          }
        ]
      }
    ]
  }
}
```

**Event Codes**:
- Individual: `"<distance><stroke>"` (e.g., "200SL", "100DO")
- Relay (same-gender): `"S4X<leg_distance><stroke>"` (e.g., "S4X50MI")
- Relay (mixed): `"M4X<leg_distance><stroke>"` (e.g., "M4X50SL")

**Stroke Codes**:
- `SL`: Freestyle (Stile Libero)
- `DO`: Backstroke (Dorso)
- `RA`: Breaststroke (Rana)
- `FA`: Butterfly (Farfalla / Delfino)
- `MI`: Medley (Misti)

**Pre-Matched Fields**:
- `event_type_id`: Matched EventType record
- `meeting_event_id`: Pre-matched MeetingEvent (if exists)

### Phase 5: Results Summary

Phase 5 produces a **summary JSON** plus **detailed DB tables**.

#### Phase5.json (Summary)
```json
{
  "_meta": { /* ... */ },
  "data": {
    "season_id": 242,
    "result_counts": {
      "individual": 1543,
      "relay": 47
    },
    "sessions": [
      {
        "session_order": 1,
        "events": [
          {
            "event_code": "200SL",
            "relay": false,
            "results_by_category": {
              "M45": 23,
              "M50": 18,
              "M55": 15
            }
          }
        ]
      }
    ]
  }
}
```

---

## Temporary Database Tables

Phase 5 populates temporary tables for review. These tables are defined in `goggles_db` gem v0.8.11+.

### Individual Results

#### `data_import_meeting_individual_results`

**Purpose**: Stores individual result headers (one per swimmer per event)

```ruby
{
  import_key: "regit-1-200SL-ROSSI|MARIO|1978",
  phase_file_path: "/path/to/source.json",
  
  # Resolved IDs from phases 1-4
  meeting_id: 12345,
  meeting_session_id: 5678,
  meeting_program_id: 2345,
  
  # Swimmer/Team from phase 3
  swimmer_id: 789,
  badge_id: 999,
  team_id: 123,
  team_affiliation_id: 456,
  
  # Result details
  rank: 1,
  is_play_off: false,
  is_out_of_race: false,
  is_disqualified: false,
  standard_points: "812.45",
  meeting_points: 950.5,
  
  # Timing
  minutes: 2,
  seconds: 5,
  hundredths: 45,
  
  # Display fields
  swimmer_name: "ROSSI MARIO",
  team_name: "CSI OBER FERRARI",
  category_code: "M45",
  
  # Metadata
  created_at: "2025-11-15 10:00:00",
  updated_at: "2025-11-15 10:00:00"
}
```

**Key Fields**:
- `import_key`: Unique identifier for O(1) lookups
- `meeting_program_id`: Links to specific event+category+gender combination
- `swimmer_id` + `badge_id`: Fully resolved swimmer identity
- `is_disqualified`: Status flags (RT, SQ, NP)

#### `data_import_laps`

**Purpose**: Stores individual lap splits (4-8 per result)

```ruby
{
  data_import_meeting_individual_result_id: 111,
  
  # Lap details
  length_in_meters: 50,
  lap_order: 1,
  reaction_time: "0.67",
  
  # Timing
  minutes: 0,
  seconds: 28,
  hundredths: 45,
  
  # Cumulative timing
  minutes_from_start: 0,
  seconds_from_start: 28,
  hundredths_from_start: 45,
  
  # Metadata
  created_at: "2025-11-15 10:00:00",
  updated_at: "2025-11-15 10:00:00"
}
```

**Lap Order**:
- Starts at 1
- Increments for each lap
- Length typically 50m or 100m depending on pool

**Timing Fields**:
- Individual lap time: `minutes`, `seconds`, `hundredths`
- Cumulative time: `minutes_from_start`, `seconds_from_start`, `hundredths_from_start`

### Relay Results

#### `data_import_meeting_relay_results`

**Purpose**: Stores relay result headers (one per team per relay event)

```ruby
{
  import_key: "regit-1-S4X50MI-DLF Nuoto Livorno-F",
  phase_file_path: "/path/to/source.json",
  
  # Resolved IDs
  meeting_id: 12345,
  meeting_session_id: 5678,
  meeting_program_id: 2346,
  
  # Team
  team_id: 124,
  team_affiliation_id: 457,
  
  # Result details
  rank: 1,
  is_play_off: false,
  is_out_of_race: false,
  is_disqualified: false,
  standard_points: "925.00",
  meeting_points: 1000.0,
  
  # Timing
  minutes: 4,
  seconds: 7,
  hundredths: 25,
  
  # Display fields
  team_name: "DLF Nuoto Livorno",
  category_code: "M320",
  
  # Metadata
  created_at: "2025-11-15 10:00:00",
  updated_at: "2025-11-15 10:00:00"
}
```

**Key Differences from Individual**:
- Team-based (no swimmer_id/badge_id)
- Multiple swimmers linked via separate table
- Category code represents sum of ages

#### `data_import_relay_swimmers`

**Purpose**: Links swimmers to relay results (4 swimmers per relay)

```ruby
{
  data_import_meeting_relay_result_id: 222,
  
  # Swimmer identity
  swimmer_id: 17724,
  badge_id: 98765,
  
  # Leg details
  relay_order: 1,
  stroke_type_id: 3,
  
  # Timing (for this leg only)
  minutes: 1,
  seconds: 46,
  hundredths: 1,
  
  # Cumulative timing
  minutes_from_start: 1,
  seconds_from_start: 46,
  hundredths_from_start: 1,
  
  # Metadata
  reaction_time: "0.42",
  length_in_meters: 50,
  created_at: "2025-11-15 10:00:00",
  updated_at: "2025-11-15 10:00:00"
}
```

**Relay Order**:
- 1-4 for 4x50m, 4x100m, 4x200m relays
- Determines leg sequence

**Stroke Type ID**:
- For medley relays, each leg has different stroke
- For freestyle relays, all legs use same stroke

#### `data_import_relay_laps`

**Purpose**: Stores lap splits within each relay leg

```ruby
{
  data_import_relay_swimmer_id: 333,
  
  # Lap details
  length_in_meters: 50,
  lap_order: 1,
  
  # Timing (for this lap)
  minutes: 0,
  seconds: 52,
  hundredths: 30,
  
  # Cumulative timing (within this leg)
  minutes_from_start: 0,
  seconds_from_start: 52,
  hundredths_from_start: 30,
  
  # Metadata
  created_at: "2025-11-15 10:00:00",
  updated_at: "2025-11-15 10:00:00"
}
```

**Note**: For 50m relays, typically only 1 lap per swimmer

---

## Production Database Entities

### Individual Result Chain

```
Meeting
  └── MeetingSession
        └── MeetingEvent (+ EventType)
              └── MeetingProgram (+ CategoryType + GenderType)
                    └── MeetingIndividualResult (+ Swimmer + Badge + Team)
                          └── Lap (1-8 per result)
```

### Relay Result Chain

```
Meeting
  └── MeetingSession
        └── MeetingEvent (+ EventType with relay=true)
              └── MeetingProgram (+ CategoryType + GenderType)
                    └── MeetingRelayResult (+ Team)
                          └── MeetingRelaySwimmer (+ Swimmer + Badge + StrokeType)
                                └── RelayLap (1+ per swimmer)
```

---

## Import Keys

Import keys provide O(1) lookups in temporary tables. Format:

### Individual Results
```
"<meeting_code>-<session_order>-<event_code>-<swimmer_key>"
Example: "regit-1-200SL-ROSSI|MARIO|1978"
```

### Relay Results
```
"<meeting_code>-<session_order>-<event_code>-<team_name>-<gender>"
Example: "regit-1-S4X50MI-DLF Nuoto Livorno-F"
```

### Relay Swimmers
```
"<relay_import_key>-<relay_order>"
Example: "regit-1-S4X50MI-DLF Nuoto Livorno-F-1"
```

---

## Quick Reference

### File Paths
```
Source JSON:     crawler/data/results.new/<season_id>/<filename>.json
Phase 1:         crawler/data/results.new/<season_id>/<filename>-phase1.json
Phase 2:         crawler/data/results.new/<season_id>/<filename>-phase2.json
Phase 3:         crawler/data/results.new/<season_id>/<filename>-phase3.json
Phase 4:         crawler/data/results.new/<season_id>/<filename>-phase4.json
Phase 5:         data_import_* DB tables
SQL Log:         crawler/data/sql.new/<season_id>/<filename>.sql
Completed:       crawler/data/results.done/<season_id>/<filename>.json
```

### Common Field Mappings

| Source Field | Phase File | DB Table | Production Entity |
|--------------|------------|----------|-------------------|
| `name` | `swimmer_key` | `swimmer_name` | `Swimmer.complete_name` |
| `team` | `team_key` | `team_name` | `Team.name` |
| `timing` | (parsed) | `minutes/seconds/hundredths` | Same |
| `year_of_birth` | `year_of_birth` | N/A | `Swimmer.year_of_birth` |
| `fin_sigla_categoria` | `category` | `category_code` | `CategoryType.code` |

### Status Codes

| Code | Meaning | Flag |
|------|---------|------|
| Rank 1-999 | Normal placement | `is_out_of_race: false` |
| "SQ" | Disqualified | `is_disqualified: true` |
| "RT" | Retired | `is_out_of_race: true` |
| "NP" | Did Not Participate | `is_out_of_race: true` |

### Gender Codes

| Code | Description | Used In |
|------|-------------|---------|
| "M" | Male | Individual events |
| "F" | Female | Individual events |
| "X" | Mixed | Relay events only |

---

**For Implementation Details**, see:
- [README.md](./README.md) - Main index
- [PHASES.md](./PHASES.md) - Phase-by-phase guide
- [TECHNICAL.md](./TECHNICAL.md) - Architecture patterns
- [RELAY_IMPLEMENTATION.md](./RELAY_IMPLEMENTATION.md) - Relay-specific implementation

**Last Updated**: 2025-11-15 by Steve A. (Leega)
