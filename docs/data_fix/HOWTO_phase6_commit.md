# HOWTO: Phase 6 Commit & SQL Generation

## Quick Start

After completing phases 1-5 of the data import workflow, follow these steps to commit changes to the database and generate SQL for remote sync:

### Step 1: Navigate to Phase 5 Review

```
URL: /data_fix/review_results?file_path=<path>&phase5_v2=1
```

You should see:
- All imported results grouped by program (session-event-category-gender)
- Result cards with swimmer names, teams, timings, and laps
- A green **"Commit"** button in the top-right corner

### Step 2: Review Results

Carefully review the displayed results to ensure:
- All swimmers are correctly matched
- All teams are correctly matched
- Timings look correct
- Badge associations are proper (team + swimmer + season)

### Step 3: Click Commit Button

1. Click the **"Commit"** button (green button with database icon)
2. A confirmation dialog will appear:
   ```
   Commit changes?
   ```
3. Click **OK** to proceed

### Step 4: Wait for Processing

The system will:
- ✅ Validate all phase files exist (1-4)
- ✅ Commit entities in dependency-aware order
- ✅ Generate SQL log for all operations
- ✅ Save SQL file to `results.new/<season_id>/`
- ✅ Move source JSON to `results.done/<season_id>/`
- ✅ Clean up phase files
- ✅ Clean up temporary database tables

### Step 5: View Results

You'll be redirected to the **Push Dashboard** with a success message:

```
Phase 6 commit successful! 
Created: 1 meetings, 12 teams, 156 swimmers, 156 badges, 
24 events, 48 programs, 312 results, 624 laps. 
SQL file saved to: sample-meeting-200RA.sql
```

### Step 6: Upload SQL to Remote Server

From the Push dashboard:
1. Verify the SQL file is listed
2. Click **"Upload"** to send to staging server
3. After testing, click **"Upload"** again to send to production server

---

## Dependency Order

Entities are committed in this specific order to respect foreign key constraints:

```
Phase 1:
  City → SwimmingPool → Meeting → MeetingSession

Phase 2:
  Team → TeamAffiliation

Phase 3:
  Swimmer → Badge

Phase 4:
  MeetingEvent

Phase 5:
  MeetingProgram → MeetingIndividualResult → Lap
```

---

## What Gets Created vs Updated

### INSERT (New Records)
Records are **created** when they don't have a database ID assigned:
- New meetings (if not matched in Phase 1)
- New teams (if not matched in Phase 2)
- New swimmers (if not matched in Phase 3)
- New badges (always created - unique per swimmer/team/season)
- New events (if not matched in Phase 4)
- New programs (auto-created if not existing)
- New results (if not matched in Phase 5)
- New laps (always created - unique per result)

### UPDATE (Existing Records)
Records are **updated** when they have a database ID and attributes changed:
- Matched meetings with modified data
- Matched teams with name/city changes
- Matched swimmers with name/YOB changes
- Matched events with time/order changes
- Matched results with timing/rank changes

### SKIP (No Changes)
Records are **skipped** when they have a database ID and no attributes changed:
- Matched entities with identical data
- No SQL generated for these

---

## Transaction Safety

### All-or-Nothing Guarantee

The entire commit happens in a **single database transaction**:
- ✅ All entities committed successfully → **commit transaction**
- ❌ Any error occurs → **rollback everything**

### Error Handling

If commit fails:
1. Transaction is rolled back
2. No data written to database
3. Phase files remain intact
4. Error message displayed with details
5. User redirected back to Phase 5 review

Example error message:
```
Phase 6 commit failed: Validation failed: Swimmer year_of_birth can't be blank
```

---

## File Organization

### Before Commit
```
crawler/data/results.new/<season_id>/
  ├── sample-meeting-200RA.json           # Source file
  ├── sample-meeting-200RA-phase1.json    # Phase 1 data
  ├── sample-meeting-200RA-phase2.json    # Phase 2 data
  ├── sample-meeting-200RA-phase3.json    # Phase 3 data
  └── sample-meeting-200RA-phase4.json    # Phase 4 data
```

### After Commit
```
crawler/data/results.new/<season_id>/
  └── sample-meeting-200RA.sql            # Generated SQL batch

crawler/data/results.done/<season_id>/
  └── sample-meeting-200RA.json           # Backup of source
```

Phase files are deleted after successful commit.

---

## SQL Log Format

The generated SQL file contains:
- One statement per INSERT/UPDATE operation
- Proper escaping for all string values
- Explicit column names
- Sequential order respecting foreign keys

Example SQL:
```sql
INSERT INTO `cities` (`id`,`name`,`zip`,`country`,`country_code`,`latitude`,`longitude`,`created_at`,`updated_at`) VALUES (12345,'Bologna','40100','Italy','IT','44.4949','11.3426','2025-11-04 10:00:00','2025-11-04 10:00:00');

INSERT INTO `swimming_pools` (`id`,`name`,`city_id`,`pool_type_id`,`lanes_number`,`created_at`,`updated_at`) VALUES (456,'Piscina Comunale','12345',1,8,'2025-11-04 10:00:01','2025-11-04 10:00:01');

INSERT INTO `meetings` (`id`,`description`,`code`,`season_id`,`header_date`,`created_at`,`updated_at`) VALUES (789,'200 Metri Rana','200ra',212,'2025-10-15','2025-11-04 10:00:02','2025-11-04 10:00:02');
```

---

## Troubleshooting

### "Missing phase files" Error

**Problem**: One or more phase files don't exist

**Solution**: 
1. Go back to the missing phase
2. Complete the phase (matching/review)
3. Return to Phase 5 and try commit again

### Commit Takes Too Long

**Problem**: Large dataset (500+ results) causing timeout

**Solution**:
1. Check Rails logs for progress
2. Consider splitting meeting into multiple imports
3. Increase request timeout if needed

### Validation Errors

**Problem**: Entity fails validation (e.g., missing required field)

**Solution**:
1. Check error message for specific entity and field
2. Go back to relevant phase (1-5)
3. Fix the data
4. Try commit again

### "Badge error: TeamAffiliation not found"

**Problem**: Team affiliation wasn't created in Phase 2

**Solution**:
1. Go back to Phase 2
2. Ensure team is matched (has team_id)
3. Ensure team_affiliation is in phase2.json
4. Try commit again

---

## Tips & Best Practices

### Before Committing

- ✅ Review **all phases** to ensure data quality
- ✅ Check for **unmatched entities** (no IDs assigned)
- ✅ Verify **team affiliations** exist for all teams
- ✅ Confirm **swimmer badges** have correct categories
- ✅ Test with **small dataset first** before large imports

### After Committing

- ✅ Check **SQL file** for correctness
- ✅ Test on **staging server** before production
- ✅ Keep **backup** of source JSON (auto-saved to results.done)
- ✅ Monitor **database size** growth
- ✅ Verify **foreign key integrity**

### Performance Optimization

For large imports (500+ results):
- Split into multiple meetings if possible
- Process in batches (separate phase files)
- Monitor memory usage
- Check database query performance

---

## Related Documentation

- [Phase 6 Implementation Plan](./phase6_implementation_plan.md)
- [Phase 6 Implementation Complete](./phase6_implementation_complete.md)
- [Phase 5 Pipeline](./README_PHASES.md)
- [Main Code](../../app/strategies/import/committers/phase_committer.rb)
