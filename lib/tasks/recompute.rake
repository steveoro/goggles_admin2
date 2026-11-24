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
    puts "*** Task: recompute:ranks - season #{ENV.fetch('season', nil)} ***"
    season = GogglesDb::Season.joins(:meetings).includes(:meetings).find_by(id: ENV['season'].to_i)
    meeting = GogglesDb::Meeting.joins(:meeting_programs).includes(:meeting_programs).find_by(id: ENV['meeting'].to_i) if season.blank?
    if season.nil? && meeting.nil?
      puts('You need a valid Season ID or Meeting ID to proceed.')
      exit
    end

    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    # (Recompute::Ranks builds the SQL; the progress lines below come from its events, the output is unchanged)
    ranker = Recompute::Ranks.new(season:, meeting:)
    season = ranker.season
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    # (^^^ Use 'auto_index_from_script_output_dir(season.id)' to get the index from the season subdirectory)
    file_name = "#{format('%04d', file_index)}-#{season.id}-recompute_ranks"
    puts("\r\n#{'- SIMULATE'.ljust(25, '.')}: ✔") if simulate
    puts("- #{ranker.meetings.count} meetings found.")
    puts('')

    ranker.call do |event, payload|
      case event
      when :meeting then puts("- #{payload}:")
      when :program then putc('.')
      when :meeting_done then puts('')
      end
    end

    puts("\r\nGenerating file '#{file_name}'...")
    process_sql_file(file_name:, sql_log_array: ranker.sql_log, simulate:)
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++
end
