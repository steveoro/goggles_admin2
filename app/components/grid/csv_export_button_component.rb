# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.27
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::CsvExportButtonComponent
  #
  # Renders a "CSV export" button linked to a specific Rails controller name.
  #
  # To implement the action, simply add <tt>.csv</tt> as a supported format for rendering.
  #
  class CsvExportButtonComponent < ViewComponent::Base
    # Creates a new ViewComponent
    #
    # == Params
    # - <tt>controller_name</tt>: Rails controller name bound to this action
    def initialize(controller_name:, request_params:)
      super
      @controller_name = controller_name
      @request_params = request_params
    end

    # Skips rendering unless the required parameters are set
    def render?
      @controller_name.present?
    end

    # Returns the correct url_to params Hash for the filtered /index action of the
    # datagrid, using the CSV format, actioned by @controller_name.
    def url_to_params
      {
        only_path: true,
        controller: @controller_name,
        action: :index,
        format: 'csv'
      }.merge(
        "#{@controller_name}_grid" => @request_params&.fetch("#{@controller_name}_grid", nil)
      )
    end
  end
end
