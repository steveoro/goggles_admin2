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
    transaction and the SQL script is stored for the push dashboard as:

      - 'crawler/data/results.new/<season_id>/<index>-season_board_backfill-<season_id>.sql'

    Options: [Rails.env=#{Rails.env}]
             [season=<season#id>|<latest MASFIN season>]
             [simulate='0'|<'1'>]

      - season: the Season ID to be processed (default: the latest FIN Masters season);

      - simulate: when set to '0' the changes are applied locally and the script is
                  written (default: '1', just prints the report and the SQL).

  DESC
  task backfill: :environment do
    puts '*** Task: season_board:backfill ***'
    season = if ENV['season'].present?
               GogglesDb::Season.find_by(id: ENV['season'].to_i)
             else
               GogglesDb::Season.last_season_by_type(GogglesDb::SeasonType.mas_fin)
             end
    if season.nil?
      puts("ABORTED: season #{ENV.fetch('season', nil).inspect} not found.")
      next
    end

    simulate = ENV['simulate'] != '0' # Don't change anything unless explicitly requested
    puts("\r\n- season.........: #{season.id}")
    puts("- simulate.......: #{simulate}\r\n\r\n")

    backfill = SeasonBoard::Backfill.new(season:, simulate:).call
    puts(backfill.report.join("\r\n"))
    if backfill.statements.empty?
      puts("\r\nNothing to do: all rows are already up to date.")
    elsif simulate
      puts("\r\n*** SQL (not applied, not saved): ***\r\n")
      puts(backfill.sql_log.join("\r\n"))
    end
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++
end
