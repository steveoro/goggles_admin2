# frozen_string_literal: true

# = MeetingsGrid
#
# DataGrid used to manage GogglesDb::Meeting rows.
#
class MeetingsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:description, :string, header: 'Name (~)') { |_value, scope| scope }
  # NOTE: ^^^ No point in re-filtering the scope here, since the request already has the
  # API filtering applied on it. So we pretend to evalute the scope, but we'll return it
  # exactly as the APIProxy made it.
  filter(:date, :date, input_options: { maxlength: 10, placeholder: 'YYYY-MM-DD' })
  filter(:header_year, :string, input_options: { maxlength: 10, placeholder: 'YYY1/YYY2 or YYYY' }) { |_value, scope| scope }
  filter(:season_id, :integer)

  selection_column(mandatory: true)
  column(:id, align: :right, mandatory: true)
  column(:description, mandatory: true, order: :description)
  column(:header_date, mandatory: true, order: :header_date)
  column(
    :season_type_name, header: 'Season', align: :left, html: true, mandatory: true,
                       order: proc { |scope| scope.sort { |a, b| a.season_type.code <=> b.season_type.code } }
  ) do |asset|
    "<small><i>#{asset.season_type.code}</i></small> - #{asset.season.id}".html_safe
  end
  column(:header_year, mandatory: true, order: false)
  boolean_column(:confirmed, align: :center, mandatory: true, order: false)

  actions_column(edit: true, clone: true, destroy: false, mandatory: true)
end
