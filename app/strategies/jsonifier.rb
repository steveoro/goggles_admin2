# frozen_string_literal: true

require 'singleton'

# = JSONifier
#
#   - file vers.: 0.3.33
#   - author....: Steve A.
#   - build.....: 20210928
#
#   Tool for converting AR Models instances into proper JSON payloads.
#   Formats datetime values so that they can be easily set & parsed by HTML form inputs.
#
class Jsonifier
  include Singleton

  HTML_DATETIME_FORMAT = '%Y-%m-%dT%H:%M:%S'

  # ActiveRecord Model-2-JSON payload adapter
  #
  # == Params
  # - <tt>asset_row</tt>:
  #   a valid ActiveRecord Model instance (*required*)
  #
  # == Returns
  # A valid JSON string, representing all <tt>asset_row</tt> attributes and their corresponding values.
  #
  def self.call(asset_row)
    return '{}' unless asset_row.present? && asset_row.respond_to?(:attributes)

    attrs = asset_row.attributes
    attrs.each do |attr_name, attr_value|
      next unless attr_value.present? && asset_row.class.respond_to?(:column_for_attribute) &&
                  asset_row.class.column_for_attribute(attr_name).type == :datetime

      # Convert DateTime values:
      attrs[attr_name] = attr_value.strftime(HTML_DATETIME_FORMAT)
    end

    attrs.to_json
  end
  #-- -------------------------------------------------------------------------
  #++
end
