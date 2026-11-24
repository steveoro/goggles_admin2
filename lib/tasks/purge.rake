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
# Since phase 13 the task body is a thin caller of the 'meeting.purge' operation (Maintenance::RakeRunner, see
# lib/tasks/merge.rake): the prompt is kept, the script goes to results.new/misc/ with the next Outbox number.
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

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-purge_meeting-<meeting_id>.sql'

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
    status = Maintenance::RakeRunner.call('purge:meeting', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++
end
