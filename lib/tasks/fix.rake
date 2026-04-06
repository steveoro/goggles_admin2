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

namespace :fix do # rubocop:disable Metrics/BlockLength
  desc <<~DESC
      Fixes a wrongly-assigned team_id on one or more badges within a single season.

    Updates all related results (MIRs, laps, MRRs, relay_laps) with the correct team_id
    and deletes meeting entries and reservations for the affected badges.

    Related badges discovered via MRS → MRR cascade (relay teammates) are included
    automatically for data coherence.

    The task halts if any swimmer in the batch already has a badge on the destination team
    (those are candidates for badge merge, not badge fix).

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '[DEFAULT_OUTPUT_DIR]/<index>-fix_team_in_badge-<badge_ids>.sql'

    Options: [Rails.env=#{Rails.env}]
             badge=<badge_id1[,badge_id2,...]> team=<correct_team_id>
             [index=<auto>] [simulate='0'|<'1'>]

      - badge: comma-separated list of Badge IDs to fix (all must be in the same season);

      - team: the correct (destination) Team ID;

      - index: override for a progressive number appended to the name of the generated file
               (default: auto-detected from existing files in output dir);

      - simulate: when set to '0' will enable script execution on localhost (toggled off by default).

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
    file_index = ENV['index'].present? ? ENV['index'].to_i : auto_index_from_script_output_dir
    badge_ids_label = badges.map(&:id).join('-')

    puts("\r\nFixing team_id in #{badges.size} badge(s): [#{badges.map(&:id).join(', ')}]")
    puts("New team: (#{new_team.id}) \"#{new_team.name}\"")
    puts("\r\n#{'- simulate'.ljust(50, '.')}: #{simulate}")
    puts("#{'- destination folder'.ljust(50, '.')}: #{SCRIPT_OUTPUT_DIR}")

    fixer = Merge::TeamInBadge.new(badges:, new_team:)
    fixer.display_report
    fixer.prepare

    file_name = "#{file_index}-fix_team_in_badge-#{badge_ids_label}"
    process_sql_file(file_name:, sql_log_array: fixer.sql_log, simulate:)

    puts('Done.')
  end

  desc <<~DESC
      Fixes a wrongly-assigned swimmer_id on one or more badges within a single season.

    Updates all related badge-linked entities (MIRs, laps, MRSs, relay_laps,
    meeting entries and reservations) with the correct swimmer_id.

    The task halts if any destination swimmer/team/season pair already has a badge
    (those are candidates for badge merge, not badge fix).

    The resulting script won't be applied (and no DB changes will be made) *unless*
    the 'simulate' option is set explicitly to '0'. (Default: DO NOT MAKE DB CHANGES.)

    The Rails.env will set the destination DB for script execution on localhost.
    The resulting file will be stored under:

      - '[DEFAULT_OUTPUT_DIR]/<index>-fix_swimmer_in_badge-<badge_ids>.sql'

    Options: [Rails.env=#{Rails.env}]
             badge=<badge_id1[,badge_id2,...]> swimmer=<correct_swimmer_id>
             [index=<auto>] [simulate='0'|<'1'>]

      - badge: comma-separated list of Badge IDs to fix (all must be in the same season);

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

    file_name = "#{file_index}-fix_swimmer_in_badge-#{badge_ids_label}"
    process_sql_file(file_name:, sql_log_array: fixer.sql_log, simulate:)

    puts('Done.')
  end
end
