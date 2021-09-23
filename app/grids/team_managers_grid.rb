# frozen_string_literal: true

# = TeamManagersGrid
#
# DataGrid used to manage GogglesDb::ImportQueue rows.
#
class TeamManagersGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:manager, :integer)

  selection_column
  column(:id, align: :right)
  column(:user_id, align: :right)
  column(:manager_name, header: 'Manager', html: true)
  column(:team_affiliation_id, header: 'TA ID', align: :right)
  column(:team_name, html: true) { |asset| asset.team.name.truncate(25) }
  column(:season, html: true, align: :right) { |asset| asset.season.id }
  date_column(:created_at)
  actions_column(edit: true, destroy: true)
end
