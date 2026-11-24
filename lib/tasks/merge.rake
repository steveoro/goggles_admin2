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

# Since phase 13 every task body is a thin caller of the maintenance operations (Maintenance::RakeRunner and its
# adapters in app/services/maintenance/rake_tasks: same texts, prompts and exits). Scripts are registered in the SQL
# Outbox with the next global number, in results.new/misc/ (an explicit index= stays the file prefix): simulate=1 (the
# default) writes them held ('not applied locally'), simulate=0 checks the DB sync gate (force=1 overrides a red
# verdict), applies them locally and only then registers them. The same operations run from /operations.
namespace :merge do
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

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-merge_swimmers-<src_id>-<dest_id>.sql'

    Options: [Rails.env=#{Rails.env}]
             src=<source_swimmer_id>
             dest=<destination_swimmer_id>
             [index=<auto>] [simulate='0'|<'1'>]
             [skip_columns=<'0'>|'1'] [force=<'0'>|'1']

      - index: a progressive number for the generated file;
      - src: source Swimmer ID;
      - dest: destination Swimmer ID;

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - skip_columns: when set to anything different from '0' will enable the "skip" & disable
        overwriting the destination row columns with the source swimmer values. When not skipped,
        the following columns are overwritten: last_name, first_name, year_of_birth, complete_name,
        nickname, associated_user_id, gender_type_id, year_guessed.

      - force: when set to '1' will force the merge even when the checker reports errors
        (e.g. conflicting MIRs in same meeting). Default: '0' (don't force).

  DESC
  task(swimmer: [:check_needed_dirs]) do
    status = Maintenance::RakeRunner.call('merge:swimmer', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
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
      1. Delete deprecated reservation entities for the merged team
      2. Merge shared badge couples inline (via Merge::Badge per couple)
      3. Update orphan merged badges and remaining TA-linked entities
      4. Update team-only links
      5. Run DuplicateResultCleaner as safety net per shared season
      6. Update the kept team columns and delete the merged team
      7. When keep_as_alias=1, move the merged team's aliases to the kept team

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-merge_teams-<src_id>-<dest_id>.sql'

    Options: [Rails.env=#{Rails.env}]
             src=<source_team_id>
             dest=<destination_team_id>
             [index=<auto>] [simulate='0'|<'1'>]
             [skip_columns=<'0'>|'1']
             [keep_as_alias=<'0'>|'1']

      - index: override for a progressive number appended to the name of the generated file;
      - src: source Team ID;
      - dest: destination Team ID;

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default);

      - skip_columns: when set to anything different from '0' will enable the "skip" & disable overwriting
        the kept team row columns with the source team values (toggled on by default).

      - keep_as_alias: when set to '1', the source team is kept as an alias of the destination team.
        The destination row always survives; the source row is deleted. Names and aliases from both
        teams are folded into the destination's name_variations and the source's team_aliases are moved.
        With skip_columns=0, all destination columns (name, editable_name, city_id) are overwritten
        with the source values; with skip_columns=1, the destination keeps its own column values.
        Default: '0' (legacy behaviour: keep destination, overwrite with source, delete source aliases).

  DESC
  task(team: [:check_needed_dirs]) do
    status = Maintenance::RakeRunner.call('merge:team', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
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

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-merge_meetings-<src_id>-<dest_id>.sql'

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
        the destination meeting flag columns (results_acquired, manifest, startlist) with the
        source values (toggled off by default). When not skipped, each flag is set to 1 if the
        source has it true and the destination does not (OR logic).
        Note that only these three flags are carried over from source to destination: description,
        notes and all other columns are NOT copied over by design.

  DESC
  task(meeting: [:check_needed_dirs]) do
    status = Maintenance::RakeRunner.call('merge:meeting', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
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
    also overwriting the destination's team_id, team_affiliation_id and category_type_id with
    the corresponding source badge values when they differ. (Default: OVERWRITE DEST WITH SRC IN SCRIPT.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-merge_badges-<src_id>-<dest_id|autofix>.sql'

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

      - keep_dest_columns: when set to anything different from '0' will make the destination
        team_id, team_affiliation_id and category_type_id be kept instead of being overridden by source.

      - keep_dest_category: same as above, but just for category_type_id.

      - keep_dest_team: same as above, but just for team_id & team_affiliation_id.

      - force: opposite of 'keep_dest_columns'. If no conflict override flags are used,
        the merge will halt in case of conflicting rows (different categories or teams).

      - autofix: when set to '1', the script will toggle the above override flags using some
        educated guesses (toggled off by default).

  DESC
  task(badge: [:check_needed_dirs]) do
    status = Maintenance::RakeRunner.call('merge:badge', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
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

    3. the remaining relay badges (Merge::BadgeSeasonChecker#relay_badges).

    *IMPORTANT NOTES* (since phase 13, operation 'season.badge_fix', see /operations):
    - Each run plans ONE step (the first one with candidates): one SQL script per step,
      'results.new/misc/<index>-season_fix_<season>-step<N>-<step>.sql', each badge in its
      own transaction inside the file (a badge fix may insert a meeting program that the
      next one uses). Badges touching a badge or a new meeting program already planned in
      the step are deferred to the next round.

    - simulate=1 (the default, as for every task): only the first step is written, held in
      the Outbox ('not applied locally'): the next steps need it applied first.
      simulate=0: the DB sync gate first (force=1 overrides a red verdict), then each step
      is applied locally and registered, in a loop, until nothing is left or nothing changes.

    - Without src_team EVERY candidate is processed (before phase 13 none was, by mistake).
      The 'possible' merges (possible=1) require a src_team.

    Options: [Rails.env=#{Rails.env}]
             season=<source_season_id>
             index=[file_index_start_override|<auto>]
             [simulate='0'|<'1'>] [force=<'0'>|'1']
             possible=[<0>|1]
             [src_team=<source_team_id> dest_team=<dest_team_id>]

      - season: source Season ID to be checked & fixed;
      - index: an ovverride index for the generated files (default: <auto>);
      - simulate: when set to '0' the steps are applied locally (default: '1', first step held);

      - possible: process and consider also the "possible badge merges" for fixing;
                  requires a src_team (unfiltered, this can be data damaging!)

      - src_team: when present, it may require a 'dest_team' for forcing conflicts during merges;
                  allows to filter and process only the specified src_team for fixing/forcing;
                  (note that the merger class may halt if no dest_team is specified and a conflict
                  is found)

      - dest_team: when present requires also a 'src_team'; as stated above,
                  all 'src_team' badges will overwrite 'dest_team's values using a forced
                  merge whenever required; otherwise, src_team badges will be processed
                  using the "autofix" mode.

  DESC
  task(season_fix: [:check_needed_dirs]) do
    status = Maintenance::RakeRunner.call('merge:season_fix', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
    Merge wrongly-assigned team results within a single meeting.

    This task merges all results (MIRs, MRRs, laps, relay_laps) from a wrong team
    to the correct team within a specific meeting, and cleans up duplicates.

    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-merge_team_in_meeting-<meeting_id>-<src_id>-to-<dest_id>.sql'

    Options: [meeting=<meeting_id> src=<wrong_team_id> dest=<good_team_id> simulate=<0>|1 index=N full_report=1]
    - meeting:     the Meeting ID (required)
    - src:         the source (wrong) Team ID (required)
    - dest:        the destination (correct) Team ID (required)
    - simulate:    when set to '0', the script will be executed locally (default: 1)
    - index:       override the default progressive file index (default: auto)
    - full_report: when set to '1', displays all IDs (10 per row) and badge merge commands (default: 0)

  DESC
  task(team_in_1_meeting: [:check_needed_dirs]) do
    status = Maintenance::RakeRunner.call('merge:team_in_1_meeting', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++
end
