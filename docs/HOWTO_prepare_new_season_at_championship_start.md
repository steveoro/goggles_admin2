# HOW-TO: prepare a new Season and related data at Championship start

Each year, around September/October, most championship season will be restarting.
Required entities:

- `Season`: 1 new row for each FederationType (FIN, CSI, etc.). For convention and consistency, Season IDs are increased by 10 for each new season, leaving the last digit usually unchanged between seasons and FederationTypes (to easily identify the season and the FederationType from the code).

- `CategoryType`: 1 new row for each new Season-related CategoryType (M20, M25, M30, ...), as categories can change from year to year due to rules changes.

- `StandardTiming`: 1 new row for each new Season-related StandardTiming (M20, M25, M30, ...), for each different PoolType, GenderType, CategoryType and EventType combination. (~1100+ rows per season.)


## Step 1: prepare base data migrations

Copy the 3 data migrations from the previous season, renaming them accordingly and editing them by hand:

  - `20<yymmddhh>0000_data_fix_add_20<yy>_seasons.rb`
  - `20<yymmddhh>0001_data_fix_add_20<yy>_category_types.rb`
  - `20<yymmddhh>0005_update_db_version_to_<version>.rb`

Content is pretty straightforward: just edit the Season ID and the version number in each block, uncommenting and updating the sections as needed.

The `data_fix_add_20<yy>_category_types` migration will run the `GogglesDb::CmdCloneCategories` command for each season. (See the command class implementation for more info.)


## Step 2: run data migrations

Run the migrations from `goggles_db` and verify that everything is correct:
f
```bash
> bundle exec rails app:db:migrate
> RAILS_ENV=test bundle exec rails app:db:migrate
```

Having updated also the test DB with the new required data, update the test dump so that it can be used for testing during the build pipeline:

```bash
> RAILS_ENV=test bundle exec rails app:db:dump
```

Goggles uses Git's LFS to store the test dump directly on the repository.


## Step 3: official standard timings download

Download the standard timings from the championship website (e.g. [FIN official website](https://www.federnuoto.it/home/master/norme-e-documenti-master.html)) possibly in XLS format, and save the file under `goggles_admin2` in `crawler/data/standard_timings`.


## Step 4: prepare .CSV from .XLS

These are the supported/expected column formats for the `standard_timings.rake` task in `goggles_admin2` (with first row as header, either one is valid):

1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"
2. "category_code;event_label;25_m;50_m;25_f;50_f"

Open the downloaded XLS file, remove the first column ("KEY") if present and edit the column headers to match the expected format.
If the gender code is in Italian ("U" for "Uomini", "D" for "Donne"), replace them with "M" and "F" respectively. In recent years we have seen that often the female gender code used is already "F", so that's one less edit to do.

Save the file as .CSV and add the season code as a prefix to the filename (e.g. `252-mst_tb_ind_2025-2026.csv`).


## Step 5: run the dedicated rake task

From GogglesAdmin2 root directory, run the rake task:

```bash
> bundle exec rails import:standard_timings season=<season_id>
```

The task will create a new file in `crawler/data/results.new` with the SQL script for data-import.

The generated file is then ready to be pushed (uploaded) to the server with the admin UI as soon as the new version of the application is deployed: this will also run the updated data-migrations and make the new season and categories available during data-import push.

(Pushing the SQL file with the standard timings before running the data-migrations will fail without the new season and categories bound to the timings.)
