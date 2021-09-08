# frozen_string_literal: true

#
# = DashboardTitleComponent
#
# Simple centered title with row count on its side
#
class DashboardTitleComponent < ViewComponent::Base
  # Creates a new ViewComponent.
  #
  # == Params:
  # - title: text title
  # - row_count: value of the row counter to display
  def initialize(title:, row_count:)
    super
    @title = title
    @row_count = row_count
  end
end
