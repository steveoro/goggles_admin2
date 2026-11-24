# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::MergeTasks
    #
    # The 'merge:*' tasks: swimmer.merge, team.merge, meeting.merge, badge.merge, season.badge_fix, meeting.team_fix.
    #
    module MergeTasks
      # 'merge:swimmer' => swimmer.merge
      class Swimmer < Base
        def call # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          say('*** Task: merge:swimmer ***')
          source = GogglesDb::Swimmer.find_by(id: env['src'].to_i)
          dest = GogglesDb::Swimmer.find_by(id: env['dest'].to_i)
          if source.nil? || dest.nil?
            say("You need to have both 'src' & 'dest' IDs with valid values in order to proceed.")
            stop!(0)
          end

          skip_columns = env['skip_columns'] == '1'
          force = env['force'] == '1'
          say("\r\nMerging '#{source&.complete_name}' (#{source&.id}) |=> '#{dest&.complete_name}' (#{dest&.id})")
          say("\r\n- simulate.......: #{simulate?}")
          say("- skip_columns...: #{skip_columns}")
          say("- force..........: #{force}")
          say("- dest. folder...: #{script_output_dir}\r\n")

          params = { source_id: source.id, dest_id: dest.id, skip_columns: flag(skip_columns), force: flag(force) }
          executor = simulate? ? script_only('swimmer.merge', params) : preview('swimmer.merge', params)
          merger = print_plan(executor)
          if merger.errors.present? && !force
            say('Issues surfaced: use force=1 to proceed. Aborted.')
            stop!(0)
          end

          executor = apply('swimmer.merge', params, preview: executor) unless simulate?
          report_script!(executor)
          say('Done.')
        end

        private

        def print_plan(executor)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          say("\r\n*** Log: ***\r\n")
          say(operation.merger.log.join("\r\n"))
          operation.merger
        end
      end

      # 'merge:team' => team.merge
      class Team < Base
        def call # rubocop:disable Metrics/AbcSize
          say('*** Task: merge:team ***')
          source = GogglesDb::Team.find_by(id: env['src'].to_i)
          dest = GogglesDb::Team.find_by(id: env['dest'].to_i)
          if source.nil? || dest.nil?
            say("You need to have both 'src' & 'dest' IDs with valid values in order to proceed.")
            stop!(0)
          end

          skip_columns = env['skip_columns'] == '1'
          keep_as_alias = env['keep_as_alias'] == '1'
          say("\r\nMerging '#{source&.name}' (#{source&.id}) |=> '#{dest&.name}' (#{dest&.id})")
          say("\r\n- simulate.......: #{simulate?}")
          say("- skip_columns...: #{skip_columns}")
          say("- keep_as_alias..: #{keep_as_alias}")
          say("- dest. folder...: #{script_output_dir}\r\n")

          params = { source_id: source.id, dest_id: dest.id, skip_columns: flag(skip_columns), keep_as_alias: flag(keep_as_alias) }
          say("\r\n*** Log: ***\r\n")
          executor = write_script('team.merge', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          report_script!(executor)
          say('Done.')
        end
      end

      # 'merge:meeting' => meeting.merge (the checker progress of the former task: console_output)
      class Meeting < Base
        def call # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          say('*** Task: merge:meeting ***')
          source = GogglesDb::Meeting.find_by(id: env['src'].to_i)
          dest = GogglesDb::Meeting.find_by(id: env['dest'].to_i)
          if source.nil? || dest.nil?
            say("You need to have both 'src' & 'dest' IDs with valid values in order to proceed.")
            stop!(0)
          end

          skip_columns = env['skip_columns'] == '1'
          say("\r\nMerging Meeting (#{source.id}) '#{source.description}'")
          say("    |=> (#{dest.id}) '#{dest.description}'")
          say("    Season: #{source.season_id}")
          say("\r\n- simulate.......: #{simulate?}")
          say("- skip_columns...: #{skip_columns}")
          say("- dest. folder...: #{script_output_dir}\r\n")

          params = { source_id: source.id, dest_id: dest.id, skip_columns: flag(skip_columns), console_output: true }
          executor = simulate? ? script_only('meeting.merge', params) : preview('meeting.merge', params)
          merger = print_plan(executor)
          return if merger.nil?

          executor = apply('meeting.merge', params, preview: executor) unless simulate?
          report_script!(executor)
          save_warning_log(merger, executor)
          write(executor.after_apply_output.to_s.then { |text| text.end_with?("\n") || text.empty? ? text : "#{text}\n" }) unless simulate?
          say('Done.')
        end

        private

        # The merger of a feasible merge (nil after the former 'Aborted due to errors.').
        def print_plan(executor)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          merger = operation.merger
          if executor.plan&.blocked?
            say('Aborted due to errors.')
            write(Maintenance::OutputCapture.capture { merger.display_report }.last)
            return
          end

          say("\r\n*** Checker Log: ***\r\n")
          say(merger.log.join("\r\n"))
          merger
        end

        # The warning log next to the scripts, as before ('<NNNN>-merge_meetings-<src>-<dest>-warnings.log').
        def save_warning_log(merger, executor)
          return if merger.warning_log.blank?

          prefix = executor.run.summary_hash['sql_filename'].to_s[/\A\d+/] || format('%04d', file_index)
          warning_file = "#{script_output_dir}/#{prefix}-merge_meetings-#{merger.source.id}-#{merger.dest.id}-warnings.log"
          File.open(warning_file, 'w+') { |f| f.puts(merger.warning_log.join("\r\n")) }
          say("\r\nWarning log saved to: #{warning_file}")
          say("Total warnings: #{merger.warning_log.count}")
        end
      end

      # 'merge:badge' => badge.merge (the abort rule of the former task kept: errors need force or a keep_ flag)
      class Badge < Base
        def call # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          say('*** Task: merge:badge ***')
          source = GogglesDb::Badge.find_by(id: env['src'].to_i)&.decorate
          dest = GogglesDb::Badge.find_by(id: env['dest'].to_i)&.decorate
          if source.nil?
            say("You need at least the 'src' ID with a valid value to proceed.")
            stop!(0)
          end

          flags = %w[keep_dest_columns keep_dest_category keep_dest_team force autofix].index_with { |name| env[name] == '1' }
          print_header(source, dest, flags)
          params = { source_id: source.id, dest_id: dest&.id }.merge(flags.transform_keys(&:to_sym).transform_values { |value| flag(value) })
          executor = simulate? ? script_only('badge.merge', params) : preview('badge.merge', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          say("\r\n*** Log: ***\r\n")
          say(operation.merger.log.join("\r\n"))
          # Must specify any override flag to proceed in case of errors
          if operation.merger.errors.present? && !(flags['force'] || flags['keep_dest_columns'] || flags['keep_dest_category'] || flags['keep_dest_team'])
            say('Issues surfaced: use force=1 or any other "keep_" flag to proceed. Aborted.')
            stop!(0)
          end

          executor = apply('badge.merge', params, preview: executor) unless simulate?
          report_script!(executor)
          say('Done.')
        end

        private

        def print_header(source, dest, flags) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          say("\r\n#{dest.nil? ? 'Fixing ' : 'Merging'} Badge (#{source.id}) #{source.display_label}, season #{source.season_id}")
          say("======= team #{source.team_id}, category_type #{source.category_type_id} (#{source.category_type.code})")
          if dest
            say('    |')
            say("    +=> (#{dest.id}) #{dest.display_label}, season #{dest.season_id}")
            say("        team #{dest.team_id}, category_type #{dest.category_type_id} (#{dest.category_type.code})\r\n")
          end
          say("\r\n#{'- SIMULATE'.ljust(50, '.')}: ✔") if simulate?
          say("#{'- AUTOFIX'.ljust(50, '.')}: ✔") if flags['autofix']
          say("#{'- keep ALL dest. columns'.ljust(50, '.')}: ✔") if flags['keep_dest_columns']
          say("#{'- keep dest. category'.ljust(50, '.')}: ✔") if flags['keep_dest_category']
          say("#{'- keep dest. team'.ljust(50, '.')}: ✔") if flags['keep_dest_team']
          say("#{'- enforce ALL source columns conflicts'.ljust(50, '.')}: ✔") if flags['force']
          say("#{'- destination folder'.ljust(50, '.')}: #{script_output_dir}")
        end
      end

      # 'merge:team_in_1_meeting' => meeting.team_fix (the prompt between the preview report and the script kept)
      class TeamInMeeting < Base
        def call # rubocop:disable Metrics/AbcSize
          say('*** Task: merge:team_in_1_meeting ***')
          meeting = GogglesDb::Meeting.find_by(id: env.fetch('meeting', nil).to_i)
          src_team = GogglesDb::Team.find_by(id: env.fetch('src', nil).to_i)
          dest_team = GogglesDb::Team.find_by(id: env.fetch('dest', nil).to_i)
          if meeting.nil? || src_team.nil? || dest_team.nil?
            say("You need valid 'meeting', 'src' & 'dest' IDs to proceed.")
            say('  meeting: Meeting ID')
            say('  src:     source (wrong) Team ID')
            say('  dest:    destination (correct) Team ID')
            stop!(0)
          end

          index = file_index
          full_report = env['full_report'] == '1'
          say("\r\nMeeting: #{meeting.id} - #{meeting.decorate.display_label}")
          say("Merging Team '#{src_team.name}' (#{src_team.id}) |=> '#{dest_team.name}' (#{dest_team.id})")
          say("\r\n- simulate.......: #{simulate?}")
          say("- full_report....: #{full_report}")
          say("- dest. folder...: #{script_output_dir}\r\n")

          params = { meeting_id: meeting.id, source_team_id: src_team.id, dest_team_id: dest_team.id, full_report: flag(full_report), index: }
          executor = preview('meeting.team_fix', params)
          operation = operation_of(executor)
          if operation.argument_error?
            say("\r\n*** ERROR: #{executor.plan.errors.first}")
            stop!(0)
          end
          raise_plan_exception!(operation)

          say("\r\n*** Preview Report: ***\r\n")
          write(operation.captured_output)
          # Always ask for confirmation
          unless confirm?("\r\nProceed with merge? [y/N] ")
            say('Aborted.')
            stop!(0)
          end

          say("\r\nPreparing SQL script...")
          report_script!(write_script('meeting.team_fix', params, preview: executor))
          say('Done.')
        end
      end

      # 'merge:season_fix' => season.badge_fix, one step per run. With simulate=0 the steps are applied in a loop
      # until nothing is left (or nothing changes), as the former task did; with simulate=1 (now the default, as for
      # every task) only the first step is written, held: the next steps need it applied first.
      class SeasonFix < Base
        MAX_ROUNDS = 50

        def call # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/MethodLength,Metrics/PerceivedComplexity
          say("*** Task: merge:season_fix - season #{env.fetch('season', nil)} ***")
          season = GogglesDb::Season.find_by(id: env['season'].to_i)
          if season.nil?
            say('You need a valid Season ID to proceed.')
            stop!(0)
          end
          src_team = env['src_team'].to_i if env['src_team'].present?
          dest_team = env['dest_team'].to_i if env['dest_team'].present?
          if dest_team.present? && src_team.nil?
            say('You need also a valid src_team when specifying a dest_team to force merges.')
            stop!(0)
          end

          say('')
          consider_possible_merges = env['possible'] == '1'
          say("Filtering only badges for team #{src_team}") if src_team
          say('Processing also the "possible merge" candindates!') if consider_possible_merges
          say("[src: #{src_team}] --(will OVERWRITE)--> [dest: #{dest_team}]") if src_team && dest_team
          if consider_possible_merges && src_team.blank?
            say("\r\nWARNING: ⚠ Processing 'possible merges' WITHOUT TEAM FILTERING! ⚠")
            say(I18n.t('maintenance.operations.season_badge_fix.errors.possible_without_team'))
            stop!(0)
          end
          say('--> Running BadgeSeasonChecker to collect candidates...')

          params = { season_id: season.id, include_possible: flag(consider_possible_merges), src_team_id: src_team, dest_team_id: dest_team }
          seen = []
          MAX_ROUNDS.times do |round|
            executor = simulate? ? script_only('season.badge_fix', params) : preview('season.badge_fix', params)
            fixer = print_round(executor, round)
            break if fixer.step.nil? || seen.include?(fixer.planned.map(&:source_id))

            seen << fixer.planned.map(&:source_id)
            executor = apply('season.badge_fix', params, preview: executor) unless simulate?
            report_script!(executor)
            if simulate?
              say("\r\n--> (simulate: the next steps need this script applied first: apply it from the Outbox, then re-run)")
              break
            end
            say("\r\n--> Refreshing BadgeSeasonChecker results...")
          end
          say('Done.')
        end

        private

        # Prints the checker summary and the step of a round; returns the Merge::SeasonBadgeFixer.
        def print_round(executor, round) # rubocop:disable Metrics/AbcSize
          operation = operation_of(executor)
          raise_plan_exception!(operation)
          plan_errors!(executor.plan)
          fixer = operation.fixer
          write(Maintenance::OutputCapture.capture { fixer.checker.display_short_summary }.last)
          if fixer.step.nil?
            say(round.zero? ? "\r\n--> Nothing to fix." : "\r\n--> No changes detected: moving on...")
            return fixer
          end

          say("\r\n--> Step #{fixer.step_number}: #{fixer.step_name}: #{fixer.planned.size}. Preparing SQL script...")
          say("    (#{fixer.deferred.size} deferred to the next round)") if fixer.deferred.any?
          fixer.failed.each { |outcome| say("    ⚠ badge #{outcome.source_id}: #{outcome.message}") }
          fixer
        end
      end
    end
  end
end
