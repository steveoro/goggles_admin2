# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::RowToolbarComponent
  #
  # Renders a row.
  #
  # The DELETE action will be set to:
  # <tt>url_for(controller: controller_name, action: :destroy, params: { id: asset_row.id })</tt>
  #
  class RowToolbarComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>asset_row</tt>:
    #  valid ActiveRecord Model instance to which this button component will be linked to
    #  (*required*)
    #
    # - <tt>controller_name</tt>:
    #   Rails controller name for the <tt>:update</tt> action (*required*)
    #
    # - <tt>edit</tt>:
    #   <tt>true</tt> to show the edit action button (default: true)
    #
    # - <tt>destroy</tt>:
    #   <tt>true</tt> to show the destroy action button (default: true)
    #
    # - <tt>label_method</tt>:
    #   Display method invoked on the row while asking confirmation
    #   (default: 'id')
    def initialize(asset_row:, controller_name:, edit: true, destroy: true, label_method: 'id')
      super
      @asset_row = asset_row
      @controller_name = controller_name
      @edit = edit
      @destroy = destroy
      @label_method = label_method
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present?
    end
  end
end
