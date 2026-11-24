# frozen_string_literal: true

require 'json'

#
# = CrawlerClient
#
# Minimal client for the local crawler server HTTP API (Node, see crawler/server/api.js).
#
# Never raises on connection problems: every call returns either a parsed value or nil
# (#status) or a Result (every crawl command: #pull_meeting, #pull_calendar, #pull_results_from_file,
# #pull_microplus, #pull_ficr, #pull_goandswim).
#
# Every crawl command makes the Node server start the crawl in the background and answer right away
# (with its current status): callers poll #status (see Crawler::RunWatcher) to learn when it ends.
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
  # URL of the local crawler server API (also read by CrawlerLauncher::STATUS_URL).
  BASE_URL = 'http://localhost:7000/'

  # Connection-level failures rescued by every call.
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

  # Starts the FIN calendar crawler (GET /pull_calendar): the crawler opens +start_url+ and simulates the click on the
  # +sub_menu_type+ menu item ('Eventi', 'Riepilogo Eventi', 'Archivio 2012-'), looking for the +year_text+ season
  # ('2025/2026'). The calendar CSV lands in 'crawler/data/calendar.new/<season_id>/'. Returns a Result.
  def pull_calendar(season_id:, start_url:, sub_menu_type:, year_text:)
    get('pull_calendar', params: { 'season_id' => season_id.to_s, 'start_url' => start_url.to_s,
                                   'sub_menu_type' => sub_menu_type.to_s, 'year_text' => year_text.to_s })
  end

  # Starts the FIN results crawler on every meeting listed by a calendar CSV file (GET /pull_results with
  # +file_path+; +layout+: 1 for the seasons before 182, 2 otherwise). Returns a Result.
  def pull_results_from_file(season_id:, file_path:, layout:)
    get('pull_results', params: { 'season_id' => season_id.to_s, 'file_path' => file_path.to_s, 'layout' => layout.to_i })
  end

  # Starts the Microplus results crawler (GET /pull_results_microplus; +target_event+: optional event title filter).
  # Returns a Result.
  def pull_microplus(season_id:, url:, target_event: nil)
    params = { 'season_id' => season_id.to_s, 'layout' => 4, 'meeting_url' => url.to_s }
    params['target_event'] = target_event.to_s if target_event.present?
    get('pull_results_microplus', params:)
  end

  # Starts the FICR results crawler (GET /pull_results_ficr). Returns a Result.
  def pull_ficr(season_id:, url:)
    get('pull_results_ficr', params: { 'season_id' => season_id.to_s, 'layout' => 5, 'meeting_url' => url.to_s })
  end

  # Starts the Go&Swim results crawler (GET /pull_results_goandswim). Returns a Result.
  def pull_goandswim(season_id:, url:)
    get('pull_results_goandswim', params: { 'season_id' => season_id.to_s, 'layout' => 6, 'meeting_url' => url.to_s })
  end

  private

  # GET-only commands (RestClient turns headers['params'] into the query string): the crawler API is local, and the
  # Node middleware would expect encoded form data for any payload.
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
