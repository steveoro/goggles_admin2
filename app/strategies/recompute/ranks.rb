# frozen_string_literal: true

module Recompute
  #
  # = Recompute::Ranks
  #
  # Recomputes the ranks of the MIRs and MRRs of a whole Season or of a single Meeting, program by program, sorting
  # the rows by timing (timed rows first, then the zero timings), and collects one UPDATE per row whose rank changes,
  # wrapped in a single transaction (Merge::Badge.start_transaction_log / end_transaction_log). Never writes: the
  # caller runs or registers the script ('recompute:ranks' rake task, 'ranks.recompute' maintenance operation).
  #
  # Extracted from lib/tasks/recompute.rake (phase 11); the task output is unchanged: its progress lines (meeting
  # headers, one dot per program) are printed by the task from the events yielded by #call, never by this class.
  #
  # == Usage
  #   ranker = Recompute::Ranks.new(meeting: meeting).call
  #   ranker.sql_log              # => Array of SQL lines (header, UPDATEs, COMMIT)
  #   ranker.updates_by_meeting   # => { meeting_id => UPDATE count }
  #
  #   ranker.call do |event, payload|   # :meeting (description), :program (MeetingProgram), :meeting_done (Meeting)
  #     ...
  #   end
  #
  class Ranks
    attr_reader :season, :meeting, :sql_log, :updates_by_meeting

    # == Params
    # - season: GogglesDb::Season (has priority over the meeting, as in the rake task);
    # - meeting: GogglesDb::Meeting, used only without a season.
    def initialize(season: nil, meeting: nil)
      @meeting = season.present? ? nil : meeting
      @season = season.presence || @meeting&.season
      raise(ArgumentError, 'A Season or a Meeting is required') if @season.nil?

      @sql_log = []
      @updates_by_meeting = {}
    end

    # The meetings processed: the single meeting, or every season meeting having programs.
    def meetings
      @meetings ||= meeting.present? ? [meeting] : season.meetings.joins(:meeting_programs).includes(:meeting_programs)
    end

    # Builds #sql_log; yields the progress events when a block is given. Returns self.
    def call # rubocop:disable Metrics/AbcSize
      count = meetings.count
      @sql_log = Merge::Badge.start_transaction_log.dup + ["--\r\n-- *** Recompute ranks: season #{season.id}, #{count} meeting(s) ***\r\n--\r\n"]
      @updates_by_meeting = {}
      meetings.each_with_index do |row, index|
        description = "Meeting #{index + 1}/#{count}, ID #{row.id} '#{row.description}', " \
                      "MIRs: #{row.meeting_individual_results.count}, MRRs: #{row.meeting_relay_results.count}"
        yield(:meeting, description) if block_given?
        @sql_log << "-- #{description}"
        @updates_by_meeting[row.id] = 0
        row.meeting_programs.each do |meeting_program|
          rank_program(row, meeting_program)
          yield(:program, meeting_program) if block_given?
        end
        yield(:meeting_done, row) if block_given?
      end
      @sql_log += Merge::Badge.end_transaction_log
      self
    end

    # Total number of UPDATE statements.
    def updates_count = @updates_by_meeting.values.sum

    private

    def rank_program(meeting_row, meeting_program) # rubocop:disable Metrics/AbcSize
      rows = meeting_program.relay? ? meeting_program.meeting_relay_results : meeting_program.meeting_individual_results
      with_time = rows.by_timing.to_a.keep_if { |row| row.to_timing.positive? }
      with_no_time = rows.by_timing.to_a.keep_if { |row| row.to_timing.zero? }

      (with_time + with_no_time).each_with_index do |row, row_index|
        next if row.rank == row_index + 1

        @sql_log << "UPDATE #{row.class.table_name} SET updated_at=NOW(), rank=#{row_index + 1} WHERE id = #{row.id}; " \
                    "-- MPrg: #{meeting_program.id}, #{row.to_timing}"
        @updates_by_meeting[meeting_row.id] += 1
      end
    end
  end
end
