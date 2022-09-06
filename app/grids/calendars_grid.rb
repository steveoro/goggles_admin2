# frozen_string_literal: true

# = CalendarsGrid
#
# DataGrid used to manage GogglesDb::Calendar rows.
#
class CalendarsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:season_id, :integer, header: 'Season ID')

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:meeting_id, mandatory: true)
  column(:meeting_name, mandatory: true, order: :meeting_name)
  column(:meeting_code, mandatory: true)
  column(:scheduled_date, mandatory: true)
  column(
    :season_type_name, header: 'Season', align: :left, html: true, mandatory: true,
    order: proc { |scope| scope.sort { |a, b| a.season_type.code <=> b.season_type.code } }
  ) do |asset|
    "<small><i>#{asset.season_type.code}</i></small> - #{asset.season.id}".html_safe
  end

  actions_column(edit: true, destroy: true, mandatory: true)
end
