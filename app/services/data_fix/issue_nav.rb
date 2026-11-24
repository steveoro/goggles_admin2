# frozen_string_literal: true

module DataFix
  #
  # = DataFix::IssueNav
  #
  # State of the next/previous issue navigation of a Data-Fix review page (DataFix::IssueNavComponent +
  # issue_nav_controller.js): how many issues the step has, how many sit on the pages before this one, and where the
  # previous / next issue outside this page is (a URL with the card anchor, or '#issue-first' / '#issue-last').
  #
  # The cards themselves carry the markers (`data-issue="<code>"`, see DataFix::IssueMarkers); the controller walks
  # them on the page and follows +prev_url+ / +next_url+ past its ends.
  #
  # == Builders
  # - IssueNav.single_page(total): phases 1 and 4 (one page);
  # - IssueNav.for_list(flags, page:, per_page:) { |page, position| url }: phases 2-3 (fixed page size; +flags+ holds
  #   one Boolean per row of the filtered collection, the card anchors are the row positions);
  # - IssueNav.for_pages(counts, page:) { |page, edge| url }: phase 5 (pages of variable size; +counts+ holds the
  #   issue count of each page, +edge+ is :first or :last).
  #
  IssueNav = Data.define(:total, :offset, :prev_url, :next_url) do
    def self.single_page(total)
      new(total: total.to_i, offset: 0, prev_url: nil, next_url: nil)
    end

    def self.for_list(flags, page:, per_page:)
      positions = Array(flags).each_index.select { |index| flags[index] }
      first_on_page = (page.to_i - 1) * per_page.to_i
      last_on_page = first_on_page + per_page.to_i - 1
      previous = positions.reverse.find { |position| position < first_on_page }
      following = positions.find { |position| position > last_on_page }
      new(total: positions.size, offset: positions.count { |position| position < first_on_page },
          prev_url: previous && yield((previous / per_page.to_i) + 1, previous),
          next_url: following && yield((following / per_page.to_i) + 1, following))
    end

    def self.for_pages(counts, page:)
      counts = Array(counts).map(&:to_i)
      index = page.to_i - 1
      previous = (0...index).to_a.reverse.find { |other| counts[other].positive? }
      following = ((index + 1)...counts.size).find { |other| counts[other].positive? }
      new(total: counts.sum, offset: counts.first([index, 0].max).sum,
          prev_url: previous && yield(previous + 1, :last),
          next_url: following && yield(following + 1, :first))
    end

    def any? = total.positive?
  end
end
