# frozen_string_literal: true

# = ApplicationRecord
#
# Internal class used to represent a single Setting tuple
#
class Setting
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
      id: id,
      group_key: @group_key,
      key: @key,
      value: @value
    }
  end

  # Pseudo-id (String) used to uniquely associate instance <=> rows inside the Datagrid
  def id
    "#{@group_key}-#{@key}"
  end

  alias attributes to_h # (new, old)
end
