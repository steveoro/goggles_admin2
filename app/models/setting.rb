# frozen_string_literal: true

# = ApplicationRecord
#
# Internal class used to represent a single Setting tuple
#
class Setting
  SPLIT_ID_CHAR = '§'

  attr_accessor :group_key, :key, :value

  # Creates a new Setting instance
  def initialize(group_key: nil, key: nil, value: nil)
    @group_key = group_key
    @key = key
    @value = value
  end

  # Returns self as an Hash
  def to_h
    {
      id:,
      group_key: @group_key,
      key: @key,
      value: @value
    }
  end

  # Returns the list of Setting rows stored in the local DB: all the base setting groups
  # (GogglesDb::AppParameter::SETTINGS_GROUPS) plus the specified user's :prefs.
  def self.local_domain(user)
    (GogglesDb::AppParameter::SETTINGS_GROUPS + [:prefs]).flat_map do |group_key|
      cfg_row = group_key.to_sym == :prefs ? user : GogglesDb::AppParameter.config
      (cfg_row.settings(group_key).value || {}).map { |key, value| new(group_key:, key:, value:) }
    end
  end

  # Pseudo-id (String) used to uniquely associate instance <=> rows inside the Datagrid
  def id
    "#{@group_key}#{SPLIT_ID_CHAR}#{@key}"
  end

  alias attributes to_h # (new, old)
end
