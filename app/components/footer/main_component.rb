# frozen_string_literal: true

require 'version'

#
# = Footer components module
#
#   - version:  7.3.25
#   - author:   Steve A.
#
module Footer
  #
  # = Footer::MainComponent
  #
  # Renders the main footer, typically shown on the index of the landing page.
  # Includes the current version number.
  #
  # Superseded by the top bar user menu (Shell::UserMenuComponent): no view renders it any more;
  # deleted in phase 15. The locale helpers now live in ShellHelper.
  #
  class MainComponent < ViewComponent::Base
    delegate :other_locale_code, :unicode_locale_flag, to: :helpers
  end
end
