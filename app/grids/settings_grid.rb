# frozen_string_literal: true

# = SettingsGrid
#
# DataGrid used to manage Settings rows.
#
class SettingsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  # Unscoped data_domain read accessor
  def unscoped
    data_domain
  end

  filter(:key, :string, header: 'Key (~)') do |value, scope|
    scope.select { |row| (row.group_key =~ /#{value}/i) || (row.key =~ /#{value}/i) }
  end

  # Customizes row background color
  def row_class(row)
    group = row&.group_key
    if group.to_s == 'app'
      'bg-light-green'
    elsif group.to_s == 'social_urls'
      'bg-light-blue'
    elsif group.to_s == 'framework_emails'
      'bg-light-yellow'
    elsif group.to_s == 'framework_urls'
      'bg-light-red'
    end
  end

  selection_column
  column(:group_key)
  column(:key)
  column(:value)
  actions_column(edit: true, destroy: true, label_method: 'key')
end
