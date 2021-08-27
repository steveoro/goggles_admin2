# frozen_string_literal: true

#
# = Grid components module
#
#   - version:  7.0.3.25
#   - author:   Steve A.
#
module Grid
  #
  # = Grid::SelectionToggleButtonComponent
  #
  # Renders a button the inverts the selection on the current
  # page of the datagrid, assuming there is one.
  #
  # All checkboxes having the <tt>grid-selector</tt> CSS style
  # will be clicked.
  #
  class SelectionToggleButtonComponent < ViewComponent::Base; end
end
