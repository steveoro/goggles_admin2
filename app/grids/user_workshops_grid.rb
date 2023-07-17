# frozen_string_literal: true

# = UserWorkshopsGrid
#
# DataGrid used to manage GogglesDb::UserWorkshop rows.
#
class UserWorkshopsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # NOTE: no point in re-filtering scopes already filtered by the API here,
  #       so we return the whole scope (otherwise local filtering would be applied).
  filter(:description, :string, header: 'Name (~)') { |_value, scope| scope }
  filter(:date, :date, input_options: { maxlength: 10, placeholder: 'YYYY-MM-DD' })
  filter(:header_year, :string, input_options: { maxlength: 10, placeholder: 'YYY1/YYY2 or YYYY' }) { |_value, scope| scope }
  filter(:season_id, :integer, header: 'Season ID')
  filter(:team_id, :integer, header: 'Team ID')
  filter(:user_id, :integer, header: 'User ID')

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:description, mandatory: true, order: :description)
  column(:header_date, mandatory: true, order: :header_date)
  column(
    :season_type_name, header: 'Season', align: :left, html: true, mandatory: true,
                       order: proc { |scope| scope.sort { |a, b| a.season_type.code <=> b.season_type.code } }
  ) do |asset|
    "<small><i>#{asset.season_type.code}</i></small> - #{asset.season.id}".html_safe
  end
  column(:header_year, mandatory: true, order: false)
  boolean_column(:confirmed, align: :center, mandatory: true, order: false)
  column(
    :team_name, header: 'Team', html: true, mandatory: true,
                order: proc { |scope| scope.sort { |a, b| a.team.name <=> b.team.name } }
  ) do |asset|
    "<small>#{asset.team.name}</small>".html_safe
  end

  actions_column(edit: true, destroy: true, mandatory: true)
end
