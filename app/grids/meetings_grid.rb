# frozen_string_literal: true

# = MeetingsGrid
#
# DataGrid used to manage GogglesDb::Meeting rows.
#
# (phase 15) Each row links to the meeting's Season board row and to the calendars of its season (drill column):
# set +board_links+ with the domain (see .board_links_for).
#
class MeetingsGrid < BaseGrid
  # { meeting id => Season board path } for the current domain (see .board_links_for)
  class_attribute(:board_links, default: {})

  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Season board links of the given meetings: only the meetings of the board season (SeasonDefaults.default_season_id)
  # get one, the board row anchor when a local calendar row carries the FIN event id (calendars.results_code), the
  # board itself otherwise. One local query for the whole page; {} when no meeting is in the board season.
  def self.board_links_for(rows)
    season_id = SeasonDefaults.default_season_id
    ids = Array(rows).select { |row| season_id && row.season_id == season_id }.map(&:id)
    return {} if ids.empty?

    fin_ids = GogglesDb::Calendar.where(meeting_id: ids).where.not(results_code: [nil, '']).pluck(:meeting_id, :results_code).to_h
    ids.index_with do |id|
      fin_ids[id] ? SeasonBoard::ActionPaths.board_row_path(fin_ids[id]) : Rails.application.routes.url_helpers.season_board_path
    end
  end

  filter(:name, :string) { |_value, scope| scope }
  # NOTE: ^^^ No point in re-filtering the scope here, since the request already has the
  # API filtering applied on it. So we pretend to evalute the scope, but we'll return it
  # exactly as the APIProxy made it.
  filter(:description, :string)
  filter(:header_date, :date, input_options: { maxlength: 10, placeholder: 'YYYY-MM-DD' })
  filter(:header_year, :string, input_options: { maxlength: 10, placeholder: 'YYY1/YYY2 or YYYY' }) { |_value, scope| scope }
  filter(:season_id, :integer)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:description, mandatory: true, order: :description)
  column(:header_date, mandatory: true, order: :header_date)

  column(:season_id, align: :left, mandatory: true, order: true) do |asset|
    asset.season.id
  end
  column(:season_type_name, align: :left, html: true, mandatory: true,
                            order: proc { |scope| scope.sort { |a, b| a.season_type.code <=> b.season_type.code } }) do |asset|
    "<small><i>#{asset.season_type.code}</i></small>".html_safe
  end

  column(:header_year, mandatory: true, order: false)
  column(:local_mirs, align: :right, html: true, mandatory: true,
                      order: false) do |asset|
    num = GogglesDb::Meeting.find_by(id: asset.id)&.meeting_individual_results&.count || 0
    num.zero? ? "<code>#{num}</code>".html_safe : "<pre>#{num}</pre>".html_safe
  end

  boolean_column(:confirmed, align: :center, mandatory: true, order: false)

  column(:drill, html: true, mandatory: true, order: false) do |asset|
    safe_join(
      [
        render(Grid::DrillLinkComponent.new(path: MeetingsGrid.board_links[asset.id], icon: 'fa-table-list',
                                            label: I18n.t('datagrid.drill.season_board'), kind: 'season_board')),
        render(Grid::DrillLinkComponent.new(path: api_calendars_path(calendars_grid: { season_id: asset.season_id }),
                                            icon: 'fa-calendar-days', label: I18n.t('datagrid.drill.calendars'),
                                            kind: 'calendars'))
      ]
    )
  end

  actions_column(edit: true, clone: true, destroy: false, mandatory: true)
end
