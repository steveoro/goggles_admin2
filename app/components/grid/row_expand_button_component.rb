# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.40
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::RowExpandButtonComponent
  #
  # Renders a single "row expand" button linked to a specific ActiveRecord Model row.
  #
  # This is basically a link to a custom page that performs a GET to retrieve the specified asset
  # (model) details via a usual <tt>GET /ENTITY_NAME/ID</tt> API call.
  #
  class RowExpandButtonComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>asset_row</tt>: valid ActiveRecord Model instance to which this button component will be linked to
    # - <tt>controller_name</tt>: Rails controller name for the <tt>:expand</tt> action
    def initialize(asset_row:, controller_name:)
      super
      @asset_row = asset_row
      @controller_name = controller_name
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present?
    end
  end
end
