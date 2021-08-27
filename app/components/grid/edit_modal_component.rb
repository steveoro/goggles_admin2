# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::EditModalComponent
  #
  # Renders an hidden empty modal form, linked to a specific controller name.
  #
  # The title and the attributes displayed in the form can be easily set by
  # binding the show buttons for the form to a 'grid-edit' Stimulus JS controller instance.
  #
  # The resulting action for the form POST has the following "placeholder":
  # <tt>url_for(only_path: true, controller: @controller_name, action: :update, id: 0)</tt>
  #
  # (@see app/javascript/controllers/grid_edit_controller.js)
  #
  class EditModalComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>controller_name</tt>: Rails controller name linked to this modal form
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
