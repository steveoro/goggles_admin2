# frozen_string_literal: true

# = SwimmingPoolsGrid
#
# DataGrid used to manage GogglesDb::SwimmingPool rows.
#
class SwimmingPoolsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
  filter(:name, :string, header: 'Name (~)') do |value, scope|
    scope.select do |row|
      (row.name =~ /#{value}/i) || (row.nick_name =~ /#{value}/i)
    end
  end
  filter(:address, :string, header: 'Address (~)') do |value, scope|
    scope.select do |row|
      row.address =~ /#{value}/i
    end
  end

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)

  column(:name, mandatory: true)
  column(:nick_name, mandatory: true)

  column(:pool_type_id, align: :right, mandatory: true)
  column(:city_id, align: :right, mandatory: true)
  column(:address)
  column(:zip)

  column(:phone_number)
  column(:fax_number)
  column(:e_mail)
  column(:contact_name)
  column(:maps_uri)

  column(:lanes_number, align: :right)
  column(:multiple_pools, align: :center)
  column(:garden, align: :center)
  column(:bar, align: :center)
  column(:restaurant, align: :center)
  column(:gym, align: :center)
  column(:child_area, align: :center)

  column(:notes)
  column(:shower_type_id, align: :right)
  column(:hair_dryer_type_id, align: :right)
  column(:locker_cabinet_type_id, align: :right)

  column(:read_only, align: :center)
  column(:latitude)
  column(:longitude)
  column(:plus_code)

  actions_column(edit: true, destroy: false, mandatory: true)
end
