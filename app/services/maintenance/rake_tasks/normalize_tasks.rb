# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::NormalizeTasks
    #
    # 'normalize:coded_names' => coded_names.normalize (results.new/misc, as since phase 07).
    #
    module NormalizeTasks
      # 'normalize:coded_names'
      class CodedNames < Base
        def call
          say('*** Task: normalize:coded_names ***')
          limit_rows = env.include?('limit') ? env['limit'].to_i : 0
          say("\r\n- limit..........: #{limit_rows.positive? ? limit_rows : '(all rows)'}")
          say("- simulate.......: #{simulate?}")
          say("- dest. folder...: #{script_output_dir}/misc\r\n")

          params = { limit: limit_rows }
          executor = simulate? ? script_only('coded_names.normalize', params) : preview('coded_names.normalize', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          print_changes(operation.normalizer)
          executor = apply('coded_names.normalize', params, preview: executor) unless simulate?
          report_script!(executor)
          say('Done.')
        end

        private

        def print_changes(normalizer)
          say("\r\n*** Change log: ***\r\n")
          say(normalizer.change_log.join("\r\n"))
          if normalizer.duplicate_pool_ids.present?
            say("\r\nWARNING: found already existing coded names in SwimmingPool IDs #{normalizer.duplicate_pool_ids.inspect}")
            say('(those rows were skipped in the script; a manual fix is required)')
          end
          say("\r\n-- Stats: meetings scanned #{normalizer.stats[:meetings_scanned]}, updated #{normalizer.stats[:meetings_updated]}; " \
              "pools scanned #{normalizer.stats[:pools_scanned]}, updated #{normalizer.stats[:pools_updated]}")
        end
      end
    end
  end
end
