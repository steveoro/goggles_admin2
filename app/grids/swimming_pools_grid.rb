# frozen_string_literal: true

# = SwimmingPoolsGrid
#
# DataGrid used to manage GogglesDb::SwimmingPool rows.
#
class SwimmingPoolsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # NOTE: no point in re-filtering scopes already filtered by the API here,
  #       so we return the whole scope (otherwise local filtering would be applied).
  filter(:name, :string, header: 'Name (~)') { |_value, scope| scope }
  filter(:address, :string, header: 'Address (~)') { |_value, scope| scope }
  filter(:pool_type_id,
         :enum, header: 'PoolType',
         select: proc { GogglesDb::PoolType.all.map {|c| [c.code, c.id] }}
        ) { |_value, scope| scope }
  filter(:city_id, :integer, header: 'City ID')

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:name, mandatory: true)
  column(:nick_name, mandatory: true)
  column(:pool_type_id, align: :right)
  column(:pool_type, html: true, align: :right, mandatory: true) { |asset| asset.pool_type.code }
  column(:city_id, align: :right)
  column(:city, html: true, align: :right, mandatory: true) { |asset| asset.city.name }
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
