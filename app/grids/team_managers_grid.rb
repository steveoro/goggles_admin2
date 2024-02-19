# frozen_string_literal: true

# = TeamManagersGrid
#
# DataGrid used to manage GogglesDb::ImportQueue rows.
#
class TeamManagersGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:season_id, :string, header: 'Season ID') { |_value, scope| scope }
  filter(:team_affiliation_id, :integer, header: 'TA ID')
  filter(:team_name, :string, header: 'Team name (~)') { |_value, scope| scope }
  filter(:manager_name, :string, header: 'Manager name (~)') { |_value, scope| scope }
  filter(:season_description, :string, header: 'Season desc. (~)') { |_value, scope| scope }

  # selection_column
  column(:id, align: :right)
  column(:user_id, align: :right)
  column(:manager_name, header: 'Manager', html: true)
  column(:team_affiliation_id, header: 'TA ID', align: :right)

  column(:tas_lookup, header: 'TA', html: true) do |asset|
    link_to(api_team_affiliations_path(team_affiliations_grid: {
                                         team_id: asset.team.id,
                                         season_id: asset.season.id
                                       })) do
      content_tag(:i, '', class: 'fa fa-eye')
    end
  end

  column(
    :team_name, html: true,
                order: proc { |scope| scope.sort { |a, b| a.team&.name <=> b.team&.name } }
  ) do |asset|
    asset.team ? asset.team.name&.truncate(25) : '♻ NEW ♻'
  end
  column(:season, html: true, align: :right) do |asset|
    asset.season ? "<small><i>#{asset.season.season_type.code}</i></small> - #{asset.season.id}".html_safe : '♻'
  end

  column(:created_at, html: true, align: :right) do |asset|
    asset.created_at&.strftime('%Y-%m-%d')
  end

  actions_column(edit: true, destroy: true)
end
