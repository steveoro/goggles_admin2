# frozen_string_literal: true

require 'fileutils'

#
# = Local Deployment helper tasks
#
#   - (p) FASAR Software 2007-2024
#   - for Goggles framework vers.: 7.00
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

SCRIPT_OUTPUT_DIR = Rails.root.join('crawler/data/results.new').freeze unless defined? SCRIPT_OUTPUT_DIR
#-- ---------------------------------------------------------------------------
#++

namespace :merge do # rubocop:disable Metrics/BlockLength
  desc 'Check and creates missing directories needed by the structure assumed by some of the merge tasks.'
  task(check_needed_dirs: :environment) do
    [
      SCRIPT_OUTPUT_DIR
      # (add here any other needed folder)
    ].each do |folder|
      puts "Checking existence of #{folder} (and creating it if missing)..."
      FileUtils.mkdir_p(folder) unless File.directory?(folder)
    end
    puts "\r\n"
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Just checks for Swimmer merge feasibility reporting any issues on the console.

    Two swimmer rows are considered "mergeable" if *none* of the linked sibling entities
    have a shared "parent container" entity.

    For instance, no 2 different relay swimmers (src & dest) should be linked to the
    same MeetingRelayResult. This rule is currently set "stricter" for MIRs, which
    in order to be mergeable must not belong to the same Meeting, and conversely more
    loosen for Badges, which can even be shared (between src and dest) among the same
    Season (2 different badges may have been created for the 2 slightly different swimmers
    during 2 different data-import procedures due to mis-parsing).

    Options: [Rails.env=#{Rails.env}]
             src=<source_swimmer_id>
             dest=<destination_swimmer_id>

      - src: source Swimmer ID
      - dest: destination Swimmer ID

  DESC
  task(swimmer_check: [:environment]) do
    puts '*** Task: merge:swimmer_check ***'
    source = GogglesDb::Swimmer.find_by(id: ENV['src'].to_i)
    dest = GogglesDb::Swimmer.find_by(id: ENV['dest'].to_i)
    if source.nil? || dest.nil?
      puts("You need both 'src' & 'dest' IDs to proceed.")
      exit
    end

    checker = Merge::SwimmerChecker.new(source:, dest:)
    checker.run
    checker.display_report
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Checks for Swimmer merge feasibility before creating an SQL script that merges
    the source Swimmer row into the destination.

    Two swimmer rows are considered "mergeable" if *none* of the linked sibling entities
    have a shared "parent container" entity.

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The resulting script will merge all linked sub-entities under the single destination row,
    also overwriting the destination columns with the corresponding source Swimmer column
    values. (Default: OVERWRITE DEST WITH SRC IN SCRIPT.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/merge_swimmers-<src_id>-<dest_id>.sql'

    Options: [Rails.env=#{Rails.env}]
             src=<source_swimmer_id>
             dest=<destination_swimmer_id>
             [simulate='0'|<'1'>]
             [skip_columns='0'|<'1'>]

      - src: source Swimmer ID;

      - dest: destination Swimmer ID;

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - skip_columns: when set to anything different from '1' will disable overwriting
        destination row columns with the source swimmer values (toggled on by default).

  DESC
  task(swimmer: [:check_needed_dirs]) do
    puts '*** Task: merge:swimmer ***'
    source = GogglesDb::Swimmer.find_by(id: ENV['src'].to_i)
    dest = GogglesDb::Swimmer.find_by(id: ENV['dest'].to_i)
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    skip_columns = ENV['skip_columns'] == '1' # Don't skip columns unless requested

    puts("\r\nMerging '#{source&.complete_name}' (#{source&.id}) |=> '#{dest&.complete_name}' (#{dest&.id})")
    puts("\r\n- simulate.......: #{simulate}")
    puts("- skip_columns...: #{skip_columns}")
    puts("- dest. folder...: #{SCRIPT_OUTPUT_DIR}\r\n")
    if source.nil? || dest.nil?
      puts("You need both 'src' & 'dest' IDs to proceed.")
      exit
    end

    merge = Merge::Swimmer.new(source:, dest:, skip_columns:)
    merge.prepare
    puts('Aborted.') && break if merge.errors.present?

    sql_file_name = "#{SCRIPT_OUTPUT_DIR}/merge_swimmers-#{source.id}-#{dest.id}.sql"
    File.open(sql_file_name, 'w+') { |f| f.puts(merge.sql_log.join("\r\n")) }
    puts("File '#{sql_file_name}' saved.")
    puts("\r\n*** Log: ***\r\n")
    puts(merge.log.join("\r\n"))
    exit if simulate

    puts("\r\n--> Executing script on localhost...")
    # NOTE: for security reasons, ActiveRecord::Base.connection.execute() executes just the first
    # command when passed multiple staments. This is somewhat overlooked and not properly documented
    # in the docs as of this writing. We'll use the MySql client for this one:
    rails_config = Rails.configuration
    db_name      = rails_config.database_configuration[Rails.env]['database']
    db_user      = rails_config.database_configuration[Rails.env]['username']
    db_pwd       = rails_config.database_configuration[Rails.env]['password']
    db_host      = rails_config.database_configuration[Rails.env]['host']
    system("mysql --host=#{db_host} --user=#{db_user} --password=\"#{db_pwd}\" --database=#{db_name} --execute=\"\\. #{sql_file_name}\"")

    puts("\r\nDone.\r\n")
  end
  #-- -------------------------------------------------------------------------
  #++
end
