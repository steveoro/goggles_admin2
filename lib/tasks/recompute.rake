# frozen_string_literal: true

require 'fileutils'

#
# = Local Data merging/fixing helper tasks
#
#   - (p) FASAR Software 2007-2024
#   - for Goggles framework vers.: 7.00
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

# Since phase 13 the task body is a thin caller of the 'ranks.recompute' operation (Maintenance::RakeRunner, see
# lib/tasks/merge.rake): the script ('<season id>-recompute_ranks') goes to results.new/misc/ with the next Outbox number.
namespace :recompute do
  desc <<~DESC
      Recomputes all ranks for MIRs & MRRs of a whole Season or of a single Meeting,
    scanning MeetingProgram by MeetingProgram and creating an output SQL script.

    This is usually required after deleting duplicate MIRs or MRRs using the 'merge' tasks.
    It's possible to specify also a single Meeting#id to process instead of the whole Season.

    Options: [Rails.env=#{Rails.env}]
             [season=<season_id>|meeting=meeting_id]
             [simulate='0'|<'1'>]
             index=[file_index_start_override|<auto>]

      - season: Season ID to be processed & updated; has priority over meeting ID;
      - meeting: single Meeting ID to be processed instead of the whole Season (don't specify season ID in this case);
      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);
      - index: an ovverride index for the generated files (default: <auto>);

  DESC
  task(ranks: ['merge:check_needed_dirs']) do
    status = Maintenance::RakeRunner.call('recompute:ranks', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++
end
