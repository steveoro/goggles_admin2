# frozen_string_literal: true

require 'fileutils'

#
# = Local Data-integrity helper tasks
#
#   - (p) FASAR Software 2007-2025
#   - for Goggles framework vers.: 7+
#   - author: Steve A.
#
#   (ASSUMES TO BE rakeD inside Rails.root)
#
#-- ---------------------------------------------------------------------------
#++

# Since phase 13 the report tasks are thin callers of the read-only inspectors (Maintenance::Inspectors, also on
# /operations) and 'check:dup_mir_swimmers' of the 'results.dedupe' operation (Maintenance::RakeRunner): same texts,
# prompt and exits. 'check:results' and 'check:events' keep their two queries; their default season is the latest FIN
# Masters season (SeasonDefaults); the data health report (/health) covers both checks for every season.
namespace :check do # rubocop:disable Metrics/BlockLength
  desc <<~DESC
    Given a Season ID, queries all local Meeting IDs that DO/DO-NOT HAVE MIRs or MRRs associated.

    The lack of MIRs is usually a red flag for meetings that either have been cancelled
    or have a data-import still pending.
    (MIRs should always be there for a Meeting that has occurred, whereas MRRs may not have been
     set at all, depending by the organization hosting it.)

    Options: [season=season#id|<nil=latest FIN Masters season>]
             [mrr=true|<nil=false>]
             [presence=true|<nil=false>]

      - season: season ID
      - mrr: when 'true' (or not blank) will count MRRs instead of MIRs
      - presence: search for zero siblings (default, either MIRs or MRRs) or for their positive count

  DESC
  task results: :environment do
    includee = ENV.include?('mrr') ? :meeting_relay_results : :meeting_individual_results
    # For presence, we'll reject the zero? counts, whereas for absence, we'll reject the positive? counts:
    reject_check_name = ENV.include?('presence') ? :zero? : :positive?
    puts("\r\n*** Find Meetings #{reject_check_name == :zero? ? 'WITH' : 'WITHOUT'} #{includee} rows ***")

    season_id = ENV.include?('season') ? ENV['season'].to_i : SeasonDefaults.default_season_id
    puts "\r\n"
    puts "--> Season #{season_id}:"
    meeting_keys = GogglesDb::Meeting.where(season_id:).includes(includee)
                                     .group('meetings.id', 'meetings.description', 'meetings.header_date')
                                     .order('meetings.header_date')
                                     .count("#{includee}.id")
                                     .reject { |_k, count| count.send(reject_check_name) }
    meeting_keys.each_key { |keys| puts "ID #{keys.first}: [#{keys.third}] \"#{keys.second}\"" }
    puts "\r\n"
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
    Similarly to check:results, given a Season ID, queries all local Meeting IDs that DO/DO-NOT HAVE
    MeetingEvents associated.

    Options: [season=season#id|<nil=latest FIN Masters season>]
             [presence=true|<nil=false>]

      - season: season ID
      - presence: search for zero siblings (default, either MIRs or MRRs) or for their positive count

  DESC
  task events: :environment do
    # For presence, we'll reject the zero? counts, whereas for absence, we'll reject the positive? counts:
    reject_check_name = ENV.include?('presence') ? :zero? : :positive?
    puts("\r\n*** Find Meetings #{reject_check_name == :zero? ? 'WITH' : 'WITHOUT'} MeetingEvent rows ***")

    season_id = ENV.include?('season') ? ENV['season'].to_i : SeasonDefaults.default_season_id
    puts "\r\n"
    puts "--> Season #{season_id}:"
    meeting_keys = GogglesDb::Meeting.where(season_id:).includes(:meeting_events)
                                     .group('meetings.id', 'meetings.description', 'meetings.header_date')
                                     .order('meetings.header_date')
                                     .count('meeting_events.id')
                                     .reject { |_k, count| count.send(reject_check_name) }
    meeting_keys.each_key { |keys| puts "ID #{keys.first}: [#{keys.third}] \"#{keys.second}\"" }
    puts "\r\n"
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Runs a check for Team merge feasibility, reporting any future issues on the console.

    Options: [Rails.env=#{Rails.env}]
             src=<source_team_id>
             dest=<destination_team_id>

      - src: source Team ID
      - dest: destination Team ID

  DESC
  task(team: [:environment]) do
    status = Maintenance::RakeRunner.call('check:team', data_root: Outbox.data_root)
    exit(status) if status
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
  task(swimmer: [:environment]) do
    status = Maintenance::RakeRunner.call('check:swimmer', data_root: Outbox.data_root)
    exit(status) if status
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
             list_teams=<'0'>|'1'

      - season: source Season ID to be checked;

      - list_teams: when set to '1' will output all team names associated with possible badge merges.

  DESC
  task(season: [:environment]) do
    status = Maintenance::RakeRunner.call('check:season', data_root: Outbox.data_root)
    exit(status) if status
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
  task(badge: [:environment]) do
    status = Maintenance::RakeRunner.call('check:badge', data_root: Outbox.data_root)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Loops upon all badges for a specific Season & Team and reports a mapping
    of all involved teams x swimmer badge for all registered seasons (of that badge).

    This is most useful when trying to divide badges that have been wrongly assigned
    to different teams.

    The output is divided into pages of 10 badges maximum using Kaminari.

    Options: [Rails.env=#{Rails.env}]
             season=<season_id>
             team=<team_id>
             page=<0>|N

      - season: Season ID to be checked out;
      - team: Team ID to be checked out;
      - page: page number to display.

  DESC
  task(map_team_badges: [:environment]) do
    status = Maintenance::RakeRunner.call('check:map_team_badges', data_root: Outbox.data_root)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Groups all MIRs found for a badge belonging to the same MeetingProgram to
    highlight and list possible duplicates per badges, created either by a wrong badge assignment
    or after a mis-aligned data-import run.

    The output lists all badge IDs associated to > 1 MIR for the specified Meeting.

    Options: [Rails.env=#{Rails.env}]
             meeting_id=<meeting_id>

  DESC
  task(dup_mir_badges: [:environment]) do
    status = Maintenance::RakeRunner.call('check:dup_mir_badges', data_root: Outbox.data_root)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Detects and optionally removes duplicate swimmer results (MIRs, laps, MRSs, relay_laps, MRRs)
    within a meeting or across all meetings in a season.

    Duplicates are identified when multiple results exist for the same swimmer in the same program.
    When autofix=1, generates a SQL script to delete duplicates (keeps lowest ID).

    Options: [Rails.env=#{Rails.env}]
             meeting_id=<meeting_id> | season_id=<season_id>
             [autofix=<'0'>|'1']
             [simulate=<'1'>|'0']
             [index=<auto>]

    - meeting_id: Check a single meeting (mutually exclusive with season_id)
    - season_id:  Check all meetings in a season (mutually exclusive with meeting_id)
    - autofix:    When '1', generates DELETE statements for duplicates (default: 0)
    - simulate:   When '0', executes the generated script locally (default: 1)
    - index:      Override the default progressive file index (default: auto)

  DESC
  task(dup_mir_swimmers: ['merge:check_needed_dirs']) do
    status = Maintenance::RakeRunner.call('check:dup_mir_swimmers', data_root: SCRIPT_OUTPUT_DIR.dirname)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Loops upon all MIRs found for a specific swimmer and reports a mapping
    of all involved teams x swimmer badge for all seasons or the latest 7 seasons.

    The output is divided into pages of 50 MIRs maximum using Kaminari.

    Options: [Rails.env=#{Rails.env}]
             swimmer=<swimmer_id>
             [last7=<'0'>|'1'|'true'|'false']
             [page=<0>|N]

      - swimmer: Swimmer ID to be checked out;
      - last7: when set to '1' or 'true' will limit output to latest 7 seasons;
      - page: optional page number to display (0-based); when missing, outputs all rows.

  DESC
  task(map_swimmer_mirs: [:environment]) do
    status = Maintenance::RakeRunner.call('check:map_swimmer_mirs', data_root: Outbox.data_root)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Checks for duplicated badges among all swimmers that have ever had a badge
    associated to the specified team.

    For each swimmer that has ever had a badge on the team, this task identifies
    which swimmers have duplicate badges in any season (across any team).

    For each flagged swimmer, the task reports all badge rows across all seasons
    ordered by season_id, badge_id with the following columns:
      season_id, badge_id, team_id, team_affiliation_id, team.name, mir_count

    Options: [Rails.env=#{Rails.env}]
             team=<team_id>

      - team: Team ID to be checked (required)

    Example:
      rake check:dup_badges_for_team team=539

  DESC
  task(dup_badges_for_team: [:environment]) do
    status = Maintenance::RakeRunner.call('check:dup_badges_for_team', data_root: Outbox.data_root)
    exit(status) if status
  end
  #-- -------------------------------------------------------------------------
  #++
end
