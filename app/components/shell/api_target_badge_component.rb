# frozen_string_literal: true

module Shell
  #
  # = Shell::APITargetBadgeComponent
  #
  # Top bar badge for the API server in use (Shell::APITarget): URL, operator label, environment (as reported by
  # the API; otherwise the port-based guess, marked "unverified"), a warning when the label names another
  # environment, last known reachability and its age. Links to the Settings page.
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
                api_guess: api_target.guess, api_environment: api_target.environment,
                api_verified: api_target.verified?.to_s, api_reachability: reachability }
      }
    end

    # URL without the scheme, for a compact display.
    def short_url
      api_target.url.sub(%r{\Ahttps?://}, '')
    end

    def environment_css
      api_target.environment == 'production' ? 'app-env-badge app-env-badge--production' : 'app-env-badge app-env-badge--unknown'
    end

    # Environment name: the API's own answer, else the translated port guess.
    def environment_name
      return api_target.environment if api_target.verified?

      t("shell.api_target.guess.#{api_target.guess}")
    end

    def environment_text
      return t('shell.api_target.reported', environment: environment_name) if api_target.verified?

      "#{environment_name} (#{t('shell.api_target.unverified')})"
    end

    def mismatch_text
      t('shell.api_target.label_mismatch', label: api_target.label, environment: api_target.environment)
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
        api_target.label, environment_text, (mismatch_text if api_target.label_mismatch?), reachability_text, version,
        api_target.error
      ].compact_blank.join(' · ')
    end
  end
end
