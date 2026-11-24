# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::SeasonBoardTasks
    #
    # 'season_board:backfill' => season_board.backfill. simulate=1 (the default) only prints the report and the SQL, as
    # before (no script); simulate=0 applies it through the operation (DB sync gate, local apply, results.new/misc).
    #
    module SeasonBoardTasks
      # 'season_board:backfill'
      class Backfill < Base
        def call # rubocop:disable Metrics/AbcSize
          say('*** Task: season_board:backfill ***')
          season = env['season'].present? ? GogglesDb::Season.find_by(id: env['season'].to_i) : SeasonDefaults.default_season
          if season.nil?
            say("ABORTED: season #{env.fetch('season', nil).inspect} not found.")
            stop!(nil)
          end

          say("\r\n- season.........: #{season.id}")
          say("- simulate.......: #{simulate?}\r\n\r\n")
          params = { season_id: season.id }
          return print_simulation(*inspect_plan('season_board.backfill', params)) if simulate?

          runner.check_gate! # (before anything, as before)
          executor = preview('season_board.backfill', params)
          operation = operation_of(executor)
          raise_plan_exception!(operation)
          plan_errors!(executor.plan)
          say(operation.backfill.report.join("\r\n"))
          return say("\r\nNothing to do: all rows are already up to date.", 'Done.') if executor.plan.empty?

          report_script!(apply('season_board.backfill', params, preview: executor))
          say('Done.')
        end

        private

        def print_simulation(operation, plan)
          raise_plan_exception!(operation)
          plan_errors!(plan)
          backfill = operation.backfill
          say(backfill.report.join("\r\n"))
          if backfill.statements.empty?
            say("\r\nNothing to do: all rows are already up to date.")
          else
            say("\r\n*** SQL (not applied, not saved): ***\r\n")
            say(backfill.sql_log.join("\r\n"))
          end
          say('Done.')
        end
      end
    end
  end
end
