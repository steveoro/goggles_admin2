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
    season ||= meeting.season if meeting
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    # (^^^ Use 'auto_index_from_script_output_dir(season.id)' to get the index from the season subdirectory)
    file_name = "#{format('%04d', file_index)}-#{season.id}-recompute_ranks"
    meetings = meeting.present? ? [meeting] : season.meetings.joins(:meeting_programs).includes(:meeting_programs)
    puts("\r\n#{'- SIMULATE'.ljust(25, '.')}: ✔") if simulate
    puts("- #{meetings.count} meetings found.")
    puts('')

    sql_log = Merge::Badge.start_transaction_log.dup + ["--\r\n-- *** Recompute ranks: season #{season.id}, #{meetings.count} meeting(s) ***\r\n--\r\n"]
    meetings.each_with_index do |m, index|
      description = "Meeting #{index + 1}/#{meetings.count}, ID #{m.id} '#{m.description}', " \
                    "MIRs: #{m.meeting_individual_results.count}, MRRs: #{m.meeting_relay_results.count}"
      puts("- #{description}:")
      sql_log << "-- #{description}"
      m.meeting_programs.each do |meeting_program|
        rows = meeting_program.relay? ? meeting_program.meeting_relay_results : meeting_program.meeting_individual_results
        with_time = rows.by_timing.to_a.keep_if { |row| row.to_timing.positive? }
        with_no_time = rows.by_timing.to_a.keep_if { |row| row.to_timing.zero? }

        (with_time + with_no_time).each_with_index do |row, row_index|
          next if row.rank == row_index + 1

          sql_log << "UPDATE #{row.class.table_name} SET updated_at=NOW(), rank=#{row_index + 1} WHERE id = #{row.id}; " \
                     "-- MPrg: #{meeting_program.id}, #{row.to_timing}"
          # DEBUG: add to the above: " -- MPrg: #{meeting_program.id}, #{row.to_timing}"
        end
        putc('.')
      end
      puts('')
    end

    sql_log += Merge::Badge.end_transaction_log
    puts("\r\nGenerating file '#{file_name}'...")
    process_sql_file(file_name:, sql_log_array: sql_log, simulate:)
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++
end
