# frozen_string_literal: true

module Drift
  #
  # = Drift::LatestUpdatesCheck
  #
  # Drift v0 (partial): does the local DB hold the rows most recently updated on the remote API?
  #
  # Calls the API's <tt>GET tools/latest_updates</tt> (<tt>max: 10</tt>; any valid JWT, here the background one
  # from Ops::BackgroundCredentials), which returns the 10 latest-updated rows of 12 tables
  # (<tt>{ '<table_name>' => [{ 'id' =>, 'updated_at' =>, ...1-2 columns }, ...], ... }</tt>), then checks that
  # every remote ID exists locally. Timestamps are not compared: the pushed SQL scripts write NOW() remotely.
  #
  # The outcome is stored in the ops snapshot 'drift_v0:<api_base_url>' (see the payload below) and read
  # through Drift::V0Status, which adds the live count of the unacknowledged remote writes (Ops::RemoteWrite).
  # Run by DriftCheckJob (recurring every 30 minutes). Phase 08 replaces it with full DB fingerprints.
  #
  # == Snapshot payload (String keys)
  #   {
  #     'url' => 'http://localhost:8081',
  #     'status' => 'ok' | 'no_credentials' | 'unreachable' | 'unauthorized' | 'unsupported' | 'error',
  #     'level' => 'ok' | 'warn' | 'unknown',                   # verdict at check time (see Drift::V0Status)
  #     'missing' => { 'meetings' => [1234, 1235], ... },       # remote IDs not found locally, per table
  #     'missing_count' => 2,
  #     'checked_tables' => ['calendars', 'meetings', ...],     # tables compared
  #     'remote_writes' => 0,                                   # unacknowledged remote writes at check time
  #     'acknowledged_at' => '<ISO 8601>' | nil,
  #     'error' => nil | '<detail>'                             # for the statuses other than 'ok'
  #   }
  #
  class LatestUpdatesCheck
    KEY_PREFIX = 'drift_v0:'
    ENDPOINT = 'tools/latest_updates'
    MAX_ROWS = 10
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    STATUSES = %w[ok no_credentials unreachable unauthorized unsupported error].freeze

    # Local models of the tables returned by 'tools/latest_updates', by table name.
    MODEL_NAMES = %w[
      Calendar Meeting MeetingIndividualResult MeetingRelayResult Lap RelayLap MeetingEvent MeetingProgram
      Swimmer Team Badge TeamAffiliation
    ].freeze

    class << self
      # Snapshot key for +base_url+ (trailing slash removed).
      def key_for(base_url)
        "#{KEY_PREFIX}#{normalize_url(base_url)}"
      end

      # The Ops::Snapshot for +base_url+, or nil. Never raises.
      def read(base_url = APIProxy.configured_base_url)
        Ops.safely { Ops::Snapshot.read(key_for(base_url)) if Ops.available? }
      end

      # { 'calendars' => GogglesDb::Calendar, ... }
      def models_by_table
        MODEL_NAMES.to_h do |name|
          model = "GogglesDb::#{name}".constantize
          [model.table_name, model]
        end
      end

      def normalize_url(base_url)
        base_url.to_s.strip.delete_suffix('/')
      end
    end

    attr_reader :base_url

    # == Params:
    # - base_url: API base URL (default: the configured one).
    def initialize(base_url: nil)
      @base_url = self.class.normalize_url(base_url.presence || APIProxy.configured_base_url)
    end

    # Runs the check and writes the snapshot. Returns the payload Hash (nil when the ops DB is not available).
    # Never raises: any failure is stored as status 'error'.
    def call
      return unless Ops.available?

      payload = build_payload
      Ops::Snapshot.write!(self.class.key_for(base_url), payload, source: 'drift_check')
      payload
    end

    private

    def build_payload
      payload = remote_payload
      writes = Ops::RemoteWrite.unacknowledged(base_url).count
      acknowledged_at = Ops::RemoteWrite.acknowledged_at
      payload.merge!('url' => base_url, 'remote_writes' => writes, 'acknowledged_at' => acknowledged_at&.iso8601)
      payload['level'] = V0Status.new(base_url:, payload:, checked_at: Time.current, remote_writes: writes).level.to_s
      payload
    end

    # Status, missing IDs & checked tables from the API (no snapshot write).
    def remote_payload
      jwt = Ops::BackgroundCredentials.jwt
      return failure('no_credentials') if jwt.blank?

      result = APIProxy.call(method: :get, url: ENDPOINT, jwt:, params: { max: MAX_ROWS }, base_url:,
                             open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT)
      return failure_for(result) unless (200..299).cover?(result.code.to_i) && !result.unreachable?
      return failure('unsupported', "Unexpected answer from #{ENDPOINT}") unless result.json.is_a?(Hash)

      compare(result.json)
    rescue StandardError => e
      Rails.logger.warn("[Drift::LatestUpdatesCheck] #{e.class}: #{e.message}")
      failure('error', "#{e.class}: #{e.message}")
    end

    def failure_for(result)
      detail = result.error_detail.to_s
      return failure('unreachable', detail) if result.unreachable?
      return failure('unauthorized', detail) if result.code.to_i == 401
      # (An API without the endpoint answers 404 or 405)
      return failure('unsupported', detail) if [404, 405].include?(result.code.to_i)

      failure('error', detail)
    end

    def failure(status, error = nil)
      { 'status' => status, 'missing' => {}, 'missing_count' => 0, 'checked_tables' => [],
        'error' => error.to_s.truncate(300).presence }
    end

    # Looks up locally each remote ID, per table (tables without a known local model are skipped).
    def compare(remote_rows)
      models = self.class.models_by_table
      missing = {}
      checked = []
      remote_rows.each do |table, rows|
        model = models[table.to_s]
        next unless model && rows.is_a?(Array)

        checked << table.to_s
        absent = missing_ids(model, rows)
        missing[table.to_s] = absent if absent.any?
      end
      { 'status' => 'ok', 'missing' => missing, 'missing_count' => missing.values.sum(&:size),
        'checked_tables' => checked, 'error' => nil }
    end

    # Sorted IDs of the remote +rows+ not found in the local +model+ table.
    def missing_ids(model, rows)
      ids = rows.filter_map { |row| row['id'].to_i if row.is_a?(Hash) && row['id'].present? }.uniq
      (ids - model.where(id: ids).pluck(:id)).sort
    end
  end
end
