# frozen_string_literal: true

#
# = ShellHelper
#
# Helpers for the application shell (sidebar, top bar, user menu; see layouts/application).
#
module ShellHelper
  # Cookie storing the sidebar state on large screens ('collapsed' or 'expanded'), written by shell_controller.js.
  SIDEBAR_COOKIE = 'sidebar'

  # Shell::Navigation item of the current page, or nil.
  def current_nav_item
    Shell::Navigation.item_for(controller_path, action_name, params)
  end

  # Shell::APITarget for the top bar (forced unreachable in an API-offline session).
  def shell_api_target
    Shell::APITarget.current(offline_info: api_offline_session? ? api_offline_info : nil)
  end

  # True when the sidebar has been collapsed (icons only) on large screens.
  def sidebar_collapsed?
    cookies[SIDEBAR_COOKIE].to_s == 'collapsed'
  end

  # Page <title>: the title provided by the view (or by Shell::PageHeaderComponent) followed by the app name.
  def page_title
    [content_for(:title), t('shell.brand')].compact_blank.join(' · ')
  end

  # Returns the first locale available besides the current one.
  # (Not an actual "locale switch" generic enough, but we'll hardly ever have more than 2 locales.)
  def other_locale_code
    I18n.available_locales.reject { |sym| sym == I18n.locale }.first
  end

  # Link text for switching to +locale_sym+.
  def unicode_locale_flag(locale_sym)
    locale_sym == :it ? 'Versione 🇮🇹' : '🇬🇧 Version'
  end

  # Path of the current page with the +locale+ parameter (home for non-GET requests).
  def locale_switch_path(locale)
    return home_index_path(locale:) unless request.get?

    "#{request.path}?#{request.query_parameters.merge('locale' => locale.to_s).to_query}"
  end
end
