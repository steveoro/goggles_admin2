# frozen_string_literal: true

# = ApplicationHelper
#
# Common parent helper
module ApplicationHelper
  # Supported Bootstrap color modes (the first one is the default).
  THEMES = %w[light dark].freeze

  # Returns the Bootstrap color mode for the layout's <tt>data-bs-theme</tt> attribute:
  # the value of the 'theme' cookie when it's a supported one, 'light' otherwise.
  def current_theme
    theme = cookies[:theme].to_s
    THEMES.include?(theme) ? theme : THEMES.first
  end
end
