# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::CreateNewButtonComponent
  #
  # Renders a "create new" button linked to a specific Rails controller name.
  #
  # The action for the form POST will be set to:
  # <tt>url_for(only_path: true, controller: controller_name, action: :create)</tt>
  #
  class CreateNewButtonComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>asset_row</tt>: empty ActiveRecord Model instance used to collect attributes for the create form
    # - <tt>controller_name</tt>: Rails controller name for the <tt>:create</tt> action
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
