# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.40
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
    # - <tt>:select</tt>:
    #   <tt>true</tt> to show the 'invert selection' button (default: true)
    #
    # - <tt>:filter</tt>:
    #   <tt>true</tt> to show the filter popup button (default: true)
    #
    # - <tt>:create</tt>:
    #   <tt>true</tt> to show the create new button (default: true)
    #
    # - <tt>:destroy</tt>:
    #   <tt>true</tt> to show the destroy selection button (default: true)
    #
    # - <tt>:csv</tt>:
    #   <tt>true</tt> to show the CSV export button (default: true)
    def initialize(options = { select: true, filter: true, create: true, destroy: true, csv: true })
      super
      @asset_row = options[:asset_row]
      @controller_name = options[:controller_name]
      @request_params = options[:request_params]
      @select = set_boolean_option_with_default(options, :select)
      @filter = set_boolean_option_with_default(options, :filter)
      @create = set_boolean_option_with_default(options, :create)
      @destroy = set_boolean_option_with_default(options, :destroy)
      @csv = set_boolean_option_with_default(options, :csv)
    end

    # Skips rendering unless the required parameters are set
    def render?
      @asset_row.present? && @controller_name.present?
    end

    private

    # Compares the options[key] with a boolean true value if present and returns a
    # boolean result or the default value if the key wasn't found.
    def set_boolean_option_with_default(options, key, default_value: true)
      options.key?(key) ? [true, 'true'].include?(options[key]) : default_value
    end
  end
end
