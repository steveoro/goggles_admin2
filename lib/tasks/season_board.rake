# frozen_string_literal: true

#
# = Season board helper tasks
#
#   - (p) FASAR Software 2007-2026
#   - for Goggles framework vers.: 7.00
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

# Since phase 13 the task body is a thin caller of the 'season_board.backfill' operation (Maintenance::RakeRunner).
namespace :season_board do
  desc <<~DESC
      One-time backfill linking the existing calendars rows of a season to the FIN calendar
    through the numeric FIN event ID (stored in 'calendars.results_code'), and flagging
    'meetings.results_acquired' for the season meetings that actually have results.

    The FIN ID is read from the archived crawl files ('meetingURL'/'manifestURL' of
    'results.done|new/<season>/<base>[-lt4].json'), the meeting ID from the commit SQL
    files 'NNNN-<base>-lt4.sql' (results.sent|done|new); manifest-only bases are matched
    through the file names predicted from the watcher snapshot rows. No name matching
    against DB strings is done: the rows that can't be resolved are listed in the report
    (with the same-date FIN rows as hints) and can be linked by hand from the Season board.

    The generated UPDATEs are idempotent (rows already correct are skipped).

    In apply mode (simulate=0), the changes are run on the localhost DB inside a single
    transaction (the 'season_board.backfill' operation, since phase 13) and the SQL script
    is registered in the SQL Outbox as:

      - 'crawler/data/results.new/misc/<index>-season_board_backfill-<season_id>.sql'

    In apply mode the DB sync gate runs first (Drift::Gate, scope :rake; see /db_sync):
    a red verdict aborts the task unless force=1; any other warning is printed.

    Options: [Rails.env=#{Rails.env}]
             [season=<season#id>|<latest MASFIN season>]
             [simulate='0'|<'1'>]
             [force='1'|<'0'>]

      - season: the Season ID to be processed (default: the latest FIN Masters season);

      - simulate: when set to '0' the changes are applied locally and the script is
                  written (default: '1', just prints the report and the SQL);

      - force: when set to '1' a red DB sync verdict doesn't stop the apply mode.

  DESC
  task backfill: :environment do
    data_root = defined?(SCRIPT_OUTPUT_DIR) ? SCRIPT_OUTPUT_DIR.dirname : Outbox.data_root
    status = Maintenance::RakeRunner.call('season_board:backfill', data_root:)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++
end
