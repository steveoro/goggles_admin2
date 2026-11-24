# frozen_string_literal: true

module Shell
  #
  # = Shell::BreadcrumbsComponent
  #
  # Bootstrap breadcrumb list (<tt>nav[aria-label] ol.breadcrumb</tt>); the last crumb is the current page.
  # Renders nothing without crumbs.
  #
  class BreadcrumbsComponent < ViewComponent::Base
    # == Params:
    # - crumbs: Array of [label, path] pairs (path nil for a crumb that is not a link).
    def initialize(crumbs:)
      super()
      @crumbs = Array(crumbs)
    end

    def render?
      @crumbs.any?
    end

    protected

    def last?(index)
      index == @crumbs.size - 1
    end
  end
end
