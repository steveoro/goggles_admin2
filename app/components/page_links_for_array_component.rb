# frozen_string_literal: true

#
# = PageLinksForArrayComponent
#
# Renders the pagination links for a specified array of data rows.
#
class PageLinksForArrayComponent < ViewComponent::Base
  # Creates a new ViewComponent.
  #
  # == Params:
  # - <tt>data</tt>: a non-empty array of data that has to be paginated.
  #   The +data+ array can also be a single page of rows (i.e. an already paged API response),
  #   what really matters in terms of the resulting links are the overall total
  #   count the number of rows displayed per page and the current page number
  #   (see below).
  #
  # - <tt>total_count</tt>: total number of rows of the domain that has to be paginated.
  #
  # - <tt>page</tt>: current domain page number being displayed; starts from 1.
  #
  # - <tt>per_page</tt>: total number of rows displayed per page.
  #
  def initialize(data:, total_count:, page:, per_page:)
    super
    @data = data
    @total_count = total_count.to_i
    @page = page.to_i
    @per_page = per_page.to_i
  end

  # Skips rendering unless the constructor parameters are valid.
  def render?
    @data.instance_of?(Array) && @total_count.positive? &&
      @page.positive? && @per_page.positive?
  end
end
