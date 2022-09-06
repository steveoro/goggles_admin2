# frozen_string_literal: true

# = CategoriesGrid
#
# DataGrid used to manage GogglesDb::CategoryType rows.
#
class CategoriesGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:season_id, :integer)
  filter(:code)
  filter(:relay, :boolean)
  filter(:out_of_race, :boolean)
  filter(:undivided, :boolean)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:code, mandatory: true)
  column(:federation_code)
  column(:description)
  column(:short_name, mandatory: true)
  column(:group_name, mandatory: true)
  column(:age_begin)
  column(:age_end)
  column(
    :season_type_name, header: 'Season', align: :right, html: true, mandatory: true,
    order: proc { |scope| scope.sort { |a, b| a.season_type.short_name <=> b.season_type.short_name } }
  ) do |asset|
    "<small><i>#{asset.season_type.code}</i></small> - #{asset.season.id}".html_safe
  end
  boolean_column(:relay, align: :center, mandatory: true, order: false)
  boolean_column(:out_of_race, align: :center, mandatory: true, order: false)
  boolean_column(:undivided, align: :center)

  actions_column(edit: true, destroy: true, mandatory: true)
end
