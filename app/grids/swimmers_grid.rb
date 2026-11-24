# frozen_string_literal: true

# = SwimmersGrid
#
# DataGrid used to manage GogglesDb::Swimmer rows.
#
class SwimmersGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # NOTE: no point in re-filtering scopes already filtered by the API here,
  #       so we return the whole scope (otherwise local filtering would be applied).
  filter(:name, :string) { |_value, scope| scope }
  filter(:year_of_birth, :integer)
  filter(:year_guessed, :boolean)
  filter(:gender_type_id,
         :enum, select: proc { GogglesDb::GenderType.all.map { |c| [c.code, c.id] } }) { |_value, scope| scope }

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)

  column(:last_name, mandatory: true)
  column(:first_name, mandatory: true)
  column(:year_of_birth, align: :right, mandatory: true)
  column(:phone_mobile)
  column(:phone_number)
  column(:e_mail)
  column(:nickname)
  column(:associated_user_id, align: :right)
  column(:gender_type_id, align: :right, mandatory: true)
  column(:complete_name, mandatory: true)
  # (phase 15) the swimmer's badges
  column(:drill, html: true, mandatory: true, order: false) do |asset|
    render(Grid::DrillLinkComponent.new(path: api_badges_path(badges_grid: { swimmer_id: asset.id }), icon: 'fa-id-badge',
                                        label: I18n.t('datagrid.drill.badges'), kind: 'badges'))
  end
  boolean_column(:year_guessed, align: :center, mandatory: true, order: false)

  actions_column(edit: true, destroy: false, mandatory: true)
end
