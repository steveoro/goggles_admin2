# frozen_string_literal: true

#
# = KpiRefreshJob
#
# Read-only refresh of the four dashboard KPI counters (row totals of 'users', 'import_queues', 'issues'
# and 'api_daily_uses' on the configured API), stored in the ops snapshot 'kpi:<api_base_url>'.
# Never commits, pushes or applies anything.
#
# Recurring every 15 minutes (config/recurring.yml, 'kpi_refresh'), also enqueued after each sign-in with
# a valid JWT and (phase 05 dashboard) by the "Refresh counters" button.
#
# - Each counter is one GET with <tt>per_page: 1</tt>, reading the api-pagination 'Total' header, with short
#   timeouts (OPEN_TIMEOUT / READ_TIMEOUT): the 'default' worker has a single thread.
# - The JWT comes from Ops::BackgroundCredentials, at run time; without a valid one no call is made.
# - The first unreachable or 401 answer stops the remaining calls (they would fail the same way).
# - A counter that can't be refreshed keeps its previous value (and its own 'fetched_at' time).
# - The key includes the API URL: switching server in Settings never shows the other server's numbers.
# - Does nothing when the ops DB is not available.
#
# == Snapshot payload (String keys)
#   {
#     'url' => 'http://localhost:8081',
#     'status' => 'ok' | 'partial' | 'unreachable' | 'unauthorized' | 'no_credentials',
#     'values' => { 'users' => 87, 'import_queues' => 3, 'issues' => 12, 'api_uses' => 1234 },  # last known
#     'fetched_at' => { 'users' => '<ISO 8601>', ... },  # time of each value's last successful fetch
#     'errors' => { 'issues' => 'Error 500' }            # this run only
#   }
# A counter never fetched is absent from 'values' (never a silent 0). The snapshot's +taken_at+ is the
# time of the last run.
#
class KpiRefreshJob < ApplicationJob
  queue_as :default

  # One refresh at a time; duplicates enqueued meanwhile (e.g. sign-in + recurring) are dropped:
  limits_concurrency key: 'kpi_refresh', to: 1, duration: 5.minutes, on_conflict: :discard

  KEY_PREFIX = 'kpi:'
  # Counter key => API endpoint ('api_uses' is the row count of 'api_daily_uses').
  ENDPOINTS = { 'users' => 'users', 'import_queues' => 'import_queues', 'issues' => 'issues',
                'api_uses' => 'api_daily_uses' }.freeze
  STATUSES = %w[ok partial unreachable unauthorized no_credentials].freeze
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  class << self
    # Snapshot key for +base_url+ (trailing slash removed).
    def key_for(base_url)
      "#{KEY_PREFIX}#{base_url.to_s.strip.delete_suffix('/')}"
    end

    # The Ops::Snapshot for +base_url+ (default: the configured API), or nil. Never raises.
    def read(base_url = APIProxy.configured_base_url)
      Ops.safely { Ops::Snapshot.read(key_for(base_url)) if Ops.available? }
    end
  end

  # == Params:
  # - base_url: API base URL (default: the configured one).
  # Returns the written payload Hash, or nil when the ops DB is not available.
  def perform(base_url: nil)
    return unless Ops.available?

    @base_url = (base_url.presence || APIProxy.configured_base_url).to_s.strip.delete_suffix('/')
    previous = previous_payload
    payload = { 'url' => @base_url, 'values' => previous.fetch('values', {}).to_h,
                'fetched_at' => previous.fetch('fetched_at', {}).to_h, 'errors' => {} }
    jwt = Ops::BackgroundCredentials.jwt
    payload['status'] = jwt.present? ? fetch_all(payload, jwt) : 'no_credentials'
    Ops::Snapshot.write!(self.class.key_for(@base_url), payload, source: 'kpi_refresh')
    payload
  end

  private

  def previous_payload
    snapshot = Ops::Snapshot.read(self.class.key_for(@base_url))
    snapshot&.payload.is_a?(Hash) ? snapshot.payload : {}
  end

  # Fetches each counter into +payload+; returns the overall status.
  def fetch_all(payload, jwt)
    stop_status = nil
    ENDPOINTS.each do |key, endpoint|
      result = APIProxy.call(method: :get, url: endpoint, jwt:, params: { per_page: 1 }, base_url: @base_url,
                             open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT)
      stop_status = store_counter(payload, key, result)
      break if stop_status
    end
    stop_status || (payload['errors'].empty? ? 'ok' : 'partial')
  end

  # Stores one counter (value or error); returns 'unreachable' / 'unauthorized' when the run must stop.
  def store_counter(payload, key, result)
    total = result.headers[:total] if (200..299).cover?(result.code.to_i) && !result.unreachable?
    if total.to_s.match?(/\A\d+\z/)
      payload['values'][key] = total.to_i
      payload['fetched_at'][key] = Time.current.iso8601
      return
    end

    payload['errors'][key] = error_for(result)
    return 'unreachable' if result.unreachable?

    'unauthorized' if result.code.to_i == 401
  end

  def error_for(result)
    return "Error #{result.code}: no 'Total' header" if (200..299).cover?(result.code.to_i)

    result.error_detail.to_s.truncate(300)
  end
end
