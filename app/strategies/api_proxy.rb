# frozen_string_literal: true

require 'singleton'

# = API Proxy
#
#   - version:  7-0.10.70
#   - author:   Steve A.
#   - build:    20261105
#
#   Helper wrapper for various API calls.
#
class APIProxy
  include Singleton

  # == APIProxy::Result
  #
  # Normalized result wrapper for API calls. Delegates everything to the
  # wrapped RestClient::Response, but guarantees that the body is always
  # valid JSON: non-JSON or blank bodies (Rails error pages, proxy 503s,
  # plain text responses) are normalized into an <tt>{ 'error' => <detail> }</tt>
  # Hash so callers can always safely parse the result.
  #
  # (JSON primitives like 'true' keep passing through untouched, so
  # `result.body == 'true'` checks keep working.)
  #
  class Result < SimpleDelegator
    # The response body as a valid JSON string (see #json for the parsed value).
    def body
      json.to_json
    end

    # The parsed response body; never raises.
    # Blank/malformed bodies on a successful response are normalized into
    # an empty Hash ("no content"), while non-JSON error bodies become an
    # 'error' Hash — so callers can always parse, and 'body.present?'
    # semantics stay unchanged (a blank 2xx still yields no domain rows).
    def json
      return @json if defined?(@json)

      @json = begin
        JSON.parse(__getobj__.body.to_s)
      rescue StandardError
        (200..299).cover?(code) ? {} : { 'error' => __getobj__.body.presence || "Error #{code}" }
      end
    end

    # True when the API server could not be reached at all (see UnreachableResponse)
    def unreachable?
      __getobj__.respond_to?(:unreachable?) && __getobj__.unreachable?
    end

    # Most useful human-readable detail for a failed call:
    # X-Error-Detail header > JSON 'error' field > raw body > status code.
    def error_detail
      detail = headers[:x_error_detail].presence
      detail ||= json['error'] if json.is_a?(Hash)
      detail.presence || __getobj__.body.presence || "Error #{code}"
    end
  end

  # == APIProxy::UnreachableResponse
  #
  # Stand-in response used when the API server cannot be reached at all
  # (connection refused, unknown host, timeouts, TLS errors, ...): mimics the
  # minimal RestClient::Response interface used by callers so that a missing
  # API server never raises.
  #
  class UnreachableResponse
    # HTTP-like code reported for unreachable servers
    CODE = 503

    attr_reader :code, :body, :headers

    def initialize(base_url, error)
      @code = CODE
      detail = "API unreachable (#{base_url}): #{error.class}: #{error.message}"
      @body = { 'error' => detail }.to_json
      @headers = { x_error_detail: detail }
    end

    def unreachable?
      true
    end
  end

  # Seconds allowed for opening the connection to the API server
  OPEN_TIMEOUT = 5

  # Connection-level errors that yield an UnreachableResponse instead of raising
  CONNECTION_ERRORS = [
    RestClient::Exception, SystemCallError, SocketError, OpenSSL::SSL::SSLError, Timeout::Error
  ].freeze

  # Generic call helper
  #
  # == Options:
  # - :method         => HTTP method used ('get', 'post', 'put', 'delete')
  # - :url            => API endpoint URL without the base prefix (i.e.: 'session')
  # - :payload        => data Hash to be used as body payload (only for POST, PUT & DELETE)
  # - :jwt            => JWT for the call (if a previous session has already been created)
  # - :params         => GET parameters for the call (only for GET)
  # - :port_override  => Port number override for the API base URL; when +nil+, uses the default found from the settings
  # - :base_url       => API base URL override (protocol, host & port); when +nil+, uses the one found from the settings
  #
  # == Returns
  # An APIProxy::Result wrapping the RestClient Response, even in case of errors.
  # The result's #body is always a valid JSON string; #json is its parsed value
  # and #error_detail the best human-readable rejection reason.
  # When the server cannot be reached at all, the result wraps an UnreachableResponse
  # (code 503, #unreachable? true) instead of raising.
  #
  def self.call(options = {})
    api_base_url = base_url_for(options[:base_url], options[:port_override])
    params = options[:params]
    whitelisted = params.respond_to?(:permit!) ? params.permit!.to_h : params&.to_h
    hdrs = whitelisted.present? ? { params: whitelisted } : {}
    hdrs['Authorization'] = "Bearer #{options[:jwt]}" if options[:jwt].present?

    execute(api_base_url, method: options[:method], url: "#{api_base_url}/api/v3/#{options[:url]}",
                          payload: options[:payload].to_h, headers: hdrs)
  end

  # Checks the public 'status' endpoint (no JWT needed) of the specified API server
  # (or the currently configured one when +nil+).
  #
  # == Returns
  # The APIProxy::Result of the call (see #call).
  #
  def self.ping(base_url = nil)
    call(method: :get, url: 'status', base_url:)
  end

  # Returns the currently configured API base URL (from the local settings)
  def self.configured_base_url
    GogglesDb::AppParameter.config.settings(:framework_urls).api.to_s
  end

  # Returns the API base URL, given the optional overrides
  def self.base_url_for(base_url_override, port_override)
    api_base_url = base_url_override.presence || configured_base_url
    api_base_url = api_base_url.gsub(/:\d{3}$/, ":#{port_override}") if port_override.present?
    api_base_url.delete_suffix('/')
  end
  private_class_method :base_url_for

  # Executes the request, wrapping any outcome into a Result
  def self.execute(api_base_url, request_options)
    Result.new(RestClient::Request.execute(open_timeout: OPEN_TIMEOUT, **request_options))
  rescue RestClient::ExceptionWithResponse => e
    Result.new(e.response || UnreachableResponse.new(api_base_url, e))
  rescue *CONNECTION_ERRORS => e
    Rails.logger.warn("[APIProxy] #{e.class} for '#{request_options[:url]}': #{e.message}")
    Result.new(UnreachableResponse.new(api_base_url, e))
  end
  private_class_method :execute
  #-- -------------------------------------------------------------------------
  #++
end
