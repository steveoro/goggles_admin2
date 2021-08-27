# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
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
