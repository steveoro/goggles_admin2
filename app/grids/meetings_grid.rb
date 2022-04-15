# frozen_string_literal: true

# = MeetingsGrid
#
# DataGrid used to manage GogglesDb::Meeting rows.
#
class MeetingsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:id, :integer)
  filter(:description, :string, header: 'Any name (~)') do |value, scope|
    scope.select { |row| row.description =~ /#{value}/i }
  end
  filter(:header_date, :date, input_options: { maxlength: 10, placeholder: 'YYYY-MM-DD' })
  filter(:season_id, :integer)
  #-- -------------------------------------------------------------------------
  #++

  selection_column(mandatory: true)

  column(:id, align: :right, mandatory: true)
  column(:description, mandatory: true, order: :description)
  column(:header_date, mandatory: true, order: :header_date)
  column(:season_id, mandatory: true, order: :season_id)
  column(:header_year, mandatory: true, order: false)
  boolean_column(:confirmed, align: :center, mandatory: true, order: false)

  actions_column(edit: true, clone: true, destroy: false, mandatory: true)
end
