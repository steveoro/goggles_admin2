# frozen_string_literal: true

module Maintenance
  module Inspectors
    #
    # = Maintenance::Inspectors::MapSwimmerMirs ('swimmer.map_mirs')
    #
    # The table of 'check:map_swimmer_mirs': every MIR of a swimmer with its season, badge, team and team affiliation
    # (all seasons, or the latest 7; 50 per page when +page+ is given, else all rows). Read only. The 'stopped' fact
    # tells the rake caller that the task stopped early (no MIR, or an empty page).
    #
    class MapSwimmerMirs < Maintenance::Inspector
      self.key = 'swimmer.map_mirs'

      PER_PAGE = 50

      param :swimmer_id, :integer, lookup: :swimmer
      param :last7, :flag
      param :page

      validates :swimmer_id, presence: true

      def self.params_from_finding(_finding) = {}

      def subject = ['swimmer', swimmer_id]
      def label = I18n.t('maintenance.operations.swimmer_map_mirs.label', id: swimmer_id)

      protected

      def build_plan # rubocop:disable Metrics/AbcSize
        swimmer = GogglesDb::Swimmer.find_by(id: swimmer_id)
        return report_plan(errors: [I18n.t('maintenance.errors.not_found', what: 'Swimmer', id: swimmer_id)]) unless swimmer

        paginate = !page.nil?
        page_idx = page.to_i
        mirs = GogglesDb::MeetingIndividualResult.includes(:meeting, :season).joins(:season, :meeting).where(swimmer_id: swimmer.id)
        if flag?(:last7)
          min_season_id = GogglesDb::LastSeasonId.last.id - 70 # (season IDs are fixed and increased by 10 each championship)
          mirs = mirs.where('seasons.id >= ?', min_season_id) # rubocop:disable Rails/WhereRange
        end
        mirs = mirs.order('seasons.id ASC, meetings.header_date ASC, meeting_individual_results.id ASC')
        mirs_count = mirs.count
        max_page_idx = [(mirs_count.to_f / PER_PAGE).ceil - 1, 0].max
        $stdout.puts("\r\n--> Swimmer ID #{swimmer.id}")
        $stdout.puts(paginate ? "--> Found #{mirs_count} MIRs => showing page #{page_idx} (/#{max_page_idx})" : "--> Found #{mirs_count} MIRs => showing all rows")
        stopped = { 'mirs' => mirs_count, 'stopped' => true }
        return report_plan(summary: stopped) if mirs.empty?

        mirs_page = paginate ? mirs.page(page_idx + 1).per(PER_PAGE) : mirs
        return report_plan(summary: stopped) if paginate && mirs_page.empty?

        print_table(swimmer, mirs_page)
        report_plan(subjects: [{ 'type' => 'swimmer', 'id' => swimmer.id }], summary: { 'mirs' => mirs_count, 'stopped' => false })
      end

      private

      def print_table(swimmer, mirs_page) # rubocop:disable Metrics/AbcSize
        $stdout.puts("--> Swimmer: #{swimmer.decorate.display_label}")
        curr_season = 0
        $stdout.puts('MIR'.ljust(12) + ' | Season'.ljust(10) + ' | Badge'.ljust(12) + ' | Team'.ljust(12) + ' | Team Aff.'.ljust(12) + ' | Team Name'.ljust(38) +
             ' | Header Date'.ljust(12) + ' | Meeting'.ljust(50))
        mirs_page.map do |mir|
          if curr_season != mir.season.id
            $stdout.puts(''.center(154, '-'))
            curr_season = mir.season.id
          end
          $stdout.puts("#{mir.id.to_s.rjust(12)} | #{mir.season.id.to_s.rjust(7)} | #{mir.badge_id.to_s.rjust(9)} | #{mir.team_id.to_s.rjust(9)} | " \
                       "#{mir.team_affiliation_id.to_s.rjust(9)} | #{mir.team.name.truncate(35).ljust(35)} | #{mir.meeting.header_date.to_s.ljust(11)} | " \
                       "#{mir.meeting.description.ljust(50)}")
        end
        $stdout.puts("\r\n")
      end
    end
  end
end
