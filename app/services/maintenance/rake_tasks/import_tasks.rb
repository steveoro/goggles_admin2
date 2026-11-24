# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::ImportTasks
    #
    # 'import:categories' => categories.clone; 'import:standard_timings' => standard_timings.import (results.new/<season>;
    # simulate=1, the default, writes it held 'not applied locally' as before; simulate=0 applies it locally and holds
    # it until the remote season exists, see the season-start checklist).
    #
    module ImportTasks
      # 'import:categories'
      class Categories < Base
        def call # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          say('*** Task: import:categories ***')
          src_season = GogglesDb::Season.find_by(id: env['src'].to_i)
          dest_season = GogglesDb::Season.find_by(id: env['dest'].to_i)
          if src_season.nil? || dest_season.nil?
            say("You need to have both 'src' & 'dest' IDs with valid Season values in order to proceed.")
            stop!(0)
          end

          remove_codes = env['remove'].present? ? env['remove'].split(',').map(&:strip).compact_blank : []
          say("\r\nCloning CategoryTypes from Season #{src_season.id} (#{src_season.header_year})")
          say("    |=> Season #{dest_season.id} (#{dest_season.header_year})")
          say("\r\n- simulate.......: #{simulate?}")
          say("- remove_codes...: #{remove_codes.any? ? remove_codes.join(', ') : '(none)'}")
          say("- dest. folder...: #{script_output_dir}\r\n")

          params = { src_season_id: src_season.id, dest_season_id: dest_season.id, remove_codes: remove_codes.join(',').presence }
          executor = simulate? ? script_only('categories.clone', params) : preview('categories.clone', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          say("\r\n*** Log: ***\r\n")
          say(operation.cloner.log.join("\r\n"))
          if operation.cloner.errors.present?
            say("\r\n*** Errors: ***\r\n")
            say(operation.cloner.errors.join("\r\n"))
            say('Aborted.')
            stop!(0)
          end

          executor = apply('categories.clone', params, preview: executor) unless simulate?
          report_script!(executor)
          say('Done.')
        end
      end

      # 'import:standard_timings'
      class StandardTimings < Base
        def call # rubocop:disable Metrics/AbcSize
          say("\r\n*** Import StandardTimings from file ***")
          say("\r\nPlease make sure the source file has one of the supported formats:")
          say(' - XLSX: sheets with header row "CATEG*|COD GARA|GARA|SESSO|VASCA|...|TEMPO PRINT"')
          say(' - CSV:  1. "category_code;fin_event_code;event_label;gender;pool_type;hundredths;timing_mmsshh;timing"')
          say('         2. "category_code;event_label;25_m;50_m;25_f;50_f"')
          say('')

          season_id = env.include?('season') ? env['season'].to_i : SeasonDefaults.default_season_id
          season = GogglesDb::Season.find_by(id: season_id)
          if season.nil?
            say('You need a valid Season ID to proceed.')
            stop!(0)
          end

          params = { season_id: season.id, source: env['source'].presence }
          executor = simulate? ? script_only('standard_timings.import', params) : preview('standard_timings.import', params)
          operation = operation_of(executor)
          write(executor.plan.console) unless operation.plan_exception
          raise_plan_exception!(operation)
          print_errors!(operation.importer)
          say("\r\n")
          executor = apply('standard_timings.import', params, preview: executor) unless simulate?
          report!(executor)
        end

        private

        # The former stops: no source file, unreadable XLSX, unknown CSV format, invalid references.
        def print_errors!(importer)
          return if importer.errors.empty?

          if importer.validity_errors.any?
            say("\r\n*** #{importer.validity_errors.count} invalid reference(s) found - fix the source data (or the DB) then retry: ***")
            importer.validity_errors.each { |msg| say("    - #{msg}") }
          else
            say(importer.errors)
          end
          stop!(0)
        end

        def report!(executor)
          run = executor.run
          return report_script!(executor) unless run.succeeded?

          path = data_root.join(run.summary_hash['sql_rel_path'].to_s)
          state = run.script_only? ? 'held in the Outbox: not applied locally' : 'applied locally, held in the Outbox until the remote season exists'
          say("\r\nFile '#{path}' saved (#{state}).")
        end
      end
    end
  end
end
