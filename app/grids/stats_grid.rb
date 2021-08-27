# frozen_string_literal: true

# = StatsGrid
#
# DataGrid used to manage GogglesDb::APIDailyUse rows.
#
class StatsGrid < BaseGrid
  filter(:id, :integer)
  filter(:route, :string)
  filter(:day, :date, range: true, input_options: {
           maxlength: 10, placeholder: 'YYYY-MM-DD'
         })

  # Customizes row background color
  def row_class(row)
    route = row&.route
    if route.to_s.starts_with?('GET')
      'bg-light-green'
    elsif route.to_s.starts_with?('PUT')
      'bg-light-blue'
    elsif route.to_s.starts_with?('POST')
      'bg-light-yellow'
    elsif route.to_s.starts_with?('DEL')
      'bg-light-red'
    end
  end

  selection_column
  column(:id, align: :right)
  column(:route)
  column(:day, align: :center)
  column(:count, align: :right)
  actions_column(edit: true, destroy: true, label_method: 'route')
end
