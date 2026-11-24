# frozen_string_literal: true

module Maintenance
  module RakeTasks
    #
    # = Maintenance::RakeTasks::RecomputeTasks
    #
    # 'recompute:ranks' => ranks.recompute (switched to Recompute::Ranks in phase 11; the script keeps its former name
    # '<season id>-recompute_ranks').
    #
    module RecomputeTasks
      # 'recompute:ranks'
      class Ranks < Base
        def call # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
          say("*** Task: recompute:ranks - season #{env.fetch('season', nil)} ***")
          season = GogglesDb::Season.joins(:meetings).includes(:meetings).find_by(id: env['season'].to_i)
          meeting = GogglesDb::Meeting.joins(:meeting_programs).includes(:meeting_programs).find_by(id: env['meeting'].to_i) if season.blank?
          if season.nil? && meeting.nil?
            say('You need a valid Season ID or Meeting ID to proceed.')
            stop!(0)
          end

          season_id = season&.id || meeting.season_id
          params = season ? { season_id: } : { meeting_id: meeting.id }
          name = "#{season_id}-recompute_ranks"
          file_name = "#{format('%04d', file_index)}-#{name}"
          say("\r\n#{'- SIMULATE'.ljust(25, '.')}: ✔") if simulate?
          say("- #{season ? season.meetings.joins(:meeting_programs).includes(:meeting_programs).count : 1} meetings found.")
          say('')

          executor = simulate? ? script_only('ranks.recompute', params, script_name: name) : preview('ranks.recompute', params)
          operation = operation_of(executor)
          write(operation.captured_output)
          raise_plan_exception!(operation)
          say("\r\nGenerating file '#{file_name}'...")
          executor = apply('ranks.recompute', params, preview: executor, script_name: name) unless simulate?
          report_script!(executor)
          say('Done.')
        end
      end
    end
  end
end
