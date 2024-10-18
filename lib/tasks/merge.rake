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
             [index=<auto>] [simulate='0'|<'1'>]
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
    if source.nil? || dest.nil?
      puts("You need to have both 'src' & 'dest' IDs with valid values in order to proceed.")
      exit
    end

    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    skip_columns = ENV['skip_columns'] == '1' # Don't skip columns unless requested

    puts("\r\nMerging '#{source&.complete_name}' (#{source&.id}) |=> '#{dest&.complete_name}' (#{dest&.id})")
    puts("\r\n- simulate.......: #{simulate}")
    puts("- skip_columns...: #{skip_columns}")
    puts("- dest. folder...: #{SCRIPT_OUTPUT_DIR}\r\n")

    merger = Merge::Swimmer.new(source:, dest:, skip_columns:)
    merger.prepare
    puts('Aborted.') && break if merger.errors.present?

    puts("\r\n*** Log: ***\r\n")
    puts(merger.log.join("\r\n"))
    file_name = "#{format('%04d', file_index)}-merge_swimmers-#{merger.source.id}-#{merger.dest.id}"
    process_sql_file(file_name:, sql_log_array: merger.sql_log, simulate:)
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Analyzes the Team merge process before creating an SQL script that will merges
    the source Team row into the destination.

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The resulting script will merge all linked sub-entities under the single destination row,
    also overwriting the destination columns with the corresponding source Swimmer column
    values. (Default: OVERWRITE DEST WITH SRC IN SCRIPT.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/<index>-merge_teams-<src_id>-<dest_id>.sql'

    Options: [Rails.env=#{Rails.env}]
             src=<source_team_id>
             dest=<destination_team_id>
             [index=<auto>] [simulate='0'|<'1'>]
             [skip_columns=<'0'>|'1']

      - index: override for a progressive number appended to the name of the generated file;
      - src: source Team ID;
      - dest: destination Team ID;

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - skip_columns: when set to anything different from '0' will enable the "skip" & disable overwriting
        destination row columns with the source swimmer values (toggled on by default).

  DESC
  task(team: [:check_needed_dirs]) do
    puts '*** Task: merge:team ***'
    source = GogglesDb::Team.find_by(id: ENV['src'].to_i)
    dest = GogglesDb::Team.find_by(id: ENV['dest'].to_i)
    if source.nil? || dest.nil?
      puts("You need to have both 'src' & 'dest' IDs with valid values in order to proceed.")
      exit
    end

    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    skip_columns = ENV['skip_columns'] == '1' # Don't skip columns unless requested

    puts("\r\nMerging '#{source&.name}' (#{source&.id}) |=> '#{dest&.name}' (#{dest&.id})")
    puts("\r\n- simulate.......: #{simulate}")
    puts("- skip_columns...: #{skip_columns}")
    puts("- dest. folder...: #{SCRIPT_OUTPUT_DIR}\r\n")

    merger = Merge::Team.new(source:, dest:, skip_columns:)
    puts("\r\n*** Log: ***\r\n")
    merger.prepare # (no need to diplay the log here, as the merger already does it with #prepare())

    file_name = "#{format('%04d', file_index)}-merge_teams-#{merger.source.id}-#{merger.dest.id}"
    process_sql_file(file_name:, sql_log_array: merger.sql_log, simulate:)
    puts('Done.')
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
             [index=<auto>] [simulate='0'|<'1'>]
             [keep_dest_columns=<'0'>|'1'] [keep_dest_category=<'0'>|'1']
             [keep_dest_team=<'0'>|'1'] [force_conflict=<'0'>|'1']

      - index: override for a progressive number appended to the name of the generated file;

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

      - autofix: when set to '1', the script will toggle the above override flags using some
        educated guesses (toggled off by default).

  DESC
  task(badge: [:check_needed_dirs]) do
    puts '*** Task: merge:badge ***'
    source = GogglesDb::Badge.find_by(id: ENV['src'].to_i)&.decorate
    dest = GogglesDb::Badge.find_by(id: ENV['dest'].to_i)&.decorate
    if source.nil?
      puts("You need at least the 'src' ID with a valid value to proceed.")
      exit
    end

    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir(source.season_id)
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    keep_dest_columns = ENV['keep_dest_columns'] == '1'
    keep_dest_category = ENV['keep_dest_category'] == '1'
    keep_dest_team = ENV['keep_dest_team'] == '1'
    force_conflict = ENV['force_conflict'] == '1'
    autofix = ENV['autofix'] == '1'
    mode = dest.nil? ? 'Fixing ' : 'Merging'

    puts("\r\n#{mode} Badge (#{source.id}) #{source.display_label}, season #{source.season_id}")
    puts("======= team #{source.team_id}, category_type #{source.category_type_id} (#{source.category_type.code})")
    if dest
      puts('    |')
      puts("    +=> (#{dest.id}) #{dest.display_label}, season #{dest.season_id}")
      puts("        team #{dest.team_id}, category_type #{dest.category_type_id} (#{dest.category_type.code})\r\n")
    end
    puts("\r\n#{'- SIMULATE'.ljust(50, '.')}: ✔") if simulate
    puts("#{'- AUTOFIX'.ljust(50, '.')}: ✔") if autofix
    puts("#{'- keep ALL dest. columns'.ljust(50, '.')}: ✔") if keep_dest_columns
    puts("#{'- keep dest. category'.ljust(50, '.')}: ✔") if keep_dest_category
    puts("#{'- keep dest. team'.ljust(50, '.')}: ✔") if keep_dest_team
    puts("#{'- enforce ALL source columns conflicts'.ljust(50, '.')}: ✔") if force_conflict
    puts("#{'- destination folder'.ljust(50, '.')}: #{SCRIPT_OUTPUT_DIR}")

    merger = Merge::Badge.new(
      source:, dest:, keep_dest_columns:, keep_dest_category:,
      keep_dest_team:, force_conflict:, autofix:
    )
    merger.prepare
    puts('Aborted.') && break if merger.errors.present?

    puts("\r\n*** Log: ***\r\n")
    puts(merger.log.join("\r\n"))
    file_name = "#{format('%04d', file_index)}-merge_badges-#{merger.source.id}-#{merger.dest ? merger.dest.id : 'autofix'}"
    process_sql_file(file_name:, sql_log_array: merger.single_transaction_sql_log, simulate:)
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Checks, analyzes and then tries to fix automatically *most* of the issues
    found in a WHOLE Season by checking the overall hierarchy integrity of badges.

    1. "sure" badge merges, i.e. when the source and destination badges share the same
       swimmer & season;
       (list of badges taken from Merge::BadgeSeasonChecker#sure_badge_merges)

    2. wrongly assigned categories, i.e. relay-only categories assigned to a swimmer
       badge;
       (list of badges taken from Merge::BadgeSeasonChecker#relay_only_badges)

    *IMPORTANT NOTES:*
    -->> SINCE THE BADGE-FIX PROCESS MAY REQUIRE TO INSERT NEW MEETING PROGRAMS,     <<--
         EACH BADGE-FIX SCRIPT WILL BE IMMEDIATELY EXECUTED ONE-BY-ONE ON localhost.

    - No *simulation* mode is supported: each file is run right after being generated.

    - An auto-index (format: 'NNN-') is appended at the start of each script name,
      with the index progressing from the greatest index value found already existing
      in the same folder. (format: 'NNN-<script_name>.sql'), because the execution sequence
      will matter in the end.

    - Be advised that this task may generate SEVERAL HUNDREDS of SQL files.

    Options: [Rails.env=#{Rails.env}]
             season=<source_season_id>
             index=[file_index_start_override|<auto>]

      - season: source Season ID to be checked & fixed;
      - index: an ovverride index for the generated files (default: <auto>);

  DESC
  task(season_fix: [:environment]) do # rubocop:disable Metrics/BlockLength
    puts "*** Task: merge:season_fix - season #{ENV.fetch('season', nil)} ***"
    season = GogglesDb::Season.find_by(id: ENV['season'].to_i)
    if season.nil?
      puts('You need a valid Season ID to proceed.')
      exit
    end

    puts('')
    puts('--> Running BadgeSeasonChecker...')
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir(season.id)

    checker = Merge::BadgeSeasonChecker.new(season:)
    checker.run
    checker.display_short_summary

    # 1) "Sure Mergeable Badges" (same swimmer, same event, even when category or team differs):
    #    Note that merge candidates are paired in couples and just the first match is stored in
    #   "sure_badge_merges"; all other candidates need more runs.
    while checker.sure_badge_merges.present?
      process_merge_badges(
        step_name: "Step 1: 'sure badge merges'",
        subdir: season.id, file_index:,
        array_of_array_of_badges: checker.sure_badge_merges.values
      )

      puts("\r\n--> Refreshing BadgeSeasonChecker results...")
      checker.run
      checker.display_short_summary
      puts("\r\n--> Some residual merge candidates found: re-running step 1...") if checker.sure_badge_merges.present?
    end

    # 2) Relay-only Badges linked to a relay category and without a known alternative inside same season:
    while checker.relay_only_badges.present?
      process_merge_badges(
        step_name: "Step 2: 'relay-only' badges",
        subdir: season.id,
        array_of_array_of_badges: checker.relay_only_badges
      )

      puts("\r\n--> Refreshing BadgeSeasonChecker results...")
      checker.run
      checker.display_short_summary
      puts("\r\n--> Some relay-only candidates found: re-running step 2...") if checker.relay_only_badges.present?
    end

    # 3) Remaining Badges linked to a relay category and with possibly an alternative category:
    while checker.relay_badges.present?
      process_merge_badges(
        step_name: 'Step 3: remaining relay badges',
        subdir: season.id,
        array_of_array_of_badges: checker.relay_badges
      )

      puts("\r\n--> Refreshing BadgeSeasonChecker results...")
      checker.run
      if checker.relay_badges.present?
        puts("\r\n--> Some relay candidates found: re-running step 3...")
        checker.display_short_summary
      else
        checker.display_report
      end
    end
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++

  private

  # Creates the specified file under #{SCRIPT_OUTPUT_DIR} by contatenating the log array into
  # a single text file.
  # If 'simulate' is +false+, the resulting script will be also executed on localhost using the MySQL client.
  #
  # == Params:
  # - file_name: the resulting text file name, minus the '.sql' extension;
  # - sql_log_array: the array of SQL statements to be written to the file;
  # - subdir: optional subdirectory name under #{SCRIPT_OUTPUT_DIR} under which the resulting file will be stored;
  # - simulate: when set to '0' will enable script execution on localhost (toggled off by default).
  #
  def process_sql_file(file_name:, sql_log_array:, subdir: nil, simulate: true) # rubocop:disable Rake/MethodDefinitionInTask
    output_dir = subdir ? "#{SCRIPT_OUTPUT_DIR}/#{subdir}" : SCRIPT_OUTPUT_DIR
    FileUtils.mkdir_p(output_dir) unless File.directory?(output_dir)
    sql_file_name = "#{output_dir}/#{file_name}.sql"
    File.open(sql_file_name, 'w+') { |f| f.puts(sql_log_array.join("\r\n")) }
    puts("\r\nFile '#{sql_file_name}' saved.")

    if simulate
      puts("\r\n\t\t>>> NOTHING WAS DONE TO THE DB: THIS WAS JUST A SIMULATION <<<\r\n")
      puts("--> Remember to use the 'simulate=0' option to actually run the generated script!")
    else
      # (See lib/tasks/db.rake for #execute_sql_file())
      execute_sql_file(full_pathname: sql_file_name)
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # Returns the progressive index found at 'SCRIPT_OUTPUT_DIR' for all .sql files present.
  # Expected index format: 'IDX-<filename>.sql'.
  # == Params:
  # - subdir: optional subdirectory name under #{SCRIPT_OUTPUT_DIR} in which the files are stored.
  def auto_index_from_script_output_dir(subdir = nil) # rubocop:disable Rake/MethodDefinitionInTask
    glob_path = subdir ? "#{SCRIPT_OUTPUT_DIR}/#{subdir}/*.sql" : "#{SCRIPT_OUTPUT_DIR}/*.sql"
    Pathname.new(Dir[glob_path].last.to_s).basename.to_s.split('-').first.to_i + 1
  end

  # Runs the script on the specified subset of badges, measuring its execution time and
  # generating a single SQL script for each call.
  #
  # == Params:
  # - array_of_array_of_badges: the list of badges to process; it can either be an actual array of array of Badge
  #   instances, or just an array of Badges for autofixing their category type;
  # - subdir: optional subdirectory name under #{SCRIPT_OUTPUT_DIR} in which the files are stored;
  # - step_name: the name of the current step displayed on screen;
  # - file_index: optional index start override for the SQL scripts in the output directory; (default: auto)
  #
  def process_merge_badges(array_of_array_of_badges:, subdir:, step_name:, file_index: nil) # rubocop:disable Rake/MethodDefinitionInTask,Metrics/AbcSize
    return if array_of_array_of_badges.blank?

    puts("\r\n--> #{step_name}: #{array_of_array_of_badges.count}. Preparing SQL script...")
    # Get the next available index for the SQL scripts in the output directory (or 1 if none):
    file_index ||= auto_index_from_script_output_dir(subdir)
    slice_size = 10

    array_of_array_of_badges.each_slice(slice_size).with_index do |badges_slice, idx|
      tms = Benchmark.measure do
        badges_slice.each do |merge_candidates|
          # Detect category fix (no destination) or actual merge (dest: first <=| source: second):
          source = merge_candidates.respond_to?(:second) ? merge_candidates.second : merge_candidates
          dest = merge_candidates.respond_to?(:first) ? merge_candidates.first : nil
          merger = Merge::Badge.new(source:, dest:, autofix: true)
          merger.prepare

          # NOTE: keep & run each badge-fix script in a separate transaction
          # --> See: app/strategies/merge/badge.rb:537#handle_mprogram_insert_or_select()
          file_name = "#{format('%04d', file_index)}-season_fix_#{source.season_id}-merge_badges-#{source.id}-#{dest ? dest.id : 'autofix'}"

          process_sql_file(file_name:, sql_log_array: merger.single_transaction_sql_log, subdir:, simulate: false)
          file_index += 1
        end
      end
      puts("[Total time for #{slice_size}x runs: #{tms.total}\", progress: #{badges_slice.size + (idx * slice_size)}/#{array_of_array_of_badges.count}]")
    end
  end
  #-- -------------------------------------------------------------------------
  #++
end
