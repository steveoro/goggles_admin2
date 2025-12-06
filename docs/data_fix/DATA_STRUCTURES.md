# Data-Fix: Data Structures Reference

Comprehensive reference for most data structures used in the Data-Fix pipeline, from source JSON through phase files to database tables.

**Last Updated**: 2025-11-24
**Version**: 3.0

---


## Source Data Formats

### Layout Type 4 (LT4) - Microplus Format

The primary source format used by the Microplus timing system.

#### Individual Result Structure

- events[] -> 1 object per event, containing event details, gender and category, each in dedicated fields
- in each event: results[] -> 1 object per result, usually containing lap data
- in each result: laps[] -> 1 object per lap data, present only if eventLength (in meters) > 50

Hierarchical structure can be examined using our custom script `bin/json_tree_viewer.py`.
Example output:

```
$ bin/json_tree_viewer.py crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-800SL-l4.json

# (Output corrected as the script mistakes hyphenated names as field-separated keys; in any case it works perfectly as a quick reference to the tree structure in the datafile)

[root]
     +--- competitionType
     +--- dates
     +--- events
     |   +--- [0]
     |       +--- eventCode
     |       +--- eventDescription
     |       +--- eventGender
     |       +--- eventLength
     |       +--- eventStroke
     |       +--- relay
     |       +--- results
     |           +--- [0]
     |               +--- category
     |               +--- heat
     |               +--- heat_position
     |               +--- lane
     |               +--- laps
     |               |   +--- [0]
     |               |       +--- delta
     |               |       +--- distance
     |               |       +--- position
     |               |       +--- timing
     |               +--- nation
     |               +--- ranking
     |               +--- swimmer
     |               +--- team
     |               +--- timing
     +--- layoutType
     +--- meetingName
     +--- meetingURL
     +--- place
     +--- seasonId
     +--- swimmers
     |   +--- "<fld1>|<fld2>|<fld3>|<fld4>|<fld5>" (ex.: "F|MARCA|Rossi|1949|Swimmo Sporting Club")
     |       +--- category
     |       +--- firstName
     |       +--- gender
     |       +--- lastName
     |       +--- team
     |       +--- year
     +--- teams
     |   +--- "<fld1>" (ex.: "Swimmo Sporting Club")
     |   |   +--- name
     +--- title
```

---

#### Relay Result Structure

Same hierarchical structure as LT4 individual results, with the only major difference being that the swimmer key may not have the leading gender when only relay results are crawled (i.e., the gender prefix field is omitted from the swimmer key).

These "incomplete" swimmer dictionaries may be integrated during the data-fix procedure using information from the swimmers section from other data-files crawled from the same competition (e.g.,from individual results data files).

```
$ bin/json_tree_viewer.py crawler/data/results.new/242/2025-06-24-Campionati_Italiani_di_Nuoto_Master_Herbalife-4X50MI-l4.json
[root]
     +--- competitionType
     +--- dates
     +--- events
     |   +--- [0]
     |       +--- eventCode
     |       +--- eventDescription
     |       +--- eventGender
     |       +--- eventLength
     |       +--- eventStroke
     |       +--- relay
     |       +--- results
     |           +--- [0]
     |               +--- category
     |               +--- heat
     |               +--- heat_position
     |               +--- lane
     |               +--- laps
     |               |   +--- [0]
     |               |       +--- delta
     |               |       +--- distance
     |               |       +--- swimmer
     |               +--- ranking
     |               +--- relay
     |               +--- relay_name
     |               +--- team
     |               +--- timing
     +--- layoutType
     +--- meetingName
     +--- meetingURL
     +--- place
     +--- seasonId
     +--- swimmers
     |   +--- "<fld1>|<fld2>|<fld3>|<fld4>" (ex.: "FRISCO|Frengo|1938|Johnny Swimmer Klub" - if the gender is missing or unknown, the total number of fields is 4)
     |   |   +--- firstName
     |   |   +--- gender
     |   |   +--- lastName
     |   |   +--- team
     |   |   +--- year
     |   +--- "<fld1>|<fld2>|<fld3>|<fld4>|<fld5>" (ex.: "F|FRISCO|Frenga|2002|G.P. Super Cup" - when the gender is known, 5 fields in total)
     |       +--- firstName
     |       +--- gender
     |       +--- lastName
     |       +--- team
     |       +--- year
     +--- teams
     |   +--- "<fld1>" (ex.: "G.P. Nuoto Mira")
     |   |   +--- name
     +--- title
```


---


### Layout Type 2 (LT2) - FIN result crawler

Usually created by the FIN result crawler, these are also generated from parsing PDF result files.

Note that the legacy data-fix process usually handles the following raw structure, but after each step, it appends to the same data file its own arrays of serialized entities as additional keys under the same root object. This inevitable will alter the source file making it extremely large and difficult to manage for competitions with many events and results.

(Example: step 2 will add to the root object the "team" key - note the singular - pointing to the dictionary of serialized team entities reviewed by the operator; step 3 will add the "swimmer" dictionary, and so on...)


#### Individual Result Structure

- sections[] -> 1 section per event, section header with event details, gender and category
- rows[] -> 1 row per result, usually lap data is missing

*Concrete example:*

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


---


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
  play_off: false,
  out_of_race: false,
  disqualified: false,
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
- `disqualified`: Status flags (RT, SQ, NP)

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
  play_off: false,
  out_of_race: false,
  disqualified: false,
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

### Status Codes

| Code | Meaning | Flag |
|------|---------|------|
| Rank 1-999 | Normal placement | `out_of_race: false` |
| "SQ" | Disqualified | `disqualified: true` |
| "RT" | Retired | `out_of_race: true` |
| "NP" | Did Not Participate | `out_of_race: true` |

### Gender Codes

| Code | Description | Used In |
|------|-------------|---------|
| "M" | Male | Individual events |
| "F" | Female | Individual events |
| "X" | Mixed | Relay events only |
