# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::DeleteSelectionButtonComponent
  #
  # Renders a "Delete selection" button linked to a specific Rails controller name.
  #
  # The DELETE action will be set to:
  # <tt>url_for(controller: controller_name, action: :destroy, params: { ids: <comma_separanted_list_of_ids> })</tt>
  #
  class DeleteSelectionButtonComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>controller_name</tt>: Rails controller name bound to this action
    def initialize(controller_name:)
      super
      @controller_name = controller_name
    end

    # Skips rendering unless the required parameters are set
    def render?
      @controller_name.present?
    end
  end
end
