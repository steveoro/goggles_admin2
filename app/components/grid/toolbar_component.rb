# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.27
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
    # == Options
    # - <tt>:asset_row</tt>:
    #  an empty ActiveRecord Model instance used to gather attributes for the create form
    #  (*required*)
    #
    # - <tt>:controller_name</tt>:
    #   Rails controller name for the <tt>:create</tt>, <tt>:destroy</tt> & <tt>:index</tt> action (*required*)
    #   (The /index action must support also the CSV output format for the action button to work.)
    #
    # - <tt>:request_params</tt>:
    #   Request <tt>:params</tt> used for Datagrid filtering
    #
    # - <tt>:create</tt>:
    #   <tt>true</tt> to show the create new button (default: true)
    #
    # - <tt>:destroy</tt>:
    #   <tt>true</tt> to show the destroy selection button (default: true)
    #
    # - <tt>:csv</tt>:
    #   <tt>true</tt> to show the CSV export button (default: true)
    def initialize(options = {})
      super
      @asset_row = options[:asset_row]
      @controller_name = options[:controller_name]
      @request_params = options[:request_params]
      @create = options[:create].nil? ? true : options[:create]
      @destroy = options[:destroy].nil? ? true : options[:destroy]
      @csv = options[:csv].nil? ? true : options[:csv]
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present?
    end
  end
end
