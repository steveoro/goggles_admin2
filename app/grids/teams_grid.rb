# frozen_string_literal: true

# = TeamsGrid
#
# DataGrid used to manage GogglesDb::Team rows.
#
class TeamsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
  filter(:name, :string, header: 'Name (~)') do |value, scope|
    scope.select { |row| (row.name =~ /#{value}/i) || (row.editable_name =~ /#{value}/i) }
  end

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:name)
  column(:editable_name, mandatory: true)
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
