# frozen_string_literal: true

# = SwimmersGrid
#
# DataGrid used to manage GogglesDb::Swimmer rows.
#
class SwimmersGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
  filter(:name, :string, header: 'Name (~)') do |value, scope|
    scope.select do |row|
      (row.complete_name =~ /#{value}/i) || (row.last_name =~ /#{value}/i) ||
        (row.last_name =~ /#{value}/i)
    end
  end
  filter(:year_of_birth, :integer)
  filter(:year_guessed, :boolean)

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
  column(:gender_type_id, align: :right)
  column(:complete_name, mandatory: true)
  boolean_column(:year_guessed, align: :center, mandatory: true, order: false)

  actions_column(edit: true, destroy: false, mandatory: true)
end
