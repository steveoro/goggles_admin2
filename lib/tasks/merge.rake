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
      Analyzes the Team merge process before creating a single-transaction SQL script
    that will merge the source Team row into the destination, including full duplicate
    elimination for shared badges and their sub-entities (MIRs, MRSs, Laps, etc.).

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The resulting script will:
      1. Delete deprecated reservation entities for the source team
      2. Merge shared badge couples inline (via Merge::Badge per couple)
      3. Update orphan source badges and remaining TA-linked entities
      4. Update team-only links
      5. Run DuplicateResultCleaner as safety net per shared season
      6. Overwrite destination team columns and delete the source team

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
        destination row columns with the source team values (toggled on by default).

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
      Merges two Meeting entities belonging to the same Season.
    All sub-entities from the source meeting will be moved to the destination,
    creating missing rows or updating existing ones, ensuring no duplicates.

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/<index>-merge_meetings-<src_id>-<dest_id>.sql'

    A separate warning log file will also be generated with timing conflicts and
    other non-fatal issues encountered during the merge.

    Options: [Rails.env=#{Rails.env}]
            src=<source_meeting_id>
            dest=<destination_meeting_id>
            [index=<auto>] [simulate='0'|<'1'>]
            [skip_columns=<'0'>|'1']

      - index: a progressive number for the generated file;
      - src: source Meeting ID;
      - dest: destination Meeting ID;

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - skip_columns: when set to anything different from '0' will disable overwriting
        destination meeting flag columns with the source values (toggled off by default).
        Note that only meeting flags are carried over from source to destination: description,
        notes and all other columns are NOT copied over by design.

  DESC
  task(meeting: [:check_needed_dirs]) do
    puts '*** Task: merge:meeting ***'
    source = GogglesDb::Meeting.find_by(id: ENV['src'].to_i)
    dest = GogglesDb::Meeting.find_by(id: ENV['dest'].to_i)
    if source.nil? || dest.nil?
      puts("You need to have both 'src' & 'dest' IDs with valid values in order to proceed.")
      exit
    end

    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    simulate = ENV['simulate'] != '0' # Don't run locally the script unless explicitly requested
    skip_columns = ENV['skip_columns'] == '1' # Don't skip columns unless requested

    puts("\r\nMerging Meeting (#{source.id}) '#{source.description}'")
    puts("    |=> (#{dest.id}) '#{dest.description}'")
    puts("    Season: #{source.season_id}")
    puts("\r\n- simulate.......: #{simulate}")
    puts("- skip_columns...: #{skip_columns}")
    puts("- dest. folder...: #{SCRIPT_OUTPUT_DIR}\r\n")

    merger = Merge::Meeting.new(source:, dest:, skip_columns:)
    result = merger.prepare
    unless result
      puts('Aborted due to errors.')
      merger.display_report
      break
    end

    puts("\r\n*** Checker Log: ***\r\n")
    puts(merger.log.join("\r\n"))

    file_name = "#{format('%04d', file_index)}-merge_meetings-#{merger.source.id}-#{merger.dest.id}"
    process_sql_file(file_name:, sql_log_array: merger.sql_log, simulate:)

    # Also save warning log if present
    if merger.warning_log.present?
      warning_file = "#{SCRIPT_OUTPUT_DIR}/#{file_name}-warnings.log"
      File.open(warning_file, 'w+') { |f| f.puts(merger.warning_log.join("\r\n")) }
      puts("\r\nWarning log saved to: #{warning_file}")
      puts("Total warnings: #{merger.warning_log.count}")
    end
    merger.verify_merge_result unless simulate

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
             [keep_dest_team=<'0'>|'1'] [force=<'0'>|'1']

      - index: override for a progressive number appended to the name of the generated file;

      - src: source badge ID;

      - dest: destination badge ID; when missing, the source badge will be checked for "auto-fixing"
              for wrongly assigned categories and no merging will be attempted.

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - keep_dest_columns: when set to anything different from '0' will make all destination
        columns values be kept instead of being overridden by source's.

      - keep_dest_category: same as above, but just for category_type_id.

      - keep_dest_team: same as above, but just for team_id & team_affiliation_id.

      - force: opposite of 'keep_dest_columns'. If no conflict override flags are used,
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
    force = ENV['force'] == '1'
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
    puts("#{'- enforce ALL source columns conflicts'.ljust(50, '.')}: ✔") if force
    puts("#{'- destination folder'.ljust(50, '.')}: #{SCRIPT_OUTPUT_DIR}")

    merger = Merge::Badge.new(
      source:, dest:, keep_dest_columns:, keep_dest_category:,
      keep_dest_team:, force:, autofix:
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
       swimmer & season with the same team (different category or not), or whenever the
       team is different but the swimmer has been found enrolled more than once in one or
       more meetings with different badges (as no swimmer can be enrolled in the same
       meeting more than once using different teams);
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
             possible=[<0>|1]
             [src_team=<source_team_id> dest_team=<dest_team_id>]

      - season: source Season ID to be checked & fixed;
      - index: an ovverride index for the generated files (default: <auto>);

      - possible: process and consider also the "possible badge merges" for fixing;
                  WARNING: unless filtered with a src_team, this can be data damaging!

      - src_team: when present, it may require a 'dest_team' for forcing conflicts during merges;
                  allows to filter and process only the specified src_team for fixing/forcing;
                  (note that the merger class may halt if no dest_team is specified and a conflict
                  is found)

      - dest_team: when present requires also a 'src_team'; as stated above,
                  all 'src_team' badges will overwrite 'dest_team's values using a forced
                  merge whenever required; otherwise, src_team badges will be processed
                  using the "autofix" mode.

  DESC
  task(season_fix: [:check_needed_dirs]) do # rubocop:disable Metrics/BlockLength
    puts "*** Task: merge:season_fix - season #{ENV.fetch('season', nil)} ***"
    season = GogglesDb::Season.find_by(id: ENV['season'].to_i)
    if season.nil?
      puts('You need a valid Season ID to proceed.')
      exit
    end
    src_team = ENV['src_team'].to_i if ENV['src_team'].present?
    dest_team = ENV['dest_team'].to_i if ENV['dest_team'].present?
    if dest_team.present? && src_team.nil?
      puts('You need also a valid src_team when specifying a dest_team to force merges.')
      exit
    end

    puts('')
    consider_possible_merges = ENV['possible'] == '1'
    puts("Filtering only badges for team #{src_team}") if src_team
    puts('Processing also the "possible merge" candindates!') if consider_possible_merges
    puts("[src: #{src_team}] --(will OVERWRITE)--> [dest: #{dest_team}]") if src_team && dest_team
    puts("\r\nWARNING: ⚠ Processing 'possible merges' WITHOUT TEAM FILTERING! ⚠") if consider_possible_merges && src_team.blank?

    puts('--> Running BadgeSeasonChecker to collect candidates...')
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir(season.id)

    checker = Merge::BadgeSeasonChecker.new(season:)
    checker.run
    checker.display_short_summary

    # 0) "Possible Mergeable Badges" (same swimmer, sometimes also with same category, similar team names):
    #    (NOTE: this optional step won't be run multiple times)
    if consider_possible_merges
      array_of_array_of_badges = checker.possible_badge_merges.values.dup
      process_merge_badges(
        step_name: "Step 0: 'POSSIBLE badge merges'",
        subdir: season.id, file_index:,
        array_of_array_of_badges:,
        src_team:, dest_team:
      )
      puts("\r\n--> Refreshing BadgeSeasonChecker results...")
      checker.run
      checker.display_short_summary
    end

    # 1) "Sure Mergeable Badges" (same swimmer, same event, even when category or team differs):
    #    Note that merge candidates are paired in couples and just the first match is stored in
    #   "sure_badge_merges": all other candidates need more runs.
    while checker.sure_badge_merges.present?
      array_of_array_of_badges = checker.sure_badge_merges.values.dup
      process_merge_badges(
        step_name: "Step 1: 'sure badge merges'",
        subdir: season.id, file_index:,
        array_of_array_of_badges:,
        src_team:, dest_team:
      )

      puts("\r\n--> Refreshing BadgeSeasonChecker results...")
      checker.run
      checker.display_short_summary
      # Try a new analysis if some badges were actually fixed (and result sizes are different)
      if checker.sure_badge_merges.values.size == array_of_array_of_badges.size
        puts("\r\n--> No changes detected: moving on...")
        break # Bail out on no changes
      else
        puts("\r\n--> Some residual merge candidates found: re-running step 1...")
      end
    end

    # 2) Relay-only Badges linked to a relay category and without a known alternative inside same season:
    while checker.relay_only_badges.present?
      array_of_array_of_badges = checker.relay_only_badges.dup
      process_merge_badges(
        step_name: "Step 2: 'relay-only' badges",
        subdir: season.id,
        array_of_array_of_badges:,
        src_team:, dest_team:
      )

      puts("\r\n--> Refreshing BadgeSeasonChecker results...")
      checker.run
      checker.display_short_summary
      # Try a new analysis if some badges were actually fixed (and result sizes are different)
      if checker.relay_only_badges.size == array_of_array_of_badges.size
        puts("\r\n--> No changes detected: moving on...")
        break # Bail out on no changes
      else
        puts("\r\n--> Some relay-only candidates found: re-running step 2...")
      end
    end

    # 3) Remaining Badges linked to a relay category and with possibly an alternative category:
    while checker.relay_badges.present?
      array_of_array_of_badges = checker.relay_badges.dup
      process_merge_badges(
        step_name: 'Step 3: remaining relay badges',
        subdir: season.id,
        array_of_array_of_badges:,
        src_team:, dest_team:
      )

      puts("\r\n--> Refreshing BadgeSeasonChecker results...")
      checker.run
      if checker.relay_badges.present? && src_team.nil?
        puts("\r\n--> Some relay candidates found: re-running step 3...")
        checker.display_short_summary
      else
        checker.display_report
      end
      # Don't re-run the process if a src_team is specified (as filtering badges may impede the clearing of all candidates):
      break if src_team.present?
    end
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++

  # Creates the specified file under #{SCRIPT_OUTPUT_DIR} by concatenating the log array into
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

  private

  # Runs the script on the specified subset of badges, measuring its execution time and
  # generating a single SQL script for each call.
  #
  # == Options:
  # - <tt>:array_of_array_of_badges</tt> => the list of badges to process; it can either be an actual
  #   array of array of Badge instances, or just an array of Badges for autofixing their category type;
  #
  # - <tt>:subdir</tt> => optional subdirectory name under #{SCRIPT_OUTPUT_DIR} in which the files are stored;
  #
  # - <tt>step_name</tt> => the name of the current step displayed on screen;
  #
  # - <tt>file_index</tt> => optional index start override for the SQL scripts in the output directory;
  #   (default: auto)
  #
  # - <tt>src_team</tt> => Team ID for badge filtering; only badges belonging to this team will be processed;
  #
  # - <tt>dest_team</tt> => Team ID that will be overwritten by the source badges when a matching source badge.
  #   will be found. (Only destination badges belonging to this team will be "forced" for a merge; others will
  #   be processed using the usual "autofix" behavior.)
  #
  def process_merge_badges(options = {}) # rubocop:disable Rake/MethodDefinitionInTask,Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
    array_of_array_of_badges = options[:array_of_array_of_badges]
    return if array_of_array_of_badges.blank?

    subdir = options[:subdir]
    step_name = options[:step_name]
    src_team = options[:src_team].to_i
    dest_team = options[:dest_team].to_i
    file_index = options[:file_index]
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
          # Process only source teams if it's requested:
          next if src_team && source.team_id != src_team

          # Whenever we have a matching dest. badge, force all destination
          # values into source in case of conflicts:
          merger = if dest_team && dest && dest&.team_id == dest_team
                     Merge::Badge.new(source:, dest:, force: true)
                   else
                     # Rely on autofix otherwise:
                     Merge::Badge.new(source:, dest:, autofix: true)
                   end
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

  desc <<~DESC
    Merge wrongly-assigned team results within a single meeting.

    This task merges all results (MIRs, MRRs, laps, relay_laps) from a wrong team
    to the correct team within a specific meeting, and cleans up duplicates.

    Options: [meeting=<meeting_id> src=<wrong_team_id> dest=<good_team_id> simulate=<0>|1 index=N full_report=1]
    - meeting:     the Meeting ID (required)
    - src:         the source (wrong) Team ID (required)
    - dest:        the destination (correct) Team ID (required)
    - simulate:    when set to '0', the script will be executed locally (default: 1)
    - index:       override the default progressive file index (default: auto)
    - full_report: when set to '1', displays all IDs (10 per row) and badge merge commands (default: 0)

  DESC
  task(team_in_1_meeting: [:check_needed_dirs]) do
    puts '*** Task: merge:team_in_1_meeting ***'
    meeting = GogglesDb::Meeting.find_by(id: ENV.fetch('meeting', nil).to_i)
    src_team = GogglesDb::Team.find_by(id: ENV.fetch('src', nil).to_i)
    dest_team = GogglesDb::Team.find_by(id: ENV.fetch('dest', nil).to_i)

    if meeting.nil? || src_team.nil? || dest_team.nil?
      puts("You need valid 'meeting', 'src' & 'dest' IDs to proceed.")
      puts('  meeting: Meeting ID')
      puts('  src:     source (wrong) Team ID')
      puts('  dest:    destination (correct) Team ID')
      exit
    end

    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    simulate = ENV['simulate'] != '0'
    full_report = ENV['full_report'] == '1'

    puts("\r\nMeeting: #{meeting.id} - #{meeting.decorate.display_label}")
    puts("Merging Team '#{src_team.name}' (#{src_team.id}) |=> '#{dest_team.name}' (#{dest_team.id})")
    puts("\r\n- simulate.......: #{simulate}")
    puts("- full_report....: #{full_report}")
    puts("- dest. folder...: #{SCRIPT_OUTPUT_DIR}\r\n")

    begin
      merger = Merge::TeamInMeeting.new(meeting:, src_team:, dest_team:, full_report:, index: file_index)
    rescue ArgumentError => e
      puts("\r\n*** ERROR: #{e.message}")
      exit
    end

    puts("\r\n*** Preview Report: ***\r\n")
    merger.display_report

    # Always ask for confirmation
    print "\r\nProceed with merge? [y/N] "
    response = $stdin.gets&.chomp&.downcase
    unless response == 'y'
      puts('Aborted.')
      exit
    end

    puts("\r\nPreparing SQL script...")
    merger.prepare

    file_name = "#{format('%04d', file_index)}-merge_team_in_meeting-#{meeting.id}-#{src_team.id}-to-#{dest_team.id}"
    process_sql_file(file_name:, sql_log_array: merger.sql_log, simulate:)
    puts('Done.')
  end
  #-- -------------------------------------------------------------------------
  #++
end
