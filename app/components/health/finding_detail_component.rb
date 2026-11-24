# frozen_string_literal: true

module Health
  #
  # = Health::FindingDetailComponent
  #
  # Detail of one data health finding: what to do (how-to text, copyable rake command with the ids filled in, the
  # procedure document), the actions (Health::FindingActionsComponent) and the triage form, the entity links, the
  # evidence (payload) and the history (first/last seen, status change, note, stale data mark).
  #
  class FindingDetailComponent < ViewComponent::Base
    # Payload keys not shown as evidence (they drive the title, the rake command and the buttons).
    HIDDEN_KEYS = %w[title_args title_key rake cancel].freeze

    # == Params:
    # - finding: Ops::HealthFinding; board_season_id: Season board season ID (board row link);
    # - stale: true when the finding was last seen on an older db_epoch; null_swimmers_first: show the
    #   "fix the NULL swimmers first" warning (results.duplicates).
    def initialize(finding:, board_season_id: nil, stale: false, null_swimmers_first: false)
      super()
      @finding = finding
      @board_season_id = board_season_id
      @stale = stale
      @null_swimmers_first = null_swimmers_first
    end

    protected

    attr_reader :finding, :board_season_id, :stale, :null_swimmers_first

    def check = finding.check
    def rake_command = finding.rake_command
    def doc = check&.doc
    def entity_links = Health::FindingLinks.new(finding).entity_links

    def payload = finding.payload.is_a?(Hash) ? finding.payload : {}

    # [key, value] pairs of scalar evidence, then [key, value] pairs of nested evidence (shown as JSON).
    def scalar_evidence
      payload.except(*HIDDEN_KEYS).reject { |_key, value| value.is_a?(Hash) || value.is_a?(Array) }
    end

    def nested_evidence
      payload.except(*HIDDEN_KEYS).select { |_key, value| value.is_a?(Hash) || value.is_a?(Array) }
    end

    def evidence_label(key) = t("health.evidence.#{key}", default: key.to_s.humanize)

    def evidence_value(value)
      case value
      when true then t('health.evidence.yes')
      when false then t('health.evidence.no')
      when nil then '-'
      else value.to_s
      end
    end

    def json(value) = JSON.pretty_generate(value)

    def time(value) = value ? l(value.localtime, format: :short) : '-'

    def status_changed_by
      return t('health.finding.by_system') if finding.status_changed_by.blank?

      GogglesDb::User.find_by(id: finding.status_changed_by)&.name || "##{finding.status_changed_by}"
    end

    def bulk_form_id = "health-finding-#{finding.id}-triage"

    # E.g. 'meeting 19412', 'swimmers 7,9'.
    def subject_label
      kind = t("health.subjects.#{finding.subject_type}", default: finding.subject_type.to_s)
      "#{kind} #{finding.subject_ids.presence || finding.subject_id}"
    end
  end
end
