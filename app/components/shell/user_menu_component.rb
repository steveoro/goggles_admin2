# frozen_string_literal: true

require 'version'

module Shell
  #
  # = Shell::UserMenuComponent
  #
  # Top bar user dropdown: name and avatar, locale switch (<tt>#href-locale-switch</tt>), app version
  # and log out. (Supersedes the locale switch and version of Footer::MainComponent.)
  #
  class UserMenuComponent < ViewComponent::Base
    # == Params:
    # - user: the current user (GogglesDb::User).
    def initialize(user:)
      super()
      @user = user
    end

    def render?
      @user.present?
    end

    protected

    attr_reader :user

    def avatar_url
      user.respond_to?(:avatar_url) ? user.avatar_url.presence : nil
    end

    def other_locale
      helpers.other_locale_code
    end

    def toggle_attributes
      { type: 'button', 'aria-expanded' => 'false', 'aria-label' => t('shell.user_menu.label'), data: { bs_toggle: 'dropdown' } }
    end
  end
end
