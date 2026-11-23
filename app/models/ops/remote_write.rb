# frozen_string_literal: true

module Ops
  #
  # = Ops::RemoteWrite
  #
  # One API call that may have changed the remote data (ops DB, table 'remote_writes'): every
  # APIProxy.call whose method is not GET, except the sign-in ('session') and the SQL batch push
  # ('import_queue/batch_sql', tracked by the push log). Written only by APIProxy (see .record!), after the
  # call; listed by RemoteWritesController (/remote_writes) and counted by the drift v0 check.
  #
  # Stores the payload KEYS only: never the values, never the headers (no JWT, no personal data).
  #
  # == Attributes
  # - http_method ('put', 'post', 'delete', ...), endpoint (e.g. 'user/12'), base_url (API base URL);
  # - status_code (503 for an unreachable server), unreachable, error_detail (failed calls only, 300 chars max);
  # - payload_keys (JSON Array of Strings), user_id (Current.user_id), source (Current.source:
  #   'controller#action' or a job class name), created_at.
  #
  class RemoteWrite < ApplicationRecord
    self.table_name = 'remote_writes'

    # Setting key of the last "Acknowledge" on /remote_writes (ISO 8601 String).
    ACKNOWLEDGED_AT_KEY = 'drift.acknowledged_at'
    ERROR_DETAIL_LIMIT = 300
    # Outcome filter values (see #status and .with_status).
    STATUSES = %w[success failed unreachable].freeze

    validates :http_method, :endpoint, :base_url, presence: true

    scope :recent, -> { order(created_at: :desc, id: :desc) }
    scope :for_base_url, ->(base_url) { where(base_url: base_url.to_s.strip.delete_suffix('/')) }
    # Rows written after +time+ (all of them when +time+ is nil).
    scope :since, ->(time) { time ? where(arel_table[:created_at].gt(time)) : all }
    scope :succeeded, -> { where(unreachable: false, status_code: 200..299) }
    scope :failed, -> { where(unreachable: false).where.not(status_code: 200..299) }
    scope :unreachable_calls, -> { where(unreachable: true) }
    # Rows whose endpoint contains +text+ (case-insensitive in SQLite for ASCII).
    scope :endpoint_like, ->(text) { where('endpoint LIKE ?', "%#{sanitize_sql_like(text.to_s.strip)}%") }
    # Successful writes to +base_url+ since the last acknowledgement: the remote-only edits seen by drift v0.
    scope :unacknowledged, ->(base_url) { for_base_url(base_url).succeeded.since(acknowledged_at) }

    class << self
      # Creates the row for an APIProxy call. Raises on failure: APIProxy wraps it in Ops.safely.
      #
      # == Params:
      # - http_method, endpoint, base_url: as sent; payload_keys: Array of the payload keys (no values);
      # - result: the APIProxy::Result (code, unreachable?, error_detail).
      def record!(http_method:, endpoint:, base_url:, result:, payload_keys: [])
        code = result.code.to_i
        unreachable = result.respond_to?(:unreachable?) && result.unreachable?
        failed = unreachable || !(200..299).cover?(code)
        create!(
          http_method: http_method.to_s.downcase, endpoint: endpoint.to_s, base_url: base_url.to_s.delete_suffix('/'),
          status_code: code, unreachable:, payload_keys: Array(payload_keys).map(&:to_s),
          error_detail: failed ? result.error_detail.to_s.truncate(ERROR_DETAIL_LIMIT) : nil,
          user_id: Current.user_id, source: Current.source.to_s.truncate(255).presence
        )
      end

      # Filters by outcome: one of STATUSES (anything else: no filter).
      def with_status(status)
        case status.to_s
        when 'success' then succeeded
        when 'failed' then failed
        when 'unreachable' then unreachable_calls
        else all
        end
      end

      # Time of the last acknowledgement (Ops::Setting ACKNOWLEDGED_AT_KEY), or nil.
      def acknowledged_at
        value = Ops::Setting.fetch(ACKNOWLEDGED_AT_KEY)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end

      # Marks every write up to +time+ as reviewed ("Acknowledge" on /remote_writes). Returns the time.
      def acknowledge!(time = Time.current)
        Ops::Setting.store!(ACKNOWLEDGED_AT_KEY, time.utc.iso8601(6))
        time
      end
    end

    # 'success', 'failed' or 'unreachable'.
    def status
      return 'unreachable' if unreachable?

      (200..299).cover?(status_code.to_i) ? 'success' : 'failed'
    end

    def success?
      status == 'success'
    end
  end
end
