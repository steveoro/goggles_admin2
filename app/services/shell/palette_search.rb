# frozen_string_literal: true

module Shell
  #
  # = Shell::PaletteSearch
  #
  # The local search of the command palette (phase 15, <tt>GET /palette/search?q=</tt>, Shell::PaletteController):
  # meetings, teams and swimmers of the localhost DB (LookupController.search_scope: name fragment or id, newest
  # first) and the Data-Fix sessions (DataFix::SessionIndex: every word in the source file name). At most
  # MAX_RESULTS in all, shared fairly among the kinds. No remote call (the sidebar pages are matched in the browser).
  #
  # == Usage
  #   Shell::PaletteSearch.new('riccione').results # => [#<data Shell::PaletteSearch::Result kind: :meeting, ...>, ...]
  #
  class PaletteSearch
    # Results returned in all
    MAX_RESULTS = 20

    # Shortest query searched
    MIN_QUERY = 2

    # Kinds, in display order: kind => [model (nil for the Data-Fix sessions), icon]
    KINDS = {
      meeting: [GogglesDb::Meeting, 'fa-flag-checkered'],
      team: [GogglesDb::Team, 'fa-people-group'],
      swimmer: [GogglesDb::Swimmer, 'fa-person-swimming'],
      data_fix_session: [nil, 'fa-wand-magic']
    }.freeze

    # One palette result (see #to_h for the JSON of the endpoint)
    Result = Data.define(:kind, :label, :detail, :path, :icon) do
      def to_h
        super.merge(kind_label: I18n.t("shell.palette.kinds.#{kind}"))
      end
    end

    attr_reader :query

    # == Params:
    # - query: the text typed in the palette;
    # - session_index: the DataFix::SessionIndex to search (default: a fresh scan of crawler/data).
    def initialize(query, session_index: nil)
      @query = query.to_s.squish
      @session_index = session_index
    end

    # @return [Array<Result>] at most MAX_RESULTS, grouped by kind (KINDS order)
    def results
      return [] if query.length < MIN_QUERY

      balance(KINDS.keys.map { |kind| send(:"#{kind}_results") })
    end

    private

    def meeting_results
      rows_for(:meeting).map do |meeting|
        result(:meeting, meeting.description, I18n.t('shell.palette.meeting_detail', date: meeting.header_date, season: meeting.season_id),
               url_helpers.api_meetings_path(meetings_grid: { name: meeting.description, season_id: meeting.season_id }))
      end
    end

    def team_results
      rows_for(:team).map do |team|
        result(:team, team.name, team.city&.name, url_helpers.api_teams_path(teams_grid: { name: team.name }))
      end
    end

    def swimmer_results
      rows_for(:swimmer).map do |swimmer|
        result(:swimmer, swimmer.complete_name, swimmer.year_of_birth.to_s,
               url_helpers.api_swimmers_path(swimmers_grid: { name: swimmer.complete_name }))
      end
    end

    # Sessions whose source file name holds every word of the query; the Resume step (the sessions list when the
    # source file is gone).
    def data_fix_session_results
      words = normalize(query).split
      rows = session_index.rows.select { |row| words.all? { |word| normalize(row.name).include?(word) } }
      rows.first(MAX_RESULTS).map do |row|
        detail = I18n.t('shell.palette.session_detail', season: row.season_id || '-', phase: row.highest_phase)
        result(:data_fix_session, row.name, detail, resume_path(row))
      end
    end

    def rows_for(kind)
      LookupController.search_scope(KINDS.dig(kind, 0), query).order(id: :desc).limit(MAX_RESULTS).to_a
    end

    def result(kind, label, detail, path)
      Result.new(kind:, label: label.to_s, detail: detail.presence, path:, icon: KINDS.dig(kind, 1))
    end

    def resume_path(row)
      return url_helpers.data_fix_sessions_path unless row.source_exists?

      helper = DataFix::SessionsListController::RESUME_STEPS.fetch(row.highest_phase.clamp(1, 5))
      url_helpers.public_send(helper, file_path: row.source_path)
    end

    # Round-robin over the kinds (the first row of each, then the second...) until MAX_RESULTS, then back in kind order.
    def balance(lists)
      slots = (0...lists.map(&:size).max.to_i).flat_map do |level|
        lists.each_index.select { |index| level < lists[index].size }.map { |index| [index, level] }
      end
      kept = slots.first(MAX_RESULTS).group_by(&:first)
      lists.each_index.flat_map { |index| Array(kept[index]).map { |_index, level| lists[index][level] } }
    end

    def normalize(text)
      I18n.transliterate(text.to_s).downcase.tr('_-', '  ')
    end

    def session_index
      @session_index ||= DataFix::SessionIndex.new
    end

    def url_helpers
      Rails.application.routes.url_helpers
    end
  end
end
