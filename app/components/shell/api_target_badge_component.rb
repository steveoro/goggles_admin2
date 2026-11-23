# frozen_string_literal: true

module Shell
  #
  # = Shell::APITargetBadgeComponent
  #
  # Top bar badge for the API server in use (Shell::APITarget): URL, operator label, port-based guess
  # (always marked "unverified"), last known reachability and its age. Links to the Settings page.
  #
  # Only local data: no API call.
  #
  class APITargetBadgeComponent < ViewComponent::Base
    REACHABILITY_CSS = { reachable: 'text-success', unreachable: 'text-danger', unknown: 'text-body-secondary' }.freeze
    REACHABILITY_ICON = { reachable: 'fa-circle-check', unreachable: 'fa-circle-xmark', unknown: 'fa-circle-question' }.freeze

    # == Params:
    # - api_target: a Shell::APITarget.
    def initialize(api_target:)
      super()
      @api_target = api_target
    end

    protected

    attr_reader :api_target

    def link_attributes
      {
        href: settings_path,
        data: { bs_toggle: 'tooltip', bs_placement: 'bottom', bs_title: tooltip_text,
                api_guess: api_target.guess, api_reachability: reachability }
      }
    end

    # URL without the scheme, for a compact display.
    def short_url
      api_target.url.sub(%r{\Ahttps?://}, '')
    end

    def guess_css
      api_target.guess == :production ? 'app-env-badge app-env-badge--production' : 'app-env-badge app-env-badge--unknown'
    end

    def guess_text
      "#{t("shell.api_target.guess.#{api_target.guess}")} (#{t('shell.api_target.unverified')})"
    end

    def reachability
      api_target.reachability
    end

    def reachability_text
      text = t("shell.api_target.reachability.#{reachability}")
      taken_at = api_target.taken_at
      return text unless taken_at

      "#{text}, #{t('shell.api_target.checked_ago', ago: helpers.time_ago_in_words(taken_at))}"
    end

    # Full description, used as the badge tooltip.
    def tooltip_text
      version = api_target.version ? t('shell.api_target.version', version: api_target.version) : nil
      [
        t('shell.api_target.settings_link'), api_target.url.presence || t('shell.api_target.no_url'),
        api_target.label, guess_text, reachability_text, version, api_target.error
      ].compact_blank.join(' · ')
    end
  end
end
