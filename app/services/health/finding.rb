# frozen_string_literal: true

module Health
  #
  # = Health::Finding
  #
  # One issue found by a check run (value object emitted by Health::Checks::*, persisted by Health::FindingSync
  # as an Ops::HealthFinding).
  #
  # - check_key: Health::Registry key; severity: 'error' | 'warning' | 'info';
  # - subject_type, subject_id (main entity), subject_ids (Array of Integers, stored sorted);
  # - identity: entity ids only (e.g. 'meeting:19412', 'swimmer:123|badges:45,67'), hashed into the fingerprint;
  # - title_args: interpolation values of 'health.checks.<key>.<title_key>' (stored in the payload as 'title_args');
  # - title_key: the title text key under 'health.checks.<key>' (default 'finding'; stored as 'title_key');
  # - payload: JSON-able evidence Hash (String keys), e.g. counts, names, 'rake' args, 'cancel' target.
  #
  Finding = Data.define(:check_key, :severity, :subject_type, :subject_id, :subject_ids, :identity, :title_args, :title_key,
                        :payload) do
    # rubocop:disable-next Metrics/ParameterLists
    def initialize(check_key:, severity:, identity:, subject_type: nil, subject_id: nil, subject_ids: [], title_args: {},
                   title_key: 'finding', payload: {})
      super(check_key: check_key.to_s, severity: severity.to_s, subject_type: subject_type&.to_s, subject_id:,
            subject_ids: Array(subject_ids).map(&:to_i).sort, identity: identity.to_s,
            title_args: title_args.to_h.transform_keys(&:to_s), title_key: title_key.to_s, payload: payload.to_h.deep_stringify_keys)
    end

    def check = Health::Registry.fetch(check_key)
    def group_key = check.group

    # Payload stored on the Ops::HealthFinding (the title args included).
    def stored_payload
      payload.merge('title_args' => title_args, 'title_key' => title_key).as_json
    end

    # Title in the given locale (default: en, as stored in the 'title' column for searching).
    def title(locale: :en)
      I18n.with_locale(locale) do
        I18n.t("health.checks.#{check_key}.#{title_key}", **title_args.symbolize_keys, default: check_key)
      end
    end
  end
end
