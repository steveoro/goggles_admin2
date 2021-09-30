# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.33
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
    #
    # - <tt>asset_row</tt>:
    #  valid ActiveRecord Model instance to which this component will be linked to (*required*)
    #
    # - <tt>jwt</tt>: required session JWT for API auth. (can be left to nil when using static values)
    def initialize(controller_name:, asset_row:, api_url: nil, jwt: nil)
      super
      @controller_name = controller_name
      @asset_row = asset_row
      @jwt = jwt
    end

    # Skips rendering unless the required parameters are set
    def render?
      @controller_name.present? && @asset_row.present?
    end

    # Returns the base API URL for all endpoints
    def base_api_url
      "#{GogglesDb::AppParameter.config.settings(:framework_urls).api}/api/v3"
    end
  end
end
