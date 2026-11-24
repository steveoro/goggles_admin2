# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::PurgeTasks
    #
    # 'purge:meeting' => meeting.purge (the prompt between the row counts and the script kept).
    #
    module PurgeTasks
      # 'purge:meeting'
      class Meeting < Base
        def call # rubocop:disable Metrics/AbcSize
          say('*** Task: purge:meeting ***')
          meeting = GogglesDb::Meeting.find_by(id: env['meeting'].to_i)
          if meeting.nil?
            say("You need a valid 'meeting' ID to proceed.")
            stop!(0)
          end

          stop_at_events = env['stop_at_events'] == '1'
          say("\r\nPurging Meeting #{meeting.id} - #{meeting.description}")
          say("\r\n- simulate.........: #{simulate?}")
          say("- stop_at_events...: #{stop_at_events}")
          say("- dest. folder.....: #{script_output_dir}\r\n")

          params = { meeting_id: meeting.id, stop_at_events: flag(stop_at_events) }
          executor = preview('meeting.purge', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          # Ask for confirmation before generating the file
          unless confirm?("\r\nProceed with generating purge script? [y/N] ")
            say('Aborted.')
            stop!(0)
          end

          report_script!(write_script('meeting.purge', params, preview: executor))
          say('Done.')
        end
      end
    end
  end
end
