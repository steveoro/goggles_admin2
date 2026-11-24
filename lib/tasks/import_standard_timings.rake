# frozen_string_literal: true

require 'goggles_db'

SCRIPT_OUTPUT_DIR = Rails.root.join('crawler/data/results.new').freeze unless defined? SCRIPT_OUTPUT_DIR
#-- ---------------------------------------------------------------------------
#++

# Since phase 13 the task body is a thin caller of the 'standard_timings.import' operation (Import::StandardTimings,
# Maintenance::RakeRunner): same source discovery, checks, texts and SQL as before.
namespace :import do
  desc <<~DESC
    Reads standard timings from an XLSX or CSV source file.
    Converts each row to a StandardTiming and prepares the SQL script for data-import.

    Source files are stored under 'crawler/data/standard_timings' (possibly inside a
    '<season_id>' sub-folder named after the season ID, e.g. '262').
    Output file will be stored in 'crawler/data/results.new/<season_id>/NNNN-<season_id>-standard_timings.sql'
    and registered in the SQL Outbox HELD:
    - simulate=1 (the default): 'not applied locally' (apply it from the Outbox page, or release it
      there without local apply, before pushing it);
    - simulate=0: applied locally first (DB sync gate; force=1 overrides a red verdict), then held
      until the remote season exists (released by step 6 of the season-start checklist,
      /operations/season_start/<season_id>, or from the Outbox page).

    Supported/expected column formats (with header row; either one is valid for CSV,
    XLSX sheets are auto-detected by their header labels):

    1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"
       (XLSX: CATEG|CATEGORIA, COD GARA, GARA, SESSO, VASCA, CENTESIMI|CENT TOT,
        TEMPO (mmsscc), TEMPO PRINT - other columns are ignored)
    2. "category_code;event_label;25_m;50_m;25_f;50_f" (CSV only)

    Options: [season=season#id|<latest FIN Masters season>]
             [source=source_file_name|<auto-discovery>]
             [simulate='0'|<'1'>] [force=<'0'>|'1']

      - season: season ID, used also as sub-folder name for source file lookup.
      - source: source file name (with or without '.xlsx'/'.csv' extension), searched
                under 'crawler/data/standard_timings' and inside its <season_id> sub-folder.
                When not specified, the first file matching
                '*mst_tb_ind*<season.begin_year>*.xlsx' inside the <season_id> sub-folder
                is used (with fallbacks for legacy layouts and .csv files).

  DESC
  task standard_timings: :environment do
    status = Maintenance::RakeRunner.call('import:standard_timings', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
end
