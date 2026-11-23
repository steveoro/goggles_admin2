# frozen_string_literal: true

module Drift
  #
  # = Drift::Fingerprint
  #
  # The two sides of a DB sync check, as plain JSON-able Hashes (String keys), never written anywhere by this class:
  #
  # - <tt>.local(tables:, light:)</tt>: read-only aggregates on the local MySQL DB, one query per whitelisted table
  #   (Drift::Tables): <tt>COUNT(*)</tt>, <tt>MAX(id)</tt>, <tt>MAX(updated_at)</tt>; light mode only
  #   <tt>MAX(id)</tt> (primary key lookup). Plus the local schema version (max of schema_migrations).
  # - <tt>.remote(tables:, light:, base_url:, jwt:)</tt>: <tt>GET tools/db_fingerprint</tt> on the API (admin JWT;
  #   the server caches each parameter set for 60 s), short timeouts. Returns a Remote (status + payload).
  #
  # == Fingerprint Hash (both sides; the remote one comes from the API as is)
  #   { 'generated_at' => '<ISO 8601>', 'schema_version' => '20261027120100', 'light' => false,
  #     'tables' => { 'laps' => { 'count' => 4120331, 'max_id' => 4188002, 'max_updated_at' => '<ISO 8601>' }, ... },
  #     'errors' => { '<table>' => '<error>' } }                     # (local only, tables that could not be read)
  # The remote payload also carries 'environment', 'db_version' and
  # 'import_queue' => { 'next_id', 'batch_queued', 'batch_failed' }.
  #
  module Fingerprint
    ENDPOINT = 'tools/db_fingerprint'
    TIMEOUTS = { full: { open_timeout: 5, timeout: 30 }, light: { open_timeout: 5, timeout: 10 } }.freeze
    REMOTE_STATUSES = %w[ok no_capability no_credentials unreachable unauthorized rejected error].freeze

    # Outcome of the remote call. status: one of REMOTE_STATUSES; payload: the fingerprint Hash ({} unless 'ok').
    Remote = Data.define(:status, :payload, :error) do
      def ok? = status == 'ok'
      def tables = payload.is_a?(Hash) && payload['tables'].is_a?(Hash) ? payload['tables'] : {}
    end

    module_function

    # Local fingerprint Hash (see above). Never raises: a table that can't be read goes to 'errors'.
    def local(tables: nil, light: false, connection: ActiveRecord::Base.connection)
      result = { 'generated_at' => Time.current.utc.iso8601, 'schema_version' => local_schema_version(connection),
                 'light' => light, 'tables' => {}, 'errors' => {} }
      Drift::Tables.normalize(tables).each do |table|
        result['tables'][table] = light ? light_row(connection, table) : full_row(connection, table)
      rescue StandardError => e
        result['errors'][table] = "#{e.class}: #{e.message}".truncate(300)
      end
      result
    end

    # Remote fingerprint (a Remote). Makes one GET with +jwt+ (nil: no call, status 'no_credentials').
    def remote(base_url:, jwt:, tables: nil, light: false)
      return Remote.new(status: 'no_credentials', payload: {}, error: nil) if jwt.blank?

      params = {}
      list = Drift::Tables.normalize(tables)
      params[:tables] = list.join(',') if list.size < Drift::Tables.all.size
      params[:light] = 1 if light
      result = APIProxy.call(method: :get, url: ENDPOINT, jwt:, params:, base_url:, **TIMEOUTS[light ? :light : :full])
      remote_for(result)
    rescue StandardError => e
      Rails.logger.warn("[Drift::Fingerprint] #{e.class}: #{e.message}")
      Remote.new(status: 'error', payload: {}, error: "#{e.class}: #{e.message}".truncate(300))
    end

    # Max schema_migrations version of the local DB (String), or nil.
    def local_schema_version(connection = ActiveRecord::Base.connection)
      connection.pool.migration_context.current_version.to_s.presence
    rescue StandardError
      nil
    end

    def full_row(connection, table)
      quoted = connection.quote_table_name(table)
      count, max_id, max_updated_at = connection.select_rows("SELECT COUNT(*), MAX(id), MAX(updated_at) FROM #{quoted}").first
      { 'count' => count.to_i, 'max_id' => max_id&.to_i, 'max_updated_at' => iso_time(max_updated_at) }
    end

    def light_row(connection, table)
      max_id = connection.select_value("SELECT MAX(id) FROM #{connection.quote_table_name(table)}")
      { 'max_id' => max_id&.to_i }
    end

    def iso_time(value)
      return if value.blank?

      time = value.is_a?(String) ? Time.zone.parse(value) : value
      time&.utc&.iso8601
    end

    def remote_for(result)
      code = result.code.to_i
      detail = result.error_detail.to_s.truncate(300)
      return Remote.new(status: 'unreachable', payload: {}, error: detail) if result.unreachable?
      return Remote.new(status: 'unauthorized', payload: {}, error: detail) if code == 401
      # (an API without the endpoint: 404/405; a rejected parameter: 422 with X-Error-Detail)
      return Remote.new(status: code.in?([404, 405]) ? 'no_capability' : 'rejected', payload: {}, error: detail) unless (200..299).cover?(code)

      json = result.json
      return Remote.new(status: 'error', payload: {}, error: "Unexpected answer from #{ENDPOINT}") unless json.is_a?(Hash) && json['tables'].is_a?(Hash)

      Remote.new(status: 'ok', payload: json, error: nil)
    end
    private_class_method :full_row, :light_row, :iso_time, :remote_for
  end
end
