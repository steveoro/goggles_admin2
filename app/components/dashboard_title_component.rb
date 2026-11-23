# frozen_string_literal: true

#
# = DashboardTitleComponent
#
# Thin wrapper kept for the existing call sites until the phase 04 sweeps replace them:
# renders a Shell::PageHeaderComponent with the title and the row counter.
# (Deleted once no view uses it any more.)
#
class DashboardTitleComponent < ViewComponent::Base
  # Creates a new ViewComponent.
  #
  # == Params:
  # - title: text title
  # - row_count: value of the row counter to display
  def initialize(title:, row_count:)
    super()
    @title = title
    @row_count = row_count
  end

  def call
    render(Shell::PageHeaderComponent.new(title: @title, count: @row_count))
  end
end
