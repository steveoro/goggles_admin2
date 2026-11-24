# frozen_string_literal: true

# = TeamsGrid
#
# DataGrid used to manage GogglesDb::Team rows.
#
class TeamsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:name, :string) { |_value, scope| scope }

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:name)
  column(:editable_name, mandatory: true)

  # (phase 15) the team's badges, affiliations and managers (the team managers API call takes no team id here: by name)
  column(:drill, html: true, mandatory: true, order: false) do |asset|
    safe_join(
      [
        render(Grid::DrillLinkComponent.new(path: api_badges_path(badges_grid: { team_id: asset.id }), icon: 'fa-id-badge',
                                            label: I18n.t('datagrid.drill.badges'), kind: 'badges')),
        render(Grid::DrillLinkComponent.new(path: api_team_affiliations_path(team_affiliations_grid: { team_id: asset.id }),
                                            icon: 'fa-link', label: I18n.t('datagrid.drill.team_affiliations'),
                                            kind: 'team_affiliations')),
        render(Grid::DrillLinkComponent.new(path: api_team_managers_path(team_managers_grid: { team_name: asset.name }),
                                            icon: 'fa-user-tie', label: I18n.t('datagrid.drill.team_managers'),
                                            kind: 'team_managers'))
      ]
    )
  end

  column(:address)
  column(:zip, align: :right)
  column(:phone_mobile)
  column(:phone_number)
  column(:fax_number)
  column(:e_mail)
  column(:contact_name)
  column(:notes)
  column(:name_variations)
  column(:city_id, align: :right)
  column(:home_page_url)

  actions_column(edit: true, destroy: false, mandatory: true)
end
