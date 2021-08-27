# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::ToolbarComponent
  #
  # Renders a row.
  #
  # The DELETE action will be set to:
  # <tt>url_for(controller: controller_name, action: :destroy, params: { id: asset_row.id })</tt>
  #
  class ToolbarComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>asset_row</tt>:
    #  an empty ActiveRecord Model instance used to gather attributes for the create form
    #  (*required*)
    #
    # - <tt>controller_name</tt>:
    #   Rails controller name for the <tt>:create</tt>, <tt>:destroy</tt> & <tt>:index</tt> action (*required*)
    #   (The /index action must support also the CSV output format for the action button to work.)
    #
    # - <tt>create</tt>:
    #   <tt>true</tt> to show the create new button (default: true)
    #
    # - <tt>destroy</tt>:
    #   <tt>true</tt> to show the destroy selection button (default: true)
    #
    # - <tt>csv</tt>:
    #   <tt>true</tt> to show the CSV export button (default: true)
    def initialize(asset_row:, controller_name:, create: true, destroy: true, csv: true)
      super
      @asset_row = asset_row
      @controller_name = controller_name
      @create = create
      @destroy = destroy
      @csv = csv
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present?
    end
  end
end
