# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.40
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::CsvExportButtonComponent
  #
  # Renders a "CSV export" button linked to a specific Rails controller name.
  # The name of the grid is inferred from the controller name.
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
    # datagrid, using the CSV format, actioned by @controller_name and
    # filtered out using the data grid name (as per convention).
    def url_to_params
      {
        only_path: true,
        controller: @controller_name,
        action: :index,
        format: 'csv',
        params: { grid_name => @request_params&.fetch(grid_name, @request_params) }
      }
    end

    protected

    # Returns the DataGrid name inferred by convention, using the controller name
    def grid_name
      grid_name = @controller_name.start_with?('api_') ? @controller_name.gsub('api_', '') : @controller_name
      "#{grid_name}_grid"
    end
  end
end
