# frozen_string_literal: true

module Drift
  #
  # = Drift::IndicatorComponent
  #
  # The DB sync verdict as a pill (green / amber / red / unknown) with its reasons as tooltip, linking to /db_sync.
  # Reads only the given (or the last stored) Ops::DbFingerprint: no API call, renders in an API-offline session.
  #
  # == Params:
  # - fingerprint: the Ops::DbFingerprint to show; :latest (default) loads the last one of +api_url+;
  # - api_url: API base URL for :latest (default: the configured one);
  # - details: true to list the reasons below the pill (push confirmation, /remote_writes);
  # - link: false to render the pill without the link (the /db_sync page itself).
  #
  class IndicatorComponent < ViewComponent::Base
    VERDICT_CSS = { 'green' => 'text-bg-success', 'amber' => 'text-bg-warning', 'red' => 'text-bg-danger',
                    'unknown' => 'text-bg-secondary' }.freeze
    VERDICT_ICON = { 'green' => 'fa-circle-check', 'amber' => 'fa-triangle-exclamation', 'red' => 'fa-circle-xmark',
                     'unknown' => 'fa-circle-question' }.freeze
    MAX_REASONS = 5

    def initialize(fingerprint: :latest, api_url: nil, details: false, link: true, now: Time.current)
      super()
      @fingerprint = fingerprint
      @api_url = api_url
      @details = details
      @link = link
      @now = now
    end

    protected

    attr_reader :now

    def details? = @details
    def link? = @link

    def fingerprint
      return @fingerprint unless @fingerprint == :latest

      url = (@api_url.presence || Shell::APITarget.configured_url).to_s
      @fingerprint = Ops.safely { Ops::DbFingerprint.latest(url) if Ops.available? }
    end

    def verdict
      fingerprint ? fingerprint.effective_verdict(now:) : 'unknown'
    end

    def css = "badge rounded-pill #{VERDICT_CSS.fetch(verdict)}"
    def icon = VERDICT_ICON.fetch(verdict)

    def label
      t('db_sync.indicator.label', verdict: t("db_sync.verdicts.#{verdict}"))
    end

    def reasons
      return [t('db_sync.pill.never')] unless fingerprint

      fingerprint.reason_list(now:).first(MAX_REASONS).map { |reason| Drift::ReasonText.call(reason) }
    end

    def checked_text
      return t('db_sync.pill.never') unless fingerprint

      t('db_sync.indicator.checked', time: l(fingerprint.taken_at.localtime, format: :short),
                                     ago: helpers.time_ago_in_words(fingerprint.taken_at), mode: t("db_sync.modes.#{fingerprint.mode}"))
    end

    def tooltip
      [label, *reasons.first(3), checked_text].join(' · ')
    end

    def pill_attributes
      { id: 'drift-indicator', class: css, title: tooltip,
        data: { drift_verdict: verdict, db_fingerprint_id: fingerprint&.id } }
    end
  end
end
