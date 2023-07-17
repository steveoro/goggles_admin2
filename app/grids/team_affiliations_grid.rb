# frozen_string_literal: true

# = TeamAffiliationsGrid
#
# DataGrid used to manage GogglesDb::TeamAffiliation rows.
#
class TeamAffiliationsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:name, :string, header: 'Name (~)') { |_value, scope| scope }
  filter(:team_id, :integer)
  filter(:season_id, :integer)
  filter(:compute_gogglecup, :boolean)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:name, mandatory: true)
  column(:number)
  boolean_column(:compute_gogglecup, align: :center, mandatory: true, order: false)
  column(:team_id, align: :right, mandatory: true)
  column(:team_lookup, header: '~Team', html: true, mandatory: true) do |asset|
    link_to(api_teams_path(teams_grid: { name: asset.team.name })) do
      content_tag(:i, '', class: 'fa fa-eye')
    end
  end

  column(:managers_lookup, header: 'Managers', html: true, mandatory: true) do |asset|
    link_to(api_team_managers_path(team_managers_grid: { team_affiliation_id: asset.id })) do
      content_tag(:i, '', class: 'fa fa-eye')
    end
  end
  column(:badges_lookup, header: 'Badges', html: true, mandatory: true) do |asset|
    link_to(api_badges_path(badges_grid: { team_id: asset.team_id, season_id: asset.season_id })) do
      content_tag(:i, '', class: 'fa fa-eye')
    end
  end

  column(
    :season_type_name, header: 'Season', align: :right, html: true, mandatory: true,
                       order: proc { |scope| scope.sort { |a, b| a.season_type.code <=> b.season_type.code } }
  ) do |asset|
    "<small><i>#{asset.season_type.code}</i></small> - #{asset.season.id}".html_safe
  end
  column(:autofilled, align: :right)

  actions_column(edit: true, destroy: true, mandatory: true)
end
