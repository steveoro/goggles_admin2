# frozen_string_literal: true

require 'fileutils'
require 'kaminari'

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

namespace :check do # rubocop:disable Metrics/BlockLength
  # Default Goggles::Season#id value for most tasks
  DEFAULT_SEASON_ID = 242 unless defined? DEFAULT_SEASON_ID
  #-- ---------------------------------------------------------------------------
  #++

  desc <<~DESC
    Given a Season ID, queries all local Meeting IDs that DO/DO-NOT HAVE MIRs or MRRs associated.

    The lack of MIRs is usually a red flag for meetings that either have been cancelled
    or have a data-import still pending.
    (MIRs should always be there for a Meeting that has occurred, whereas MRRs may not have been
     set at all, depending by the organization hosting it.)

    Options: [season=season#id|<nil=#{DEFAULT_SEASON_ID}>]
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

    season_id = ENV.include?('season') ? ENV['season'].to_i : DEFAULT_SEASON_ID
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

    Options: [season=season#id|<nil=#{DEFAULT_SEASON_ID}>]
             [presence=true|<nil=false>]

      - season: season ID
      - presence: search for zero siblings (default, either MIRs or MRRs) or for their positive count

  DESC
  task events: :environment do
    # For presence, we'll reject the zero? counts, whereas for absence, we'll reject the positive? counts:
    reject_check_name = ENV.include?('presence') ? :zero? : :positive?
    puts("\r\n*** Find Meetings #{reject_check_name == :zero? ? 'WITH' : 'WITHOUT'} MeetingEvent rows ***")

    season_id = ENV.include?('season') ? ENV['season'].to_i : DEFAULT_SEASON_ID
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
    puts("\r\n*** Task: check:team ***")
    source = GogglesDb::Team.find_by(id: ENV['src'].to_i)
    dest = GogglesDb::Team.find_by(id: ENV['dest'].to_i)
    if source.nil? || dest.nil?
      puts("You need both 'src' & 'dest' IDs to proceed.")
      exit
    end

    checker = Merge::TeamChecker.new(source:, dest:)
    checker.run
    checker.display_report
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
    puts("\r\n*** Task: check:swimmer ***")
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
    puts("\r\n*** Task: check:season - season #{ENV.fetch('season', nil)} ***")
    season = GogglesDb::Season.find_by(id: ENV['season'].to_i)
    if season.nil?
      puts("You need a valid 'season' ID to proceed.")
      exit
    end
    list_teams = ENV['list_teams'] == '1'

    puts('--> LIST TEAMS for sure & possible badge merges: ✔') if list_teams

    checker = Merge::BadgeSeasonChecker.new(season:)
    checker.run
    checker.display_report
    exit unless list_teams || (checker.sure_badge_merges.blank? && checker.possible_badge_merges.blank?)

    %i[possible_badge_merges sure_badge_merges].each do |method_name|
      puts("\r\n\033[1;33;37m#{method_name.upcase} candidates w/ badge details:\033[0m (tot. #{checker.send(method_name).size})")
      checker.send(method_name).each do |swimmer_id, badge_list|
        deco_list = badge_list.map do |badge|
          "[ID \033[1;33;33m#{badge.id.to_s.rjust(7)}\033[0m, team #{badge.team_id.to_s.rjust(5)}: #{badge.team.name} / #{badge.category_type.code}]".ljust(100)
        end
        puts("- Swimmer #{swimmer_id.to_s.rjust(6)}, badges: #{deco_list.join('| ')}")
      end
    end
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
    puts("\r\n*** Task: check:badge ***")
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
    puts("\r\n*** Task: check:map_team_badges - season #{ENV.fetch('season', nil)}, team #{ENV.fetch('team', nil)} ***")
    season = GogglesDb::Season.find_by(id: ENV['season'].to_i)
    team = GogglesDb::Team.find_by(id: ENV['team'].to_i)
    if season.nil? || team.nil?
      puts("You need both a valid 'season' & team IDs to proceed.")
      exit
    end

    page_idx = ENV['page'].to_i
    badges = GogglesDb::Badge.where(season_id: season.id, team_id: team.id)
    puts("\r\n--> Found #{badges.size} badges => showing page #{page_idx} (/#{(badges.size / 10) - 1})")
    exit if badges.empty?

    badges_page = Kaminari.paginate_array(badges).page(page_idx).per(10)
    exit if badges_page.empty?

    GogglesDb::BadgeDecorator.decorate_collection(badges_page).each do |badge|
      categories_x_seasons = Merge::BadgeChecker.map_categories_x_seasons(season.season_type_id, badge.swimmer_id)
      curr_hash = categories_x_seasons.find { |h| h[:season_id] == season.id }
      Merge::BadgeChecker.badge_report_header(
        src_badge: badge,
        computed_category_type_id: curr_hash[:computed_category_type_id],
        computed_category_type_code: curr_hash[:computed_category_type_code]
      ).each { |header_line| puts(header_line) }

      categories_x_seasons.map do |categories_map|
        puts(Merge::BadgeChecker.decorate_categories_map(categories_map))
      end
    end
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
    puts("\r\n*** Task: check:dup_mir_badges - Meeting: #{ENV.fetch('meeting_id', nil)} ***")
    meeting_id = ENV.fetch('meeting_id', nil)
    unless GogglesDb::Meeting.exists?(id: meeting_id)
      puts('You need a valid meeting_id to proceed.')
      exit
    end

    badge_ids = GogglesDb::MeetingIndividualResult.joins(meeting_program: { meeting_event: { meeting_session: :meeting } })
                                                  .where(meetings: { id: meeting_id })
                                                  .group(:badge_id, 'meeting_programs.id')
                                                  .having('COUNT(meeting_individual_results.id) > 1')
                                                  .pluck(:badge_id)

    puts("\r\n--> Found #{badge_ids.size} badges with > 1 MIR for the *SAME* MeetingProgram.")
    if badge_ids.size.positive?
      puts(badge_ids.join(', '))
    else
      puts("THAT'S GOOD! No duplicates!")
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  desc <<~DESC
      Loops upon all MIRs found for a specific swimmer and reports a mapping
    of all involved teams x swimmer badge for the 5 latest seasons.

    The output is divided into pages of 50 MIRs maximum using Kaminari.

    Options: [Rails.env=#{Rails.env}]
             swimmer=<swimmer_id>
             page=<0>|N

      - swimmer: Swimmer ID to be checked out;
      - page: page number to display.

  DESC
  task(map_swimmer_mirs: [:environment]) do
    puts("\r\n*** Task: check:map_swimmer_mirs - swimmer #{ENV.fetch('swimmer', nil)} ***")
    swimmer = GogglesDb::Swimmer.find_by(id: ENV['swimmer'].to_i)
    if swimmer.nil?
      puts("You need a valid 'swimmer' ID to proceed.")
      exit
    end

    min_season_id = GogglesDb::LastSeasonId.first.id - 50 # (season IDs are fixed and increased by 10 each championship)
    per_page = 50
    page_idx = ENV['page'].to_i

    mirs = GogglesDb::MeetingIndividualResult.includes(:meeting, :season)
                                             .joins(:season)
                                             .where('swimmer_id = ? AND seasons.id >= ?', swimmer.id, min_season_id)
    puts("\r\n--> Swimmer ID #{swimmer.id}")
    puts("--> Found #{mirs.size} MIRs => showing page #{page_idx} (/#{(mirs.size / per_page) - 1})")
    exit if mirs.empty?

    mirs_page = Kaminari.paginate_array(mirs).page(page_idx).per(per_page)
    exit if mirs_page.empty?

    curr_season = 0
    puts('MIR'.ljust(12) + ' | Season'.ljust(10) + ' | Badge'.ljust(12) + ' | Team'.ljust(12) + ' | Team Aff.'.ljust(12) + ' | Meeting'.ljust(50))
    mirs_page.map do |mir|
      if curr_season != mir.season.id
        puts(''.center(120, '-'))
        curr_season = mir.season.id
      end
      puts("#{mir.id.to_s.rjust(12)} | #{mir.season.id.to_s.rjust(7)} | #{mir.badge_id.to_s.rjust(9)} | #{mir.team_id.to_s.rjust(9)} | #{mir.team_affiliation_id.to_s.rjust(9)} | #{mir.meeting.description.ljust(50)}")
    end
    puts("\r\n")
  end
  #-- -------------------------------------------------------------------------
  #++
end
