# frozen_string_literal: true

# = CategoriesGrid
#
# DataGrid used to manage GogglesDb::CategoryType rows.
#
class CategoriesGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
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
  column(:relay, align: :center)
  column(:season_id, align: :right, mandatory: true)
  column(:out_of_race, align: :center)
  column(:undivided, align: :center)

  actions_column(edit: true, destroy: true, mandatory: true)
end
