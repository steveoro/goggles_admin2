# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.40
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
    #
    # - <tt>controller_name</tt>: Rails controller name for the <tt>:create</tt> action
    #
    # - <tt>base_modal_id</tt>: base DOM ID used inside the associated modal dialog; defaults to "grid-edit".
    #
    # - <tt>btn_label</tt>: additional label for the button; default: nil
    #
    def initialize(asset_row:, controller_name:, base_modal_id: 'grid-edit', btn_label: nil)
      super
      @asset_row = asset_row
      @controller_name = controller_name
      @base_modal_id = base_modal_id
      @btn_label = btn_label
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present? && @base_modal_id.present?
    end
  end
end
