# frozen_string_literal: true

module Drift
  #
  # = Drift::ReasonText
  #
  # One translated line for a DB sync reason (a Drift::Verdict / Ops::DbFingerprint / Drift::Gate reason Hash with
  # String or Symbol keys 'code', 'table', 'local', 'remote'), from 'db_sync.reasons.<code>'.
  #
  #   Drift::ReasonText.call({ code: 'id_collision', table: 'laps', local: 100, remote: 120 })
  #   # => "laps: remote max id 120 is above the local one (100): new rows would collide"
  #
  module ReasonText
    TIME_CODES = %w[remote_updated stale].freeze

    module_function

    def call(reason)
      data = reason.to_h.transform_keys(&:to_s)
      code = data['code'].to_s
      I18n.t("db_sync.reasons.#{code}", table: data['table'].to_s, local: value(code, data['local']),
                                        remote: value(code, data['remote']), count: count_for(code, data),
                                        default: I18n.t('db_sync.reasons.other', code:))
    end

    def value(code, value)
      return '-' if value.nil? || value.to_s.empty?
      return format_time(value) if TIME_CODES.include?(code)
      return value.to_s.truncate(200) unless value.is_a?(Numeric)

      ActiveSupport::NumberHelper.number_to_delimited(value)
    end

    def count_for(code, data)
      value = code == 'remote_batch_failed' ? data['remote'] : data['local']
      value.is_a?(Numeric) ? value : value.to_s.to_i
    end

    def format_time(value)
      time = value.is_a?(String) ? Time.zone.parse(value) : value
      time ? I18n.l(time.localtime, format: :short) : value.to_s
    rescue ArgumentError
      value.to_s
    end
  end
end
