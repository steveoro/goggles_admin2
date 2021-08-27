# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::RowDeleteButtonComponent
  #
  # Renders a single "row delete" button linked to a specific ActiveRecord Model row.
  #
  # The DELETE action will be set to:
  # <tt>url_for(controller: controller_name, action: :destroy, params: { id: asset_row.id })</tt>
  #
  class RowDeleteButtonComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>asset_row</tt>: valid ActiveRecord Model instance to which this button component will be linked to
    # - <tt>controller_name</tt>: Rails controller name for the <tt>:update</tt> action
    # - <tt>label_method</tt>: display method invoked on the row while asking confirmation (default: 'id')
    def initialize(asset_row:, controller_name:, label_method: 'id')
      super
      @asset_row = asset_row
      @controller_name = controller_name
      @label_method = label_method
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present?
    end
  end
end
