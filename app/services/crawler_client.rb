# frozen_string_literal: true

require 'json'

#
# = CrawlerClient
#
# Minimal client for the local crawler server HTTP API (Node, see crawler/server/api.js).
#
# Never raises on connection problems: every call returns either a parsed value or nil
# (#status) or a Result (#pull_meeting).
#
# == Crawler status file
# The Node side writes { timestamp:, status:, detail:, progress:, total: } through
# CrawlUtil.updateStatus (crawler/server/utility.js), where:
# - timestamp is the UTC time formatted as 'YYYYMMDD-HHMMSS' (fullTimeStamp());
# - status is a terse label: 'OK, idle' (server boot), 'OK, running', 'OK, processing i/n',
#   'OK, postprocessing', 'OK, done, idle' (end of a calendar/direct-URL run), 'DONE' (Microplus),
#   'ERROR' (failed run), 'no-file' (no status file yet).
# See CrawlerClient::Status.
#
class CrawlerClient
  BASE_URL = PullController::CRAWLER_API_URL

  # Connection-level failures rescued by every call (and by PullController#call_crawler_api).
  # (RestClient::Exception covers HTTP error codes, RestClient timeouts & ServerBrokeConnection.)
  CONNECTION_ERRORS = [
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT,
    SocketError, Timeout::Error, RestClient::Exception
  ].freeze

  # Outcome of an API command:
  # - ok: true when the server answered with a 2xx code;
  # - code: HTTP status code (nil when unreachable);
  # - body: parsed JSON body (or the raw body when not JSON; nil when unreachable);
  # - error: error message (nil when ok).
  Result = Data.define(:ok, :code, :body, :error) do
    def ok? = ok
    def unreachable? = code.nil? && !ok
  end

  # Parsed crawler status (see the class notes for the values written by the Node side).
  # Terse status labels written when no crawl is running (or a run has just ended).
  IDLE_STATUS_REGEXP = /idle|\Adone\z|\Aerror\z|\Ano-file\z|moved to "done" folder/i
  ERROR_STATUS_REGEXP = /\Aerror\z/i
  # Format of the status 'timestamp' (UTC).
  STATUS_TIMESTAMP_FORMAT = '%Y%m%d-%H%M%S'

  Status = Data.define(:status, :detail, :timestamp, :progress, :total, :raw) do
    # Builds a Status from the parsed status Hash (nil when not a Hash).
    def self.from(hash)
      return nil unless hash.is_a?(Hash)

      new(status: hash['status'].to_s, detail: hash['detail'].to_s, timestamp: parse_timestamp(hash['timestamp']),
          progress: hash['progress'].to_i, total: hash['total'].to_i, raw: hash)
    end

    def self.parse_timestamp(value)
      return nil if value.blank?

      ActiveSupport::TimeZone['UTC'].strptime(value.to_s, STATUS_TIMESTAMP_FORMAT)
    rescue ArgumentError
      nil
    end

    # True for a terminal/idle label ('OK, idle', 'OK, done, idle', 'DONE', 'ERROR', ...).
    def idle? = IDLE_STATUS_REGEXP.match?(status)
    def error? = ERROR_STATUS_REGEXP.match?(status)

    # True when the status claims a crawl in progress but hasn't been updated for +stale_after+
    # (or carries no timestamp at all): e.g. a run that died without writing its final status.
    def stale?(now:, stale_after:)
      timestamp.nil? || timestamp < now - stale_after
    end

    # True when a (non-stale) crawl is in progress.
    def busy?(now:, stale_after:)
      !idle? && !stale?(now:, stale_after:)
    end
  end

  def initialize(base_url: BASE_URL, timeout: 10, open_timeout: 3)
    @base_url = base_url
    @timeout = timeout
    @open_timeout = open_timeout
  end

  # Returns the parsed status Hash (GET /status), or nil when unreachable or unparsable.
  def status
    result = get('status')
    result.ok? && result.body.is_a?(Hash) ? result.body : nil
  end

  # Starts the FIN results crawler (layout 2) for a single meeting URL (GET /pull_results).
  # The crawler answers right away (with its current status) and runs in the background.
  # Returns a Result.
  def pull_meeting(season_id:, url:)
    get('pull_results', params: { 'season_id' => season_id.to_s, 'layout' => 2, 'meeting_url' => url.to_s })
  end

  private

  # Same request shape as PullController#call_crawler_api (RestClient turns headers['params'] into the query string).
  def get(endpoint, params: nil)
    headers = { 'Content-Type' => 'application/json' }
    headers['params'] = params if params
    response = RestClient::Request.execute(method: :get, url: "#{@base_url}#{endpoint}", headers:,
                                           timeout: @timeout, open_timeout: @open_timeout)
    Result.new(ok: true, code: response.code, body: parse_body(response.body), error: nil)
  rescue RestClient::ExceptionWithResponse => e
    Result.new(ok: false, code: e.http_code, body: parse_body(e.response&.body), error: error_message(e))
  rescue *CONNECTION_ERRORS => e
    Rails.logger.warn("[CrawlerClient] GET /#{endpoint} failed: #{e.class}: #{e.message}")
    Result.new(ok: false, code: nil, body: nil, error: "#{e.class}: #{e.message}")
  end

  def parse_body(body)
    return nil if body.nil?

    JSON.parse(body.to_s)
  rescue JSON::ParserError
    body.to_s
  end

  def error_message(error)
    body = parse_body(error.response&.body)
    body.is_a?(Hash) && body['error'].present? ? "#{error.message}: #{body['error']}" : error.message
  end
end
