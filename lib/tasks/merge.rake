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

      - '#{SCRIPT_OUTPUT_DIR}/<index>-merge_swimmers-<src_id>-<dest_id>.sql'

    Options: [Rails.env=#{Rails.env}]
             src=<source_swimmer_id>
             dest=<destination_swimmer_id>
             [index=<0>] [simulate='0'|<'1'>]
             [skip_columns=<'0'>|'1']

      - index: a progressive number for the generated file;
      - src: source Swimmer ID;
      - dest: destination Swimmer ID;

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - skip_columns: when set to anything different from '0' will enable the "skip" & disable overwriting
        destination row columns with the source swimmer values (toggled on by default).

  DESC
  task(swimmer: [:check_needed_dirs]) do
    puts '*** Task: merge:swimmer ***'
    source = GogglesDb::Swimmer.find_by(id: ENV['src'].to_i)
    dest = GogglesDb::Swimmer.find_by(id: ENV['dest'].to_i)
    file_index = ENV['index'].to_i
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

    merger = Merge::Swimmer.new(source:, dest:, skip_columns:)
    merger.prepare
    puts('Aborted.') && break if merger.errors.present?

    process_sql_file(file_index:, title: 'merge_swimmers', merger:, sql_log_array: merger.sql_log, simulate:)
    puts("Done.\r\n")
  end
  #-- -------------------------------------------------------------------------
  #++

  # Creates an SQL file under #{SCRIPT_OUTPUT_DIR} which will merge
  # the source row into the dest row.
  # The file name have the format: "<index>-<title>-<source_id>-<dest_id|autofix>.sql"
  # The method will execute also the script on localhost only when 'simulate' is +false+.
  def process_sql_file(file_index:, title:, merger:, sql_log_array:, simulate: true) # rubocop:disable Metrics/AbcSize,Rake/MethodDefinitionInTask
    dest_id_label = merger.dest ? merger.dest.id : 'autofix'
    sql_file_name = "#{SCRIPT_OUTPUT_DIR}/#{format('%03d', file_index)}-#{title}-#{merger.source.id}-#{dest_id_label}.sql"
    File.open(sql_file_name, 'w+') { |f| f.puts(sql_log_array.join("\r\n")) }
    puts("\r\n*** Log: ***\r\n")
    puts(merger.log.join("\r\n"))
    puts("\r\nFile '#{sql_file_name}' saved.")

    if simulate
      puts("\r\n\t\t>>> NOTHING WAS DONE TO THE DB: THIS WAS JUST A SIMULATION <<<\r\n")
      puts("\r\n--> Remember to use the 'simulate=0' option to actually run the generated script!")
    else
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
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Checks and analyzes for issues a WHOLE Season by checking the overall
    hierarchy integrity of badges.

    The resulting report will suggest:

    - possible team merges;
    - possible badge merges;
    - badge duplication & wrong category assignments

    Options: [Rails.env=#{Rails.env}]
             season=<source_season_id>

      - season: source Season ID to be checked;

  DESC
  task(season_check: [:environment]) do
    puts '*** Task: merge:season_check ***'
    season = GogglesDb::Season.find_by(id: ENV['season'].to_i)
    if season.nil?
      puts("You need a valid 'season' ID to proceed.")
      exit
    end

    checker = Merge::BadgeSeasonChecker.new(season:)
    checker.run
    checker.display_report
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Just checks for Badge merge/fix feasibility reporting any issues on the console.

    Two Badge rows are considered "mergeable" if *none* of the linked sibling entities
    have a shared "parent container" entity with an linked different timing result.

    E.g. - Two badges for the same swimmer are mergeable if:
    1. belong to the same season & swimmer;
    2. any MIR/MRS linked to the same MeetingEvent for both badges has the same timing result
       of the other result associated to the different badge.
       Each timing result can belong to a different MeetingProgram, as long as they belong
       to the same event of the other corresponding badge.
    3. any non-result/non-timing row associated to the corresponding other badge has no difference
       in value (otherwise it's not a duplication, but a conflict).

    Conflicts in badges to be merged may be manually overridden only for Team, TeamAffiliation &
    CategoryType value differences.

    Options: [Rails.env=#{Rails.env}]
             src=<source_badge_id>
             dest=<destination_badge_id>

      - src: source badge ID
      - dest: destination badge ID; when missing, the source badge will be checked for "auto-fixing"
              for wrongly assigned categories.

  DESC
  task(badge_check: [:environment]) do
    puts '*** Task: merge:badge_check ***'
    source = GogglesDb::Badge.find_by(id: ENV['src'].to_i)
    dest = GogglesDb::Badge.find_by(id: ENV['dest'].to_i)
    if source.nil?
      puts("You need at least the 'src' ID to proceed.")
      exit
    end

    checker = Merge::BadgeChecker.new(source:, dest:)
    checker.run
    checker.display_report
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Checks for badge merge feasibility before creating an SQL script that merges
    the source badge row into the destination.

    Two badge rows are considered "mergeable" if *none* of the linked sibling entities
    have a shared "parent container" entity.

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The resulting script will merge all linked sub-entities under the single destination row,
    also overwriting the destination columns with the corresponding source badge column
    values. (Default: OVERWRITE DEST WITH SRC IN SCRIPT.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/<index>-merge_badges-<src_id>-<dest_id|autofix>.sql'

    Options: [Rails.env=#{Rails.env}]
             src=<source_badge_id> dest=<destination_badge_id>
             [index=<0>] [simulate='0'|<'1'>]
             [keep_dest_columns=<'0'>|'1'] [keep_dest_category=<'0'>|'1']
             [keep_dest_team=<'0'>|'1'] [force_conflict=<'0'>|'1']

      - index: a progressive number for the generated file;

      - src: source badge ID;

      - dest: destination badge ID; when missing, the source badge will be checked for "auto-fixing"
              for wrongly assigned categories and no merging will be attempted.

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - keep_dest_columns: when set to anything different from '0' will make all destination
        columns values be kept instead of being overridden by source's.

      - keep_dest_category: same as above, but just for category_type_id.

      - keep_dest_team: same as above, but just for team_id & team_affiliation_id.

      - force_conflict: opposite of 'keep_dest_columns'. If no conflict override flags are used,
        the merge will halt in case of conflicting rows (different categories or teams).

  DESC
  task(badge: [:check_needed_dirs]) do
    puts '*** Task: merge:badge ***'
    source = GogglesDb::Badge.find_by(id: ENV['src'].to_i)&.decorate
    dest = GogglesDb::Badge.find_by(id: ENV['dest'].to_i)&.decorate
    if source.nil?
      puts("You need at least the 'src' ID to proceed.")
      exit
    end

    file_index = ENV['index'].to_i
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    keep_dest_columns = ENV['keep_dest_columns'] == '1'
    keep_dest_category = ENV['keep_dest_category'] == '1'
    keep_dest_team = ENV['keep_dest_team'] == '1'
    force_conflict = ENV['force_conflict'] == '1'
    mode = dest.nil? ? 'Fixing ' : 'Merging'

    puts("\r\n#{mode} Badge (#{source.id}) #{source.display_label}, season #{source.season_id}")
    puts("======= team #{source.team_id}, category_type #{source.category_type_id} (#{source.category_type.code})")
    if dest
      puts('    |')
      puts("    +=> (#{dest.id}) #{dest.display_label}, season #{dest.season_id}")
      puts("        team #{dest.team_id}, category_type #{dest.category_type_id} (#{dest.category_type.code})\r\n")
    end
    puts("#{"\r\n- SIMULATE".ljust(50, '.')}: ✔") if simulate
    puts("#{'- keep ALL dest. columns'.ljust(50, '.')}: ✔") if keep_dest_columns
    puts("#{'- keep dest. category'.ljust(50, '.')}: ✔") if keep_dest_category
    puts("#{'- keep dest. team'.ljust(50, '.')}: ✔") if keep_dest_team
    puts("#{'- enforce ALL source columns conflicts'.ljust(50, '.')}: ✔") if force_conflict
    puts("#{'- destination folder'.ljust(50, '.')}: #{SCRIPT_OUTPUT_DIR}")

    merger = Merge::Badge.new(
      source:, dest:, keep_dest_columns:, keep_dest_category:,
      keep_dest_team:, force_conflict:
    )
    merger.prepare
    puts('Aborted.') && break if merger.errors.present?

    process_sql_file(file_index:, title: 'merge_badges', merger:, sql_log_array: merger.single_transaction_sql_log, simulate:)
    puts("Done.\r\n")
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Checks, analyzes and then tries to fix automatically *most* of the issues
    found in a WHOLE Season by checking the overall hierarchy integrity of badges.

    The task will output a single SQL script that will address only:

    1. "sure" badge merges, i.e. when the source and destination badges share the same
       swimmer & season;
       (list of badges taken from Merge::BadgeSeasonChecker#sure_badge_merges)

    2. wrongly assigned categories, i.e. relay-only categories assigned to a swimmer
       badge;
       (list of badges taken from Merge::BadgeSeasonChecker#relay_only_badges)

    Options: [Rails.env=#{Rails.env}]
             season=<source_season_id>

      - season: source Season ID to be checked;

  DESC
  task(season_fix: [:environment]) do
    puts '*** Task: merge:season_check ***'
    season = GogglesDb::Season.find_by(id: ENV['season'].to_i)
    if season.nil?
      puts("You need a valid 'season' ID to proceed.")
      exit
    end

    checker = Merge::BadgeSeasonChecker.new(season:)
    checker.run
    checker.display_report
  end
  #-- -------------------------------------------------------------------------
  #++
end
