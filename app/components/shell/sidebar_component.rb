# frozen_string_literal: true

module Shell
  #
  # = Shell::SidebarComponent
  #
  # Application sidebar: the Shell::Navigation groups and items, with the current page highlighted
  # (<tt>.nav-link.active</tt> + <tt>aria-current="page"</tt>).
  #
  # Offcanvas below the lg breakpoint (opened by the top bar menu button); above it, a fixed column that
  # can be collapsed to icons only (cookie 'sidebar', see ShellHelper#sidebar_collapsed? and shell_controller.js).
  #
  # In an API-offline session the items not marked +offline_ok+ are rendered as disabled links with a tooltip.
  #
  class SidebarComponent < ViewComponent::Base
    # == Params:
    # - current: the Shell::Navigation::Item of the current page, or nil;
    # - offline: true for an API-offline session.
    def initialize(current:, offline: false)
      super()
      @current = current
      @offline = offline
    end

    protected

    def groups
      Shell::Navigation.groups(offline: @offline)
    end

    # The item highlighted as active: the current one, or its closest sidebar ancestor
    # (e.g. Result files for the Data-Fix pages).
    def active_key
      return @active_key if defined?(@active_key)

      item = @current
      item = Shell::Navigation.find(item.parent) while item && !item.sidebar? && item.parent
      @active_key = item&.key
    end

    def active?(item)
      item.key == active_key
    end

    def item_path(item)
      Shell::Navigation.path_for(item)
    end

    def link_classes(item, disabled)
      ['nav-link', 'app-nav-link', 'd-flex', 'align-items-center', 'gap-2',
       (active?(item) ? 'active' : nil), (disabled ? 'disabled' : nil)].compact.join(' ')
    end
  end
end
