# frozen_string_literal: true

# = UsersGrid
#
# DataGrid used to manage GogglesDb::User rows.
#
class UsersGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # NOTE: no point in re-filtering scopes already filtered by the API here,
  #       so we return the whole scope (otherwise local filtering would be applied).
  filter(:name, :string) { |_value, scope| scope }
  filter(:description, :string) { |_value, scope| scope }
  filter(:email, :string) { |_value, scope| scope }

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:name, mandatory: true)
  column(:description, mandatory: true)
  # 'swimmer_id' can be nil, need to convert the value:
  column(:swimmer_id, align: :right, mandatory: true,
                      order: proc { |scope| scope.sort { |a, b| a.swimmer_id.to_i <=> b.swimmer_id.to_i } })
  column(:email, mandatory: true)
  column(:last_name)
  column(:first_name)
  column(:year_of_birth)
  column(:provider)
  column(:uid)
  column(:avatar_url)
  column(:swimmer_level_type_id)
  column(:coach_level_type_id)
  column(:jwt)
  column(:outstanding_goggle_score_bias)
  column(:outstanding_standard_score_bias)

  actions_column(edit: true, destroy: true, label_method: 'description', mandatory: true)
end
