# frozen_string_literal: true

module Outbox
  #
  # = Outbox::PushConfirmComponent
  #
  # The push confirmation (OutboxController#push_new): the ordered list of the scripts, their total size, the
  # target URL and environment (reported by the API; otherwise a port guess labelled "unverified"), the fresh ping
  # (reachability, maintenance flag, API version), the operator's JWT validity, the DB sync verdict (Drift::Gate,
  # scope :push) with its tick when it warns, the ordering warning and the typed environment label (unverified or
  # non-production targets only). The form posts to OutboxController#push.
  #
  # == Params:
  # - plan: the Outbox::PushPlan; ping: the APIProxy::Result of a fresh ping (nil when nothing to push);
  # - jwt_valid: the operator's API JWT validity; jwt_expires_at: its expiry (or nil);
  # - gate: the Drift::Gate result for the push (nil when nothing to push).
  #
  class PushConfirmComponent < ViewComponent::Base
    MAINTENANCE_REGEXP = /maint|manutenzione/i

    def initialize(plan:, ping:, jwt_valid:, jwt_expires_at: nil, gate: nil)
      super()
      @plan = plan
      @ping = ping
      @jwt_valid = jwt_valid
      @jwt_expires_at = jwt_expires_at
      @gate = gate
    end

    protected

    attr_reader :plan, :ping, :gate

    # True when the DB sync gate warns: the form carries the tick (drift_ack), required by the server.
    def drift_tick? = gate.present? && gate.warn?

    def jwt_valid? = @jwt_valid
    def reachable? = ping.present? && !ping.unreachable? && (200..299).cover?(ping.code.to_i)

    def ping_json
      json = ping&.json
      json.is_a?(Hash) ? json : {}
    end

    def version = ping_json['version'].presence || '?'
    def maintenance? = reachable? && MAINTENANCE_REGEXP.match?(ping_json['msg'].to_s)

    def ping_error
      ping ? ping.error_detail.to_s.truncate(200) : '-'
    end

    def total_size = helpers.number_to_human_size(plan.total_bytes)

    def jwt_text
      return t('outbox.push.jwt_invalid') unless jwt_valid?

      @jwt_expires_at ? t('outbox.push.jwt_valid', time: l(@jwt_expires_at.localtime, format: :short)) : t('outbox.push.jwt_valid', time: '?')
    end

    # The push button is enabled only when everything needed is there (the server re-checks all of it).
    def submittable?
      !plan.empty? && reachable? && jwt_valid?
    end

    def environment_label = plan.environment

    def label_field_options
      { class: 'form-control', autocomplete: 'off', required: true, placeholder: environment_label }
    end
  end
end
