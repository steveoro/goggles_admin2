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

  # Filters using direct IDs will be propagated on all the pages (the filter field must be present in the query)
  filter(:team_affiliation_id, :integer, header: 'TA ID')
  filter(:manager_name, :string, header: 'Manager name (~)') do |value, scope|
    scope.select { |row| row.manager&.name =~ /#{value}/i }
  end
  filter(:team_name, :string, header: 'Team name (~)') do |value, scope|
    scope.select { |row| (row.team&.name =~ /#{value}/i) || (row.team&.editable_name =~ /#{value}/i) }
  end

  selection_column
  column(:id, align: :right)
  column(:user_id, align: :right)
  column(:manager_name, header: 'Manager', html: true)
  column(:team_affiliation_id, header: 'TA ID', align: :right)
  column(
    :team_name, html: true,
                order: proc { |scope| scope.sort { |a, b| a.team&.name <=> b.team&.name } }
  ) do |asset|
    asset.team ? asset.team.name&.truncate(25) : '♻ NEW ♻'
  end
  column(:season, html: true, align: :right) { |asset| asset.season ? asset.season.id : '♻' }
  date_column(:created_at)
  actions_column(edit: true, destroy: true)
end
