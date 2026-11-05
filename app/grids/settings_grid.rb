# frozen_string_literal: true

# = SettingsGrid
#
# DataGrid used to manage Settings rows.
#
class SettingsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:key, :string, header: 'Key (~)') do |value, scope|
    scope.select { |row| (row.group_key =~ /#{value}/i) || (row.key =~ /#{value}/i) }
  end

  # Row background colors by setting group
  GROUP_ROW_CLASSES = {
    'app' => 'bg-light-green',
    'social_urls' => 'bg-light-blue',
    'framework_emails' => 'bg-light-yellow',
    'framework_urls' => 'bg-light-red'
  }.freeze

  # Customizes row background color
  def row_class(row)
    GROUP_ROW_CLASSES[row&.group_key.to_s]
  end

  selection_column
  column(:group_key)
  column(:key)
  column(:value)
  actions_column(edit: true, destroy: true, label_method: 'key')
end
