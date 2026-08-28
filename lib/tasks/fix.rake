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

namespace :fix do # rubocop:disable Metrics/BlockLength
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

      - '[DEFAULT_OUTPUT_DIR]/<index>-fix_team_in_badge-<badge_ids>.sql'

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
    puts '*** Task: fix:team_in_badge ***'

    badge_ids = ENV.fetch('badge', '')
                   .split(',')
                   .map { |x| x.strip.to_i }
                   .reject(&:zero?)
    badges = badge_ids.filter_map { |id| GogglesDb::Badge.find_by(id:) }
    new_team = GogglesDb::Team.find_by(id: ENV.fetch('team', nil).to_i)

    if badges.empty?
      puts("You need at least one valid 'badge' ID to proceed.")
      exit
    end
    if new_team.nil?
      puts("You need a valid 'team' ID to proceed.")
      exit
    end

    simulate = ENV['simulate'] != '0'
    nuke_team = ENV['nuke_team'] == '1'
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    badge_ids_label = badges.map(&:id).join('-')

    puts("\r\nFixing team_id in #{badges.size} badge(s): [#{badges.map(&:id).join(', ')}]")
    puts("New team: (#{new_team.id}) \"#{new_team.name}\"")
    puts("Mode: #{nuke_team ? 'NUKE TEAM-AFFILIATION REUSE' : 'SURGICAL (CREATE MISSING AFFILIATIONS ONLY)'}")
    if nuke_team
      puts('WARNING: NUKE MODE ENABLED!')
      puts('WARNING: THIS MAY REASSIGN ALL ROWS LINKED TO REUSED TEAM_AFFILIATION IDS,')
      puts('WARNING: NOT JUST THE BADGES YOU PASSED ON THE COMMAND LINE.')
    end
    puts("\r\n#{'- simulate'.ljust(50, '.')}: #{simulate}")
    puts("#{'- nuke_team'.ljust(50, '.')}: #{nuke_team}")
    puts("#{'- destination folder'.ljust(50, '.')}: #{SCRIPT_OUTPUT_DIR}")

    fixer = Merge::TeamInBadge.new(badges:, new_team:, nuke_team:)
    fixer.display_report
    fixer.prepare

    file_name = "#{format('%04d', file_index)}-fix_team_in_badge-#{badge_ids_label}"
    process_sql_file(file_name:, sql_log_array: fixer.sql_log, simulate:)

    puts('Done.')
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

      - '[DEFAULT_OUTPUT_DIR]/<index>-fix_swimmer_in_badge-<badge_ids>.sql'

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
    puts '*** Task: fix:swimmer_in_badge ***'

    badge_ids = ENV.fetch('badge', '')
                   .split(',')
                   .map { |x| x.strip.to_i }
                   .reject(&:zero?)
    badges = badge_ids.filter_map { |id| GogglesDb::Badge.find_by(id:) }
    new_swimmer = GogglesDb::Swimmer.find_by(id: ENV.fetch('swimmer', nil).to_i)

    if badges.empty?
      puts("You need at least one valid 'badge' ID to proceed.")
      exit
    end
    if new_swimmer.nil?
      puts("You need a valid 'swimmer' ID to proceed.")
      exit
    end

    simulate = ENV['simulate'] != '0'
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    badge_ids_label = badges.map(&:id).join('-')

    puts("\r\nFixing swimmer_id in #{badges.size} badge(s): [#{badges.map(&:id).join(', ')}]")
    puts("New swimmer: (#{new_swimmer.id}) \"#{new_swimmer.complete_name}\"")
    puts("\r\n#{'- simulate'.ljust(50, '.')}: #{simulate}")
    puts("#{'- destination folder'.ljust(50, '.')}: #{SCRIPT_OUTPUT_DIR}")

    fixer = Merge::SwimmerInBadge.new(badges:, new_swimmer:)
    fixer.display_report
    fixer.prepare

    file_name = "#{format('%04d', file_index)}-fix_swimmer_in_badge-#{badge_ids_label}"
    process_sql_file(file_name:, sql_log_array: fixer.sql_log, simulate:)

    puts('Done.')
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

      - '#{SCRIPT_OUTPUT_DIR}/<index>-fix_nil_swimmers-<meeting_id|season_<season_id>>.sql'

    Options: [Rails.env=#{Rails.env}]
             meeting_id=<meeting_id> | season_id=<season_id>
             [index=<auto>] [simulate='0'|<'1'>]

      - meeting_id: process a single meeting (mutually exclusive with season_id);
      - season_id:  process all meetings in a season (mutually exclusive with meeting_id);
      - index:      override for a progressive number appended to the name of the generated file
                   (default: auto-detected from existing files in output dir);
      - simulate:   when set to '0' will enable script execution on localhost (toggled off by default).

  DESC
  task(nil_swimmers_in_results: ['merge:check_needed_dirs']) do # rubocop:disable Metrics/BlockLength
    puts '*** Task: fix:nil_swimmers_in_results ***'

    meeting_id = ENV.fetch('meeting_id', nil)
    season_id = ENV.fetch('season_id', nil)

    if meeting_id.present? && season_id.present?
      puts("You cannot specify both 'meeting_id' and 'season_id'.")
      exit
    end

    meeting = GogglesDb::Meeting.find_by(id: meeting_id.to_i) if meeting_id.present?
    season = GogglesDb::Season.find_by(id: season_id.to_i) if season_id.present?

    if meeting.nil? && season.nil?
      puts("You need a valid 'meeting_id' or 'season_id' to proceed.")
      puts('  meeting_id: process a single meeting')
      puts('  season_id:  process all meetings in a season')
      exit
    end

    simulate = ENV['simulate'] != '0'
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir

    meetings = if meeting
                 [meeting]
               else
                 GogglesDb::Meeting.for_season(season).order(:id)
               end

    puts("\r\n- Scope..........: #{meeting ? "Meeting #{meeting.id}" : "Season #{season.id} (#{season.description})"}")
    puts("- Meetings.......: #{meetings.count}")
    puts("- simulate.......: #{simulate}")
    puts("- dest. folder...: #{SCRIPT_OUTPUT_DIR}\r\n")

    sql_log = []
    totals = { mirs: 0, mrss: 0, laps: 0, relay_laps: 0, unfixable_mirs: 0, unfixable_mrss: 0 }

    meetings.each do |mtg|
      fixer = Fix::NullSwimmersInMeeting.new(meeting: mtg)
      fixer.scan
      fixer.display_report

      sql_log.concat(fixer.prepare)
      print '.' if !simulate && fixer.fixable?

      report = fixer.report
      totals[:mirs]        += report[:mirs][:fixable]
      totals[:mrss]        += report[:mrss][:fixable]
      totals[:laps]        += report[:laps][:fixable]
      totals[:relay_laps]  += report[:relay_laps][:fixable]
      totals[:unfixable_mirs]  += report[:mirs][:unfixable]
      totals[:unfixable_mrss]  += report[:mrss][:unfixable]
    end
    puts("\r\n") unless simulate

    puts("\r\n*** Totals ***")
    puts("MIRs fixed: #{totals[:mirs]}")
    puts("MRSs fixed: #{totals[:mrss]}")
    puts("Laps updated: #{totals[:laps]}")
    puts("Relay laps updated: #{totals[:relay_laps]}")
    puts("Unfixable MIRs: #{totals[:unfixable_mirs]}") if totals[:unfixable_mirs].positive?
    puts("Unfixable MRSs: #{totals[:unfixable_mrss]}") if totals[:unfixable_mrss].positive?

    if sql_log.empty?
      puts("\r\nNo fixable null swimmers found. No SQL generated.")
      puts('Done.')
      next
    end

    full_sql_log = []
    full_sql_log << "-- Fix null swimmers - #{meeting ? "Meeting #{meeting.id}" : "Season #{season.id}"}"
    full_sql_log << "-- Generated: #{Time.zone.now}"
    full_sql_log << ''
    full_sql_log << 'SET AUTOCOMMIT = 0;'
    full_sql_log << 'START TRANSACTION;'
    full_sql_log << ''
    full_sql_log.concat(sql_log)
    full_sql_log << ''
    full_sql_log << 'COMMIT;'

    target_id = meeting&.id || "season_#{season.id}"
    file_name = "#{format('%04d', file_index)}-fix_nil_swimmers-#{target_id}"
    process_sql_file(file_name:, sql_log_array: full_sql_log, simulate:)
    puts('Done.')
  end
end
