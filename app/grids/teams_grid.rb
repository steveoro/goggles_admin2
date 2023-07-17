# frozen_string_literal: true

# = TeamsGrid
#
# DataGrid used to manage GogglesDb::Team rows.
#
class TeamsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:name, :string, header: 'Name (~)') { |_value, scope| scope }

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:name)
  column(:editable_name, mandatory: true)

  column(:tas_lookup, header: 'TAs', html: true, mandatory: true) do |asset|
    link_to(api_team_affiliations_path(team_affiliations_grid: { team_id: asset.id })) do
      content_tag(:i, '', class: 'fa fa-eye')
    end
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
