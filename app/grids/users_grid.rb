# frozen_string_literal: true

# = UsersGrid
#
# DataGrid used to manage GogglesDb::User rows.
#
class UsersGrid < BaseGrid
  filter(:id, :integer)
  filter(:name, :string)
  filter(:swimmer_id, :integer)
  filter(:created_at, :date, range: true, input_options: {
           maxlength: 10, placeholder: 'YYYY-MM-DD'
         })

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:name, mandatory: true)
  column(:description, mandatory: true)
  column(:swimmer_id, align: :right, mandatory: true)
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
