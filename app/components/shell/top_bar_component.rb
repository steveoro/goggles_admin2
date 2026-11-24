# frozen_string_literal: true

module Shell
  #
  # = Shell::TopBarComponent
  #
  # Application top bar: sidebar toggles (offcanvas below lg, collapse cookie above), brand, API target
  # badge, the lazy status frame (<tt>turbo-frame#shell-status</tt>, see Shell::StatusController),
  # the light/dark toggle and the user menu.
  #
  # Renders only local data (session, local DB settings, ops snapshots): no API call.
  #
  # == Slots:
  # - search: optional; the layout puts the command palette trigger there (phase 15, Shell::PaletteTriggerComponent).
  #
  class TopBarComponent < ViewComponent::Base
    renders_one :search

    # == Params:
    # - api_target: a Shell::APITarget;
    # - offline: true for an API-offline session;
    # - user: the current user.
    def initialize(api_target:, user:, offline: false)
      super()
      @api_target = api_target
      @offline = offline
      @user = user
    end

    protected

    BUTTON_CSS = 'btn btn-link link-body-emphasis px-2'

    # Below lg: opens the offcanvas sidebar.
    def offcanvas_toggle_attributes
      {
        type: 'button', id: 'sidebar-offcanvas-toggle', class: "#{BUTTON_CSS} d-lg-none",
        'aria-label' => t('shell.sidebar.open'), 'aria-controls' => 'app-sidebar',
        data: { bs_toggle: 'offcanvas', bs_target: '#app-sidebar' }
      }
    end

    # lg and up: collapses/expands the sidebar (shell_controller.js, cookie 'sidebar').
    def collapse_toggle_attributes
      {
        type: 'button', id: 'sidebar-toggle', class: "#{BUTTON_CSS} d-none d-lg-inline-block",
        'aria-label' => t('shell.sidebar.toggle'), 'aria-controls' => 'app-sidebar',
        'aria-expanded' => (!sidebar_collapsed?).to_s, data: { action: 'shell#toggleSidebar' }
      }
    end

    # Light/dark toggle (theme_controller.js, cookie 'theme').
    def theme_toggle_attributes
      {
        type: 'button', id: 'theme-toggle', class: BUTTON_CSS, title: t('theme.toggle'),
        'aria-label' => t('theme.toggle'), 'aria-pressed' => dark_theme?.to_s, data: { action: 'theme#toggle' }
      }
    end

    def dark_theme?
      helpers.current_theme == 'dark'
    end

    def sidebar_collapsed?
      helpers.sidebar_collapsed?
    end
  end
end
