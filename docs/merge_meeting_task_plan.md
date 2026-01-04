# Subject: new meeting merge task
- Container project: Goggles Admin 2 (project `goggles_admin2`)
- Reference schema: db/schema.rb
- Models from Rails engine, project `goggles_db`

## Overview
This new task will create a new rake command to merge two Meeting instances belonging to the same Season.
The source meeting's data will be transferred to the destination meeting, creating any missing linked entities rows or updating existing ones, while ensuring no duplicate records are created.

Meetings have several tied relationships with other entities like teams, events, and results that need to be properly handled during the merge process, so this will result in a complex operation that will span several tables but that NEEDS TO BE WRAPPED IN A SINGLE TRANSACTION, so that in case of conflicts or errors, the entire operation can be rolled back.

## Specifications
1. Single transaction for the entire merge operation, with fail-fast in case of errors.

2. Validate that both meetings exist and belong to the same season; abort or exit if not.

3. Support for a "simulate" parameter default mode, that will run the entire merge process but will not actually perform any changes to the DB. See, for example, the `merge:swimmer` task for a reference implementation: @merge.rake#L35-101. It's strongly advised to use dedicated strategy classes for each step of the process so that they can be tested in isolation and then use a combined strategy class to wrap the entire process like in `app/strategies/merge/swimmer.rb` and `app/strategies/merge/swimmer_checker.rb` for example.

4. Log each query run into an SQL script file that reproduces the whole transaction, so that it can be reproduced on another DB replica or restored backup dump; again as above, take inspiration from the logging pattern already used in the existing merger strategy classes like `app/strategies/merge/badge.rb`, `app/strategies/merge/swimmer.rb` or `app/strategies/merge/team.rb`.

5. Source meeting should be merged in any way into the destination, creating any missing linked entity record row or updating any existing row found. Don't overwrite non-zero or non-empty destination columns with source zero or empty string values. Typical example: MIR's `standard_points` or any non-zero numeric field present in destination, but missing (or zero) from source. Overwrite destination with source *only* if the values are different or if the destination is empty/zero. (See also points 8. and 9. below.). The merge goal can be achieved by:
  - 5.1. "Moving", that is, re-assigning any missing linked entity row to the destination meeting's parent entity if the parent entity is the deemed to be the same or "equal" (in the sense of representing the same event or result; more on comparison checking in point 9. below).
    - Example: a source MIR belonging to the same program event type but missing from the destination meeting program's results, can be moved to the destination meeting by changing its `meeting_program_id` link to the destination meeting program's ID (once the destination meeting program has been processed and consolidated).
  - 5.2. Updating any existing linked entity destination row found to match the source meeting's data type (same program type, same swimmer, same team but different timing or other columns).
  - 5.3. Removing any duplicate source row after it has been merged into a valid destination row. (See point 6. below for more details.)
  - 5.4. The order of processing should start top-most in the hierarchy chain of dependencies (which is the inverse of the bottom-up order of point 6. below, needed for the deletion phase):
    - 5.4.1. Calendar, Meeting, MeetingSession, MeetingEvent, MeetingProgram; (branches to 5.4.2, 5.4.3 and 5.4.4 depending on references in children entities)
    - 5.4.2. MeetingIndividualResult, Lap; (deletion of duplicates can occur at this point, see point 6. below)
    - 5.4.3. MeetingRelayResult, MeetingRelaySwimmer and RelayLap; (deletion point 6. below)
    - 5.4.4. MeetingEntry, MeetingReservation, MeetingRelayReservation and MeetingTeamScore; (deletion point 6. below); simplified processing for MeetingEntry, MeetingReservation, MeetingRelayReservation as these 3 DO NOT NEED TO BE MERGED, BUT JUST DELETED from source as their usage is deprecated and rarely will have rows involved in this task.

6. Any resulting duplicate source record row that gets merged into a valid destination row must be removed as the last step of the operation, whenever we reach the bottom hierarchy branch, that is:
  - 6.1: laps (@schema.rb#L752-779) → meeting_individual_results (@schema.rb#L878-914)
  - 6.2: relay_laps (@schema.rb#L1208-1230) → meeting_relay_swimmers (@schema.rb#L989-1013) → meeting_relay_results (@schema.rb#L957-987)
  - 6.3: meeting_relay_reservations (@schema.rb#L937-955) → meeting_reservations (@schema.rb#L1015-1034)
  - 6.4: meeting_team_scores (@schema.rb#L1056-1083)
  - 6.5: meeting_programs (@schema.rb#L916-935) → meeting_events (@schema.rb#L859-876) → meeting_sessions (@schema.rb#L1036-1054)
  - 6.6: meetings (@schema.rb#L1080-1136) → calendars (@schema.rb#L226-256)

7. Check data validation before saving any destination row to the DB using something like `GogglesDb::ValidationErrorTools.recursive_error_for(model_row)`, similarly to what we've already done for the existing committer classes. See, for example, @badge.rb#L155-181.
  - Due to the nature of the data-import/data-fix procedure (which tries to match existing swimmers, teams, pools or cities), we should not touch swimmers, teams, seasons or swimming_pools or any other "base" look-up entity (because, for example, if a swimming_pool row was created for the source meeting, we'll reuse its ID in the destination meeting sessions). But we can create automatically any missing badges or team_affiliations when needed, logging the operation as a warning (see point 8. below) for incomplete data found (with ID reference for debugging), if for any reason the data is incomplete (validation fails).
  - 7.1. to create any missing badges: use source (or target, as they must be the same) swimmer_id, season_id and team_id
  - 7.2. to create any missing team_affiliations: use source (or target) team_id and season_id

8. Create a dedicated info/warning log text file to signal any non-fatal issues, on any entity row during the process, logging table name, source row ID and destination row ID of the step where the issue occurred. For example:
  - destination MIR found existing matching the same program type (see point 9 below), swimmer and team, but with different badge_id or team_affiliation_id or different non-zero timing: same program type + swimmer + team implies the individual result should be the same, but with different timing might signal a result update or with different badge or team affiliation might imply a duplicated badge or team_affiliation creation which must be later resolved with the dedicated check and merge tasks;
  - destination MRR found, matching the same program type (same as above) and team_id: any difference in team_affiliation or a difference between non-zero timing columns should be logged as above;
  - destination Lap found (same program type as above, with same swimmer_id and team_id) but different timing columns (minutes, seconds, hundredths, reaction_time, minutes_from_start, seconds_from_start, hundredths_from_start): again, log the difference in timing columns.
  - in many other cases (relay_laps, meeting_relay_swimmers) similar conditions may apply, using always the type of the parent entity (same code or ID, plus ties to same team and swimmer) as the key for the check. The fundamental principles that shape this "meeting results" data domain are:
    A) each swimmer can compete only once in the same event (single result per swimmer per event/program);
    B) each swimmer can only belong to a single category per season (single badge per season);
    C) each team can only be registered once per season (single team_affiliation);
    D) each swimmer can only be registered once with the team (single badge and single team_affiliation per season);

9. Destination row existence checks must be performed using the combination of columns that uniquely identify a record across meeting results. Merging same-table rows with different parent ID links implies we need to rely either on `code` or `id` values where possible or any other specific lookup-entity IDs (like `event_type_id`, or `category_type_id`, `gender_type_id`, `swimming_pool_id` and so on) which, as said above, should be the same for both source and destination whenever they actually refer to the same result. So, when comparing, for example 2 MeetingProgram rows, we need to dig into the hierarchy, retrieving the event type, the category type and the gender type because obviously any meeting_program_id referenced in individual or relay results will use different values. Specifically:

  - 9.1. MeetingProgram rows are the main discriminant between results and are identified by event type (from MeetingEvent), category type and gender type. By obtaining and comparing the linked `event_type_id`, `category_type_id` and `gender_type_id` we can determine if 2 different MeetingProgram rows are referencing the same program event.

  - 9.2. MIRs (meeting individual results): 2 rows are to be considered "the same" if they refer to the same type of meeting program (see above), same team_id and same swimmer_id. If the row is found equal with this criteria but some fields differ, specifically the timing columns (minutes, seconds, hundredths) or badge_id or team_affiliation_id, we'll log the difference into the dedicated warning text log file but overwrite the destination with the source where possible (source non-zero/present and destination either different or zero/empty).

  - 9.3. For MRRs (meeting relay results): 2 rows are the same if they refer to the same type of meeting program (same criteria as point 9.2 above but with relay category codes) and same team_id. If the row is found equal but some fields differ, specifically the timing columns (minutes, seconds, hundredths) or badge_id or team_affiliation_id, we'll log the difference into the dedicated warning text log file.

  - 9.4. For MRS (meeting relay swimmers): same parent relay (thus, same category code and same team_id), same swimmer_id and same length_in_meters.

  - 9.5. For laps (child of MIRs) or relay_laps (child of MRS): same parent result (see points above), same team_id, swimmer_id, and same length_in_meters.

  - 9.6. MeetingEvent: compare just `event_type_id`.
  - 9.7. MeetingSession: compare just `scheduled_date`.
  - 9.8. MeetingTeamScores: compare just `team_id`. (Each overall team score row is unique per meeting)
  - 9.9. Calendar: only one calendar row per season must refer to the same meeting_id (thus, after source has been merged, if there's a calendar row tied to the source meeting_id, that row must be deleted too), regardless of Calendar's `scheduled_date`.

10. We'll be assuming no duplicate teams, swimmers, badges and team affiliations are present in the whole season or, at least, involve the 2 meetings being merged. Meaning we won't check for base entity duplicates (teams, swimmers, badges and team_affiliations will be handled by the existing dedicated rake tasks for checking and merge)

11. We can reuse anything already existing in goggles_db, goggles_admin2 (strategies, services and so on). We may even generalize, refactor or improve any existing classes by adding methods or splitting them in reusable parts (for example, extracting common parts), as long as we can provide tests that assure no regression occurring.
  - 11.1. Any newly written or updated RSpec test must be fully green or this task won't be considered complete.

12. Given the lengthy process, the task should output a simple but meaningful progress indicator on the console, possibly step-by-step.
 - For example, when looping upon several rows (like MIRs of a Program), we could output the name (and ID or code or the `display_label` from the decorator if available) of the entity being processed, plus a dot for process like `$stdout.write("\033[1;33;32m.\033[0m")`.
 - To speed-up process and reduce the number of queries needed for lookup, especially if we'll be looping on a parent entity to process each children one by one, we should probably pass as parameters any parent entity key needed by the children (like event_type_id, category_type_id, gender_type_id and so on).

## Goal and reference test case scenario
In order to complete this task, we must be able to successfully merge 2 meetings that have been recently duplicated and are available in the current localhost database dump:

- A) meeting ID 19988 (newer): complete hierarchy with MIRs, MRRs, MRSs and laps, but no meeting or standard point values for results.
- B) destination meeting ID 19863 (older): almost complete hierarchy, but no relay results or laps, with meeting/standard points for each result row.

We can probably choose the most complete one as destination and only update the columns that need updating (like the scores, for one), or we could use it as source, moving any rows missing from the destination. In any case, the result of the task (even in the default simulation mode) should be a script the leaves only 1 calendar row for the remaining destination calendar, plus unique results for each program event, swimmer and team combination as detailed above.

---

# First analysis for Meeting Merge Task - Implementation Plan

Based on my thorough analysis of the task plan (`@/home/steve/Projects/goggles_admin2/docs/merge_meeting_task_plan.md:1-88`) and the existing merge patterns ([Merge::Team](cci:2://file:///home/steve/Projects/goggles_admin2/app/strategies/merge/team.rb:10:2-195:5), [Merge::Badge](cci:2://file:///home/steve/Projects/goggles_admin2/app/strategies/merge/badge.rb:10:2-1309:5), [Merge::Swimmer](cci:2://file:///home/steve/Projects/goggles_admin2/app/strategies/merge/swimmer.rb:10:2-181:5)), here's my proposed architecture and implementation plan.

---

## Overview

The Meeting merge is significantly more complex than existing merge strategies because it involves a **deep hierarchy** with multiple branches:

```
Meeting
├── MeetingSession(s)
│   └── MeetingEvent(s)
│       └── MeetingProgram(s)
│           ├── MeetingIndividualResult(s) → Lap(s)
│           ├── MeetingRelayResult(s) → MeetingRelaySwimmer(s) → RelayLap(s)
│           └── MeetingEntry(s)
├── MeetingReservation(s) → MeetingEventReservation(s) / MeetingRelayReservation(s)
├── MeetingTeamScore(s)
└── Calendar (1:1)
```

---

## Proposed Architecture

### New Files to Create

| File | Purpose |
|------|---------|
| `app/strategies/merge/meeting_checker.rb` | Analysis & conflict detection |
| `app/strategies/merge/meeting.rb` | Main merge strategy class |
| [lib/tasks/merge.rake](cci:7://file:///home/steve/Projects/goggles_admin2/lib/tasks/merge.rake:0:0-0:0) (update) | Add `merge:meeting` task |
| `spec/strategies/merge/meeting_checker_spec.rb` | Tests for checker |
| `spec/strategies/merge/meeting_spec.rb` | Tests for merger |

### Design Pattern (Following Existing Conventions)

```ruby
# Similar to Merge::Team / Merge::Badge pattern:
module Merge
  class Meeting
    attr_reader :sql_log, :checker, :source, :dest, :warning_log
    
    def initialize(source:, dest:, skip_columns: false)
      # Validate both are Meetings in same Season
      @checker = MeetingChecker.new(source:, dest:)
      @sql_log = []
      @warning_log = []  # New: dedicated warning file
    end
    
    def prepare
      @checker.run
      # Generate SQL script...
    end
  end
end
```

---

## Implementation Phases

### **Phase 1: MeetingChecker** (~Day 1-2)
Analysis class that detects conflicts and collects merge data.

**Key responsibilities:**
1. Validate same Season [spec 2]
2. Map sessions by `scheduled_date` [spec 9.7]
3. Map events by `event_type_id` [spec 9.6]
4. Map programs by `(event_type_id, category_type_id, gender_type_id)` [spec 9.1]
5. Detect shared vs source-only vs dest-only at each level
6. Flag timing conflicts in MIRs/MRRs for warning log [spec 8]

**Data structures to collect:**
```ruby
# Session mapping: { scheduled_date => { src_id:, dest_id: } }
# Event mapping:   { event_type_id => { src_id:, dest_id:, session_key: } }
# Program mapping: { [event_type_id, category_type_id, gender_type_id] => { src_id:, dest_id: } }
# MIR mapping:     { [program_key, team_id, swimmer_id] => { src_ids:, dest_ids: } }
# MRR mapping:     { [program_key, team_id] => { src_ids:, dest_ids: } }
```

---

### **Phase 2: Session/Event/Program Hierarchy** (~Day 2-3)
Process top-down following [spec 5.4.1].

**For each MeetingSession (compare by `scheduled_date`):**
- If dest session exists → use dest session_id for children
- If only in source → UPDATE `meeting_id` to point to dest meeting

**For each MeetingEvent (compare by `event_type_id`):**
- If dest event exists → use dest event_id for children
- If only in source → UPDATE `meeting_session_id` to dest session

**For each MeetingProgram (compare by `event_type_id + category_type_id + gender_type_id`):**
- If dest program exists → use dest program_id for results
- If only in source → UPDATE `meeting_event_id` to dest event

---

### **Phase 3: Results Merging** (~Day 3-4)
The most complex part. Handle MIRs, MRRs, MRS, Laps, RelayLaps.

**MIR Logic [spec 9.2]:**
```ruby
# Two MIRs are "same" if: same program_type + team_id + swimmer_id
# 1. Source-only MIRs → UPDATE meeting_program_id to dest program
# 2. Shared MIRs → UPDATE dest with source non-zero values, log timing diffs
# 3. Move Laps (UPDATE meeting_individual_result_id, meeting_program_id)
# 4. DELETE source MIR after merge
```

**MRR/MRS/RelayLap Logic [spec 9.3, 9.4, 9.5]:**
- Similar pattern but with relay hierarchy
- MRS matched by: same MRR + swimmer_id + length_in_meters
- RelayLap matched by: same MRS + length_in_meters

**Auto-create missing Badges/TeamAffiliations [spec 7.1, 7.2]:**
```ruby
# If validation fails due to missing badge:
#   INSERT INTO badges (swimmer_id, season_id, team_id, ...)
#   Log warning with IDs
# If validation fails due to missing team_affiliation:
#   INSERT INTO team_affiliations (team_id, season_id, ...)
#   Log warning with IDs
```

---

### **Phase 4: Auxiliary Entities** (~Day 4)
Handle entries, reservations, team scores, calendar.

**Simplified processing [spec 5.4.4]:**
- MeetingEntry, MeetingReservation, MeetingRelayReservation → **DELETE from source** (deprecated, rarely used)
- MeetingTeamScore → Merge by `team_id` [spec 9.8], UPDATE or move
- Calendar → DELETE source calendar row after merge [spec 9.9]

---

### **Phase 5: Rake Task & Logging** (~Day 5)

**Rake task structure:**
```ruby
desc 'Merge two meetings belonging to the same season...'
task(meeting: [:check_needed_dirs]) do
  source = GogglesDb::Meeting.find_by(id: ENV['src'].to_i)
  dest = GogglesDb::Meeting.find_by(id: ENV['dest'].to_i)
  # Validate, create merger, prepare, process_sql_file
end
```

**Output files:**
1. `NNNN-merge_meetings-SRC-DEST.sql` - Full transaction script
2. `NNNN-merge_meetings-SRC-DEST-warnings.log` - Timing differences and auto-created entities

**Progress indicator [spec 12]:**
```ruby
puts "--> Processing MIRs for program #{program.decorate.display_label}..."
mirs.each_with_index do |mir, idx|
  $stdout.write("\033[1;33;32m.\033[0m") if (idx % 5).zero?
end
```

---

### **Phase 6: RSpec Tests** (~Day 5-6)

**Test scenarios needed:**
1. **MeetingChecker specs:**
   - Same season validation
   - Session/Event/Program mapping
   - Conflict detection

2. **Merge::Meeting specs:**
   - Source-only entities get moved
   - Shared entities get merged (non-zero overwrites)
   - Duplicate deletions in correct order
   - Badge/TeamAffiliation auto-creation
   - Warning log captures timing differences
   - SQL script is valid and executable

3. **Integration test** with reference data:
   - Meeting 19988 (source) → Meeting 19863 (dest) [spec Goal section]

---

## Key Design Decisions

### 1. **Comparison Keys** (from spec section 9)

| Entity | Comparison Columns |
|--------|-------------------|
| MeetingSession | `scheduled_date` |
| MeetingEvent | `event_type_id` |
| MeetingProgram | `event_type_id`, `category_type_id`, `gender_type_id` |
| MIR | program_key + `team_id` + `swimmer_id` |
| MRR | program_key + `team_id` |
| MRS | MRR_key + `swimmer_id` + `length_in_meters` |
| Lap/RelayLap | parent_key + `length_in_meters` |

### 2. **Processing Order**
- **Top-down for creation/update** [spec 5.4]
- **Bottom-up for deletion** [spec 6]

### 3. **Non-zero Value Priority** [spec 5]
```ruby
def merge_value(src_val, dest_val)
  return src_val if dest_val.blank? || dest_val.zero?
  return dest_val if src_val.blank? || src_val.zero?
  src_val # Source wins if both non-zero (but log warning)
end
```

---
