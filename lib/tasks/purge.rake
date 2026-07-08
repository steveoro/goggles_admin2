# frozen_string_literal: true

require 'fileutils'

#
# = Local Data purge helper tasks
#
#   - (p) FASAR Software 2007-2026
#   - for Goggles framework vers.: 7.00
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++
namespace :purge do
  desc <<~DESC
      Generates a replayable SQL script that purges all data associated
    to a specific meeting, respecting the FK hierarchy bottom-up.

    The resulting script won't be applied (and no DB changes will be made)
    *unless* the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    When 'stop_at_events' is set to '1', the purge stops at meeting_programs,
    leaving events, sessions, reservations, team scores, calendar, and the
    meeting row itself intact (default: '0' — full purge).

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/<index>-purge_meeting-<meeting_id>.sql'

    Options: [Rails.env=#{Rails.env}]
             meeting=<meeting_id>
             [simulate='0'|<'1'>]
             [index=<auto>]
             [stop_at_events='0'|<'1'>]

      - meeting: the target Meeting ID (must exist);
      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);
      - index: a progressive number for the generated file;
      - stop_at_events: when set to '1', stops purge at meeting_programs (steps 1-8 only),
        leaving events, sessions, reservations, team scores, calendar, and the meeting row intact.

  DESC
  task(meeting: ['merge:check_needed_dirs']) do
    puts '*** Task: purge:meeting ***'
    meeting = GogglesDb::Meeting.find_by(id: ENV['meeting'].to_i)
    if meeting.nil?
      puts("You need a valid 'meeting' ID to proceed.")
      exit
    end

    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    stop_at_events = ENV['stop_at_events'] == '1'

    puts("\r\nPurging Meeting #{meeting.id} - #{meeting.description}")
    puts("\r\n- simulate.........: #{simulate}")
    puts("- stop_at_events...: #{stop_at_events}")
    puts("- dest. folder.....: #{SCRIPT_OUTPUT_DIR}\r\n")

    purger = Purge::Meeting.new(meeting:, stop_at_events:)
    purger.display_report

    # Ask for confirmation before generating the file
    print "\r\nProceed with generating purge script? [y/N] "
    response = $stdin.gets&.chomp&.downcase
    unless response == 'y'
      puts('Aborted.')
      exit
    end

    purger.prepare

    file_name = "#{format('%04d', file_index)}-purge_meeting-#{meeting.id}"
    process_sql_file(file_name:, sql_log_array: purger.single_transaction_sql_log, simulate:)
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++
end
