# frozen_string_literal: true

#
# = Local Data fixing helper tasks
#
#   - (p) FASAR Software 2007-2026
#   - for Goggles framework vers.: 7.00
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

SCRIPT_OUTPUT_DIR = Rails.root.join('crawler/data/results.new').freeze unless defined? SCRIPT_OUTPUT_DIR

# Since phase 13 every task body is a thin caller of the maintenance operations (Maintenance::RakeRunner, see
# lib/tasks/merge.rake): scripts in results.new/misc/ with the next Outbox number, held with simulate=1.
namespace :fix do
  desc <<~DESC
      Fixes a wrongly-assigned team_id on one or more badges (also across multiple seasons).

    Updates all related results (MIRs, laps, MRRs, relay_laps) with the correct team_id
    and deletes meeting entries and reservations for the affected badges.

    Related badges discovered via MRS → MRR cascade (relay teammates) are included
    automatically for data coherence.

    The task halts if any swimmer in the batch already has a badge on the destination team
    for the same season
    (those are candidates for badge merge, not badge fix).

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '[DEFAULT_OUTPUT_DIR]/misc/<index>-fix_team_in_badge-<badge_ids>.sql'

    Options: [Rails.env=#{Rails.env}]
             badge=<badge_id1[,badge_id2,...]> team=<correct_team_id>
             [index=<auto>] [simulate='0'|<'1'>] [nuke_team=<'0'>|'1']

      - badge: comma-separated list of Badge IDs to fix (can span multiple seasons);

      - team: the correct (destination) Team ID;

      - index: override for a progressive number appended to the name of the generated file
               (default: auto-detected from existing files in output dir);

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default).

      - nuke_team: when set to '1' allows reusing/remapping existing TeamAffiliations from the wrong team.
                   WARNING: THIS MAY REASSIGN ALL ROWS LINKED TO THE REUSED TEAM_AFFILIATION IDS,
                   NOT JUST THE SUPPLIED BADGES. USE ONLY WHEN YOU EXPLICITLY WANT THAT BROAD EFFECT.

  DESC
  task(team_in_badge: ['merge:check_needed_dirs']) do
    status = Maintenance::RakeRunner.call('fix:team_in_badge', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end

  desc <<~DESC
      Fixes a wrongly-assigned swimmer_id on one or more badges (also across multiple seasons).

    Updates all related badge-linked entities (MIRs, laps, MRSs, relay_laps,
    meeting entries and reservations) with the correct swimmer_id.

    The task halts if any destination swimmer/team/season tuple already has a badge
    (those are candidates for badge merge, not badge fix).

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '[DEFAULT_OUTPUT_DIR]/misc/<index>-fix_swimmer_in_badge-<badge_ids>.sql'

    Options: [Rails.env=#{Rails.env}]
             badge=<badge_id1[,badge_id2,...]> swimmer=<correct_swimmer_id>
             [index=<auto>] [simulate='0'|<'1'>]

      - badge: comma-separated list of Badge IDs to fix (can span multiple seasons);

      - swimmer: the correct (destination) Swimmer ID;

      - index: override for a progressive number appended to the name of the generated file
               (default: auto-detected from existing files in output dir);

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default).

  DESC
  task(swimmer_in_badge: ['merge:check_needed_dirs']) do
    status = Maintenance::RakeRunner.call('fix:swimmer_in_badge', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Scans a Meeting or all Meetings in a Season for MIRs and MRSs
    with a null +swimmer_id+ and, whenever a valid badge with a swimmer is present,
    generates an SQL script that restores the correct swimmer from the badge.

    The fix is cascaded to child Lap rows (when +laps.swimmer_id+ IS NULL) and to
    child RelayLap rows of affected MRSs, so they stay in sync with the fixed result.

    Rows that cannot be fixed (no badge, missing badge, or badge with null swimmer)
    are reported at the end.

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '#{SCRIPT_OUTPUT_DIR}/misc/<index>-fix_nil_swimmers-<meeting_id|season_<season_id>>.sql'

    Options: [Rails.env=#{Rails.env}]
             meeting_id=<meeting_id> | season_id=<season_id>
             [index=<auto>] [simulate='0'|<'1'>]

      - meeting_id: process a single meeting (mutually exclusive with season_id);
      - season_id:  process all meetings in a season (mutually exclusive with meeting_id);
      - index:      override for a progressive number appended to the name of the generated file
                   (default: auto-detected from existing files in output dir);
      - simulate:   when set to '0' will enable script execution on localhost (toggled off by default).

  DESC
  task(nil_swimmers_in_results: ['merge:check_needed_dirs']) do
    status = Maintenance::RakeRunner.call('fix:nil_swimmers_in_results', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
end
