# frozen_string_literal: true

module DataFix
  #
  # = DataFix::IssueNavComponent
  #
  # Toolbar of the next/previous issue navigation of a Data-Fix review page (#data-fix-issue-nav, wired to
  # issue_nav_controller.js): Previous / Next buttons (keys `k` / `j`), the "issue x / total" position and, in the
  # optional +toggle+ slot, the page's "needs you only" switch.
  #
  # == Usage
  #   = render(DataFix::IssueNavComponent.new(nav: @issue_nav)) do |component|
  #     - component.with_toggle { link_to(...) }
  #
  class IssueNavComponent < ViewComponent::Base
    renders_one :toggle

    CURRENT_TOKEN = '__CURRENT__'
    TOTAL_TOKEN = '__TOTAL__'

    # == Params
    # - nav: DataFix::IssueNav (total, offset, prev_url, next_url) or nil (no issue);
    # - selector: CSS selector of the card markers (default '[data-issue]').
    def initialize(nav:, selector: '[data-issue]')
      super()
      @nav = nav || DataFix::IssueNav.single_page(0)
      @selector = selector
    end

    attr_reader :nav

    def controller_data
      {
        controller: 'issue-nav', action: 'keydown@window->issue-nav#keydown',
        issue_nav_selector_value: @selector, issue_nav_total_value: nav.total, issue_nav_offset_value: nav.offset,
        issue_nav_prev_url_value: nav.prev_url.to_s, issue_nav_next_url_value: nav.next_url.to_s,
        # (templates filled in by the controller: CURRENT_TOKEN / TOTAL_TOKEN)
        issue_nav_position_label_value: t('data_fix.issue_nav.position', current: CURRENT_TOKEN, total: TOTAL_TOKEN),
        issue_nav_total_label_value: t('data_fix.issue_nav.total', total: TOTAL_TOKEN),
        issue_nav_none_label_value: t('data_fix.issue_nav.none')
      }
    end

    def summary_text
      nav.any? ? t('data_fix.issue_nav.total', total: nav.total) : t('data_fix.issue_nav.none')
    end
  end
end
