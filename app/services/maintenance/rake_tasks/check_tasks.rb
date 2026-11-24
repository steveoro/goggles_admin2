# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::CheckTasks
    #
    # The read-only 'check:*' reports through the inspectors (Maintenance::Inspectors, planned without any run row:
    # nothing is written), plus 'check:dup_mir_swimmers' => results.dedupe (report, then the prompt, then the script).
    # 'check:results' and 'check:events' keep their own bodies (two queries, no strategy).
    #
    module CheckTasks
      # A report: the title, the input checks of the former task, then the inspector console unchanged.
      class Report < Base
        protected

        def report(key, params)
          operation, plan = inspect_plan(key, params)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          plan_errors!(plan)
          plan
        end
      end

      # 'check:team' => team.check
      class Team < Report
        def call
          say("\r\n*** Task: check:team ***")
          source = GogglesDb::Team.find_by(id: env['src'].to_i)
          dest = GogglesDb::Team.find_by(id: env['dest'].to_i)
          if source.nil? || dest.nil?
            say("You need both 'src' & 'dest' IDs to proceed.")
            stop!(0)
          end

          report('team.check', source_id: source.id, dest_id: dest.id)
        end
      end

      # 'check:swimmer' => swimmer.check
      class Swimmer < Report
        def call
          say("\r\n*** Task: check:swimmer ***")
          source = GogglesDb::Swimmer.find_by(id: env['src'].to_i)
          dest = GogglesDb::Swimmer.find_by(id: env['dest'].to_i)
          if source.nil? || dest.nil?
            say("You need both 'src' & 'dest' IDs to proceed.")
            stop!(0)
          end

          report('swimmer.check', source_id: source.id, dest_id: dest.id)
        end
      end

      # 'check:badge' => badge.check
      class Badge < Report
        def call
          say("\r\n*** Task: check:badge ***")
          source = GogglesDb::Badge.find_by(id: env['src'].to_i)
          dest = GogglesDb::Badge.find_by(id: env['dest'].to_i)
          if source.nil?
            say("You need at least the 'src' ID to proceed.")
            stop!(0)
          end

          report('badge.check', source_id: source.id, dest_id: dest&.id)
        end
      end

      # 'check:season' => season.badges (the former task stopped before the candidate list unless list_teams=1 or there
      # was no candidate at all)
      class Season < Report
        def call
          say("\r\n*** Task: check:season - season #{env.fetch('season', nil)} ***")
          season = GogglesDb::Season.find_by(id: env['season'].to_i)
          if season.nil?
            say("You need a valid 'season' ID to proceed.")
            stop!(0)
          end

          plan = report('season.badges', season_id: season.id, list_teams: flag(env['list_teams'] == '1'))
          stop!(0) unless plan.summary['listed']
        end
      end

      # 'check:map_team_badges' => team.map_badges
      class MapTeamBadges < Report
        def call # rubocop:disable Metrics/AbcSize
          say("\r\n*** Task: check:map_team_badges - season #{env.fetch('season', nil)}, team #{env.fetch('team', nil)} ***")
          season = GogglesDb::Season.find_by(id: env['season'].to_i)
          team = GogglesDb::Team.find_by(id: env['team'].to_i)
          if season.nil? || team.nil?
            say("You need both a valid 'season' & team IDs to proceed.")
            stop!(0)
          end

          plan = report('team.map_badges', season_id: season.id, team_id: team.id, page: env['page'].to_i)
          stop!(0) if plan.summary['stopped']
        end
      end

      # 'check:map_swimmer_mirs' => swimmer.map_mirs
      class MapSwimmerMirs < Report
        def call
          say("\r\n*** Task: check:map_swimmer_mirs - swimmer #{env.fetch('swimmer', nil)} ***")
          swimmer = GogglesDb::Swimmer.find_by(id: env['swimmer'].to_i)
          if swimmer.nil?
            say("You need a valid 'swimmer' ID to proceed.")
            stop!(0)
          end

          last7 = %w[1 true].include?(env.fetch('last7', '').to_s.downcase)
          plan = report('swimmer.map_mirs', swimmer_id: swimmer.id, last7: flag(last7), page: env['page'].presence&.to_i)
          stop!(0) if plan.summary['stopped']
        end
      end

      # 'check:dup_badges_for_team' => team.dup_badges
      class DupBadgesForTeam < Report
        def call
          say("\r\n*** Task: check:dup_badges_for_team - team #{env.fetch('team', nil)} ***")
          team = GogglesDb::Team.find_by(id: env['team'].to_i)
          if team.nil?
            say('You need a valid team ID to proceed.')
            stop!(0)
          end

          report('team.dup_badges', team_id: team.id)
        end
      end

      # 'check:dup_mir_badges' => meeting.dup_mir_badges
      class DupMirBadges < Report
        def call
          say("\r\n*** Task: check:dup_mir_badges - Meeting: #{env.fetch('meeting_id', nil)} ***")
          meeting_id = env.fetch('meeting_id', nil)
          unless GogglesDb::Meeting.exists?(id: meeting_id)
            say('You need a valid meeting_id to proceed.')
            stop!(0)
          end

          report('meeting.dup_mir_badges', meeting_id: meeting_id.to_i)
        end
      end

      # 'check:dup_mir_swimmers' => results.dedupe (meeting or whole season; "nothing to do" is now Plan#empty?, not the
      # former 'size <= 5' guard)
      class DupMirSwimmers < Base
        def call # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
          say("\r\n*** Task: check:dup_mir_swimmers ***")
          meeting_id = env.fetch('meeting_id', nil)
          season_id = env.fetch('season_id', nil)
          autofix = env['autofix'] == '1'
          meeting = GogglesDb::Meeting.find_by(id: meeting_id) if meeting_id.present?
          season = GogglesDb::Season.find_by(id: season_id) if season_id.present?
          if meeting.nil? && season.nil?
            say('You need a valid meeting_id or season_id to proceed.')
            say('  meeting_id: Check a single meeting')
            say('  season_id:  Check all meetings in a season')
            stop!(0)
          end

          say("\r\n- Meeting.......: #{meeting.id} - #{meeting.decorate.display_label}") if meeting
          say("- Season........: #{season.id} - #{season.description}") if season && meeting.nil?
          say("- autofix.......: #{autofix}")
          say("- simulate......: #{simulate?}")
          say("- dest. folder..: #{script_output_dir}\r\n") if autofix

          params = (meeting ? { meeting_id: meeting.id } : { season_id: season.id }).merge(report: true)
          unless autofix
            operation, plan = inspect_plan('results.dedupe', params.merge(report_only: true))
            write(operation.captured_output)
            raise_plan_exception!(operation)
            plan_errors!(plan)
            say("\r\nRun with autofix=1 to generate deletion script.")
            return
          end

          executor = preview('results.dedupe', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          plan_errors!(executor.plan)
          if executor.plan.empty?
            say("\r\nNo duplicates found requiring deletion.")
            return
          end

          # Ask for confirmation
          unless confirm?("\r\nProceed with generating fix script? [y/N] ")
            say('Aborted.')
            stop!(0)
          end

          report_script!(write_script('results.dedupe', params, preview: executor))
          say('Done.')
        end
      end
    end
  end
end
