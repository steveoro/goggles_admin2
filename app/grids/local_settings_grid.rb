# frozen_string_literal: true

# = LocalSettingsGrid
#
# Read-only DataGrid listing the Settings stored in the local DB
# (used when the remote API server is unreachable; see SettingsController#index).
#
class LocalSettingsGrid < BaseGrid
  # Returns the scope for the grid. (#assets is the filtered version of it)
  scope { data_domain }

  filter(:key, :string, header: 'Key (~)') do |value, scope|
    scope.select { |row| (row.group_key =~ /#{value}/i) || (row.key =~ /#{value}/i) }
  end

  # Customizes row background color
  def row_class(row)
    SettingsGrid::GROUP_ROW_CLASSES[row&.group_key.to_s]
  end

  column(:group_key)
  column(:key)
  column(:value)
end
