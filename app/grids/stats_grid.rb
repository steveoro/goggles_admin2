class StatsGrid < BaseGrid
  @@data_domain = []

  scope do
    @@data_domain
  end

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

  sortable_column(:id)
  sortable_column(:route)
  date_column(:day)
  # TODO: try to  make the date column actually sortable
  sortable_column(:count)

  column(:actions, html: true) do |record|
    content_tag(:div, class: 'text-center') do
      button_to('X', stats_delete_path(record.id), id: "frm-delete-row-#{record.id}", method: :delete,
                class: 'btn btn-sm btn-outline-danger',
                data: { confirm: t('dashboard.confirm_row_delete', label: record.route) })
    end
  end
end
