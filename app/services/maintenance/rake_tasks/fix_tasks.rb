# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::FixTasks
    #
    # The 'fix:*' tasks: badge.team_fix, badge.swimmer_fix, results.null_swimmers_fix (meeting or whole season).
    #
    module FixTasks
      # Shared input of the badge fixes: the 'badge' list (comma separated) and its existing badges.
      module BadgeList
        def badge_list
          ids = env.fetch('badge', '').split(',').map { |x| x.strip.to_i }.reject(&:zero?)
          ids.filter_map { |id| GogglesDb::Badge.find_by(id:) }
        end
      end

      # 'fix:team_in_badge' => badge.team_fix
      class TeamInBadge < Base
        include BadgeList

        def call # rubocop:disable Metrics/AbcSize
          say('*** Task: fix:team_in_badge ***')
          badges = badge_list
          new_team = GogglesDb::Team.find_by(id: env.fetch('team', nil).to_i)
          if badges.empty?
            say("You need at least one valid 'badge' ID to proceed.")
            stop!(0)
          end
          if new_team.nil?
            say("You need a valid 'team' ID to proceed.")
            stop!(0)
          end

          nuke_team = env['nuke_team'] == '1'
          say("\r\nFixing team_id in #{badges.size} badge(s): [#{badges.map(&:id).join(', ')}]")
          say("New team: (#{new_team.id}) \"#{new_team.name}\"")
          say("Mode: #{nuke_team ? 'NUKE TEAM-AFFILIATION REUSE' : 'SURGICAL (CREATE MISSING AFFILIATIONS ONLY)'}")
          if nuke_team
            say('WARNING: NUKE MODE ENABLED!')
            say('WARNING: THIS MAY REASSIGN ALL ROWS LINKED TO REUSED TEAM_AFFILIATION IDS,')
            say('WARNING: NOT JUST THE BADGES YOU PASSED ON THE COMMAND LINE.')
          end
          say("\r\n#{'- simulate'.ljust(50, '.')}: #{simulate?}")
          say("#{'- nuke_team'.ljust(50, '.')}: #{nuke_team}")
          say("#{'- destination folder'.ljust(50, '.')}: #{script_output_dir}")

          params = { badge_ids: badges.map(&:id).join(','), team_id: new_team.id, nuke_team: flag(nuke_team) }
          executor = write_script('badge.team_fix', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          report_script!(executor)
          say('Done.')
        end
      end

      # 'fix:swimmer_in_badge' => badge.swimmer_fix
      class SwimmerInBadge < Base
        include BadgeList

        def call # rubocop:disable Metrics/AbcSize
          say('*** Task: fix:swimmer_in_badge ***')
          badges = badge_list
          new_swimmer = GogglesDb::Swimmer.find_by(id: env.fetch('swimmer', nil).to_i)
          if badges.empty?
            say("You need at least one valid 'badge' ID to proceed.")
            stop!(0)
          end
          if new_swimmer.nil?
            say("You need a valid 'swimmer' ID to proceed.")
            stop!(0)
          end

          say("\r\nFixing swimmer_id in #{badges.size} badge(s): [#{badges.map(&:id).join(', ')}]")
          say("New swimmer: (#{new_swimmer.id}) \"#{new_swimmer.complete_name}\"")
          say("\r\n#{'- simulate'.ljust(50, '.')}: #{simulate?}")
          say("#{'- destination folder'.ljust(50, '.')}: #{script_output_dir}")

          executor = write_script('badge.swimmer_fix', { badge_ids: badges.map(&:id).join(','), swimmer_id: new_swimmer.id })
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          report_script!(executor)
          say('Done.')
        end
      end

      # 'fix:nil_swimmers_in_results' => results.null_swimmers_fix (one script for a meeting or a whole season)
      class NilSwimmers < Base
        def call # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          say('*** Task: fix:nil_swimmers_in_results ***')
          meeting_id = env.fetch('meeting_id', nil)
          season_id = env.fetch('season_id', nil)
          if meeting_id.present? && season_id.present?
            say("You cannot specify both 'meeting_id' and 'season_id'.")
            stop!(0)
          end

          meeting = GogglesDb::Meeting.find_by(id: meeting_id.to_i) if meeting_id.present?
          season = GogglesDb::Season.find_by(id: season_id.to_i) if season_id.present?
          if meeting.nil? && season.nil?
            say("You need a valid 'meeting_id' or 'season_id' to proceed.")
            say('  meeting_id: process a single meeting')
            say('  season_id:  process all meetings in a season')
            stop!(0)
          end

          meetings_count = meeting ? 1 : GogglesDb::Meeting.for_season(season).count
          say("\r\n- Scope..........: #{meeting ? "Meeting #{meeting.id}" : "Season #{season.id} (#{season.description})"}")
          say("- Meetings.......: #{meetings_count}")
          say("- simulate.......: #{simulate?}")
          say("- dest. folder...: #{script_output_dir}\r\n")

          params = meeting ? { meeting_id: meeting.id } : { season_id: season.id }
          executor = simulate? ? script_only('results.null_swimmers_fix', params) : preview('results.null_swimmers_fix', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          say("\r\n") unless simulate?
          print_totals(executor.plan.summary['totals'].to_h)
          if executor.plan.empty?
            say("\r\nNo fixable null swimmers found. No SQL generated.")
            say('Done.')
            stop!(nil)
          end

          executor = apply('results.null_swimmers_fix', params, preview: executor) unless simulate?
          report_script!(executor)
          say('Done.')
        end

        private

        def print_totals(totals)
          say("\r\n*** Totals ***")
          say("MIRs fixed: #{totals['mirs'].to_i}")
          say("MRSs fixed: #{totals['mrss'].to_i}")
          say("Laps updated: #{totals['laps'].to_i}")
          say("Relay laps updated: #{totals['relay_laps'].to_i}")
          say("Unfixable MIRs: #{totals['unfixable_mirs']}") if totals['unfixable_mirs'].to_i.positive?
          say("Unfixable MRSs: #{totals['unfixable_mrss']}") if totals['unfixable_mrss'].to_i.positive?
        end
      end
    end
  end
end
