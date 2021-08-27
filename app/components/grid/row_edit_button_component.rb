# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::RowEditButtonComponent
  #
  # Renders a single "row edit" button linked to a specific ActiveRecord Model row.
  #
  # The action for the form POST will be set to:
  # <tt>url_for(only_path: true, controller: controller_name, action: :update, id: asset_row.id)</tt>
  #
  class RowEditButtonComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>asset_row</tt>: valid ActiveRecord Model instance to which this button component will be linked to
    # - <tt>controller_name</tt>: Rails controller name for the <tt>:update</tt> action
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
