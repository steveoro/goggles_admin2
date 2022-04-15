# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7-0.3.52
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
    # == Options
    # - <tt>asset_row</tt>:
    #  valid ActiveRecord Model instance to which this button component will be linked to
    #  (*required*)
    #
    # - <tt>controller_name</tt>:
    #   Rails controller name for the <tt>:update</tt> action (*required*)
    #
    # - <tt>edit</tt>:
    #   <tt>true</tt> to show the edit action button (default: true)
    #   when set to a string, the value will be used as custom DOM ID for the edit modal dialog
    #
    # - <tt>clone</tt>:
    #   <tt>true</tt> to enable & show the clone action button (default: false)
    #
    # - <tt>destroy</tt>:
    #   <tt>true</tt> to enable & show the destroy action button (default: true)
    #
    # - <tt>expand</tt>:
    #   <tt>true</tt> to show the "expand row" action button (default: false)
    #   This is usually a link to a "GET <ENTITY_NAME/<ID>"-type request that will open in a new custom page.
    #
    # - <tt>label_method</tt>:
    #   Display method invoked on the row while asking confirmation
    #   (default: 'id')
    def initialize(options = { edit: true, clone: false, destroy: true, expand: false, label_method: 'id' })
      super
      @asset_row = options[:asset_row]
      @controller_name = options[:controller_name]
      @base_modal_id = options[:edit] if options[:edit].is_a?(String)
      @edit = options[:edit].present? || options[:edit].nil?
      @destroy = set_boolean_option_with_default(options, :destroy)
      @clone = set_boolean_option_with_default(options, :clone, default_value: false)
      @expand = set_boolean_option_with_default(options, :expand, default_value: false)
      @label_method = options[:label_method].presence || 'id'
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
