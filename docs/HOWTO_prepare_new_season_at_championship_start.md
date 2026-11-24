# HOW-TO: prepare a new Season and related data at Championship start

Each year, around September/October, most championship seasons restart. Required entities:

- `Season`: 1 new row for each FederationType (FIN, CSI, etc.). For convention and consistency, Season IDs are increased by 10 for each new season, leaving the last digit usually unchanged between seasons and FederationTypes (to easily identify the season and the FederationType from the code).
- `CategoryType`: 1 new row for each new Season-related CategoryType (M20, M25, M30, ...), as categories can change from year to year due to rules changes.
- `StandardTiming`: 1 new row for each new Season-related StandardTiming, for each different PoolType, GenderType, CategoryType and EventType combination (~1100+ rows per season).

## The season-start checklist (admin2)

Since phase 13 the whole procedure is a guided checklist: sidebar **Data quality > Operations**, then **Season-start checklist** (`/operations/season_start`, pick the season; the new FIN Masters season is usually the latest id + 10), or the **Season-start checklist** link of a `season.setup` data health finding (a season without CategoryTypes or standard timings).

The page lists eight ordered steps. A step opens only when every previous one is done (or skipped, for the two tick boxes): its buttons are disabled before, and the server refuses its POST anyway. The steps marked *checked on the data* re-derive their state on every view; the two tick boxes are stored in the ops DB (`season_checklist_items`, with who confirmed them, when, and an optional note). Nothing on the page calls the remote API, except the explicit check of step 6.

| # | Step | Done when | Action in admin2 |
|---|---|---|---|
| 1 | Season rows exist locally | the `Season` row of the id exists | none (goggles_db migration, see below) |
| 2 | CategoryTypes exist | the season has at least one `CategoryType` | repair only: **Clone from season N** (`categories.clone`) |
| 3 | Dev and test DBs migrated, test dump refreshed | ticked by the operator | **Mark as done** / **Skip** (with a note) |
| 4 | Standard-timings source file present | the FIN file is found in `crawler/data/standard_timings/<season_id>/` | **Upload** (`.xlsx` or `.csv`, saved in that folder) |
| 5 | Standard timings imported | the season has `StandardTiming` rows | **Open the dry run form** (`standard_timings.import`) |
| 6 | Remote season exists | the last on-demand check found it and no standard-timings script is still held | **Check the remote season now** |
| 7 | Static calendar URLs checked | ticked by the operator | **Mark as done** / **Skip** |
| 8 | Season board backfill | `SeasonDefaults.default_season_id` is the new season and a `season_board.backfill` apply exists for it | **Open the dry run form** (`season_board.backfill`) |

### Step 1: Season rows (goggles_db)

No Season row is ever created from admin2: they come from the goggles_db data migrations. Copy the 3 data migrations from the previous season, renaming them accordingly and editing them by hand:

- `20<yymmddhh>0000_data_fix_add_20<yy>_seasons.rb`
- `20<yymmddhh>0001_data_fix_add_20<yy>_category_types.rb`
- `20<yymmddhh>0005_update_db_version_to_<version>.rb`

Content is pretty straightforward: just edit the Season ID and the version number in each block, uncommenting and updating the sections as needed. The step lists the other seasons of the same championship year, to check every FederationType got its row.

### Step 2: CategoryTypes

The `data_fix_add_20<yy>_category_types` migration runs the `GogglesDb::CmdCloneCategories` command for each season (see the command class for more info): after step 1 the categories are usually there already.

Only as a **repair**, when the local season has no CategoryType **and** the remote season is known to exist (step 6 checked it), the step offers **Clone from season N**: the `categories.clone` operation (the code of `rake import:categories`) clones the previous season's categories, with a dry run first. It is never offered otherwise: a clone pushed from admin2 could collide with the categories the goggles_db migration inserts on deploy. (The operation has no form link on `/operations` for the same reason.)

### Step 3: run the data migrations (tick box)

Run the migrations from `goggles_db` and verify that everything is correct:

```bash
> bundle exec rails app:db:migrate
> RAILS_ENV=test bundle exec rails app:db:migrate
```

Having updated also the test DB with the new required data, update the test dump so that it can be used for testing during the build pipeline:

```bash
> RAILS_ENV=test bundle exec rails app:db:dump
```

Goggles uses Git's LFS to store the test dump directly on the repository. Admin2 can't check any of this: tick **Mark as done** (or **Skip**) when it's over.

### Step 4: the official standard timings file

Download the standard timings from the championship website (e.g. [FIN official website](https://www.federnuoto.it/home/master/norme-e-documenti-master.html)), possibly in XLSX format, and save it as-is under `crawler/data/standard_timings/<season_id>/` (e.g. `crawler/data/standard_timings/262/mst_tb_ind_2026-2027b.xlsx`), or **Upload** it from the step (only the file name is kept; `.xlsx` and `.csv` only).

The step is done as soon as the file is found the way the import finds it: the first `*mst_tb_ind*<season begin year>*.xlsx` in the season folder (then any `*<season_id>*` folder, the standard timings folder itself, and the same patterns for `.csv`, with the legacy flat `<season_id>-mst_tb_ind_<b>-<e>.csv` name last).

No manual conversion is needed: the import reads the XLSX directly through `Parser::StandardTimingXlsx`, which:

- auto-detects the sheets having the expected column layout (header row, label aliases in parentheses):
  `CATEG`/`CATEGORIA`, `COD GARA`, `GARA`, `SESSO`, `VASCA`, `CENTESIMI`/`CENT TOT`, `TEMPO (mmsscc)`, `TEMPO PRINT` (any other column is ignored);
- when a single sheet contains both pool types (25 & 50, like the "VERIFICA" sheet in recent files) only that sheet is used; otherwise all matching sheets are merged and de-duplicated;
- normalizes gender codes (`U` => `M`, `D` => `F`) and the FIN non-standard 3-digit category codes (`M100` => `MA0`, i.e. FINA 100+);
- takes the timing from `TEMPO PRINT`, falling back to the `TEMPO (mmsscc)` digit column when missing.

The older CSV formats are still supported:

1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"
2. "category_code;event_label;25_m;50_m;25_f;50_f"

### Step 5: import the standard timings

**Open the dry run form** of the `standard_timings.import` operation (`Import::StandardTimings`). The dry run shows the file used, the sheets, the warnings and the row count; before any SQL is built it validates every `category_code` / `event_label` / `gender` / `pool_type` against the DB and stops listing every missing reference (e.g. a new CategoryType that still needs a data-fix in `goggles_db`). An explicit file can be named in the **Source file name** field (with or without extension; searched under `crawler/data/standard_timings` and inside its `<season_id>` sub-folder).

The apply (with the checkbox confirmation) inserts the rows on the local DB, then registers the script as `crawler/data/results.new/<season_id>/NNNN-<season_id>-standard_timings.sql` in the SQL Outbox, **held** with the reason *waiting for the remote season*: pushing it before the new goggles_db version (with its data migrations) is deployed would fail without the new season and categories bound to the timings.

### Step 6: the remote season

**Check the remote season now** asks the configured API for `GET season/<season_id>` (it needs a signed-in session with a valid API token). When the season exists there, the held standard-timings scripts of the season are released for push (Outbox state *pending*, push them from `/outbox`); when it doesn't yet, nothing changes: check again after the deploy. The step stays open while a standard-timings script of the season is still held.

### Step 7: static calendar URLs (tick box)

Check the static calendar URLs of the new season. They are the FIN pages admin2 reads by itself:

- the FIN "Riepilogo Eventi" page, read every hour by the watcher behind the Season board (`FedernuotoWatch::URL`);
- the FIN calendar pages crawled by **Import > Sources > Crawler > FIN calendar** (menu items *Eventi*, *Riepilogo Eventi* and *Archivio 2012-*; the base page is `Sources::CrawlKinds::FIN_CALENDAR_BASE_URL`, the menu targets are in `crawler/server/calendar-crawler.js`).

Crawl the new season's calendar once from that form: a new CSV in the **Calendars** tab of Sources means the pages still answer. The addresses are fixed in the code (watcher and crawler), not configurable from admin2: when FIN moves a page, the code has to change. Tick **Mark as done** (or **Skip**) when checked.

### Step 8: Season board backfill

After the first calendar crawl of the new season, **Open the dry run form** of `season_board.backfill` for it (calendars linked to their FIN event ids, `results_acquired` flags) and apply it. The step also shows whether `SeasonDefaults.default_season_id` (the latest FIN Masters season: the board season and the default of the rake tasks) is now the new season.

## From the terminal

The same steps still work from the terminal (the rake tasks now run the same operations, with the same texts):

```bash
> bundle exec rails import:standard_timings season=<season_id>            # simulate=1: script held 'not applied locally'
> bundle exec rails import:standard_timings season=<season_id> simulate=0 # applied locally, held until the remote season exists
> bundle exec rails import:categories src=<previous_id> dest=<season_id>  # repair only, see step 2
> bundle exec rails season_board:backfill season=<season_id> simulate=0
```

With `simulate=1` (the default) the standard-timings script stays held *not applied locally*: apply it from the Outbox page (**Apply locally**), or release it there without a local apply, before pushing it. The checklist step 5 counts the local `StandardTiming` rows, so it turns done only once the script ran locally.
