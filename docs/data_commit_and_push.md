# Data Commit & Push

This final stage of the data import workflow involves permanently saving the reviewed and corrected data into the Goggles database. This is handled by the `Import::MacroCommitter` class.

## Commit process (`Import::MacroCommitter`)

The `Import::MacroCommitter` class (`app/strategies/import/macro_committer.rb`) is responsible for translating the verified data representation into actual database changes.

*   **Input:** An instance of `Import::MacroSolver` which has been initialized with the **final, reviewed JSON data file**. This file contains the data parsed from the source, enriched with database links by `MacroSolver`, and potentially corrected via the `DataFixController` interface.
*   **Orchestration (`commit_all`):
    1.  The process typically starts by calling the `commit_all` method on the `MacroCommitter` instance.
    2.  This method iterates through the entities stored within the `MacroSolver`'s data structures (`solver.data`) in a specific order designed to respect database dependencies (e.g., Teams are committed before Badges, Meetings before Sessions, Events before Results, etc.).
*   **Entity Committing:**
    1.  For each entity instance (like a specific swimmer, team, or result) found in the solver's data:
        *   The committer retrieves the corresponding unsaved ActiveRecord model instance (`model_row`).
        *   It checks if the `model_row` has an existing database `id`.
        *   **New Records (INSERT):** If the `id` is missing or zero and the row is valid, the committer calls `save!` on the `model_row`, inserting it into the database.
        *   **Existing Records (UPDATE):** If the `id` exists, the committer compares the `model_row`'s attributes with the current database record. If any differences are found, it fetches the database record, applies the changes from the `model_row`, and calls `save!` to update the database record.
        *   **Validation:** Validity checks are performed before saving; errors are raised if a record is invalid.
*   **SQL Logging:** Every successful INSERT or UPDATE operation generates a corresponding SQL statement via the `SqlMaker` utility, which is appended to a log stored within the committer instance.
*   **Data Structure Update:** After a record is successfully committed, the committer updates the `MacroSolver`'s internal data structure, replacing the temporary row representation with the actual, saved ActiveRecord object returned from the database.
*   **Output:**
    *   The primary result is the **modification of the Goggles database**, with new records created and existing ones updated according to the reviewed data.
    *   An SQL log detailing all the database operations performed during the commit process.

## Push process (manual sync)
 
This whole data-fix/commit/push process assumes that the local database is just a cloned dump of the remote one so that by editing locally the data and pushing just the committed changes both databases will be updated and in sync.

The final result of the commit is an output SQL log file that will be generated only if the transaction is successful, and stored as `crawler/data/results.new/<season_id>/<original_json_filename>.sql`.

This output SQL file is then ready to be "pushed" (manually) to the remote server. There, a background job will check for any uploaded SQL log files and, if found, will execute them to update its database, respecting the order of upload.
