# frozen_string_literal: true

require 'singleton'

# = API Proxy
#
#   - version:  7-0.5.02
#   - author:   Steve A.
#   - build:    20230424
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
    # Non-JSON or blank bodies are normalized into an 'error' Hash.
    def json
      @json ||= JSON.parse(__getobj__.body.to_s)
    rescue StandardError
      { 'error' => __getobj__.body.presence || "Error #{code}" }
    end

    # Most useful human-readable detail for a failed call:
    # X-Error-Detail header > JSON 'error' field > raw body > status code.
    def error_detail
      detail = headers[:x_error_detail].presence
      detail ||= json['error'] if json.is_a?(Hash)
      detail.presence || __getobj__.body.presence || "Error #{code}"
    end
  end

  # Generic call helper
  #
  # == Options:
  # - :method         => HTTP method used ('get', 'post', 'put', 'delete')
  # - :url            => API endpoint URL without the base prefix (i.e.: 'session')
  # - :payload        => data Hash to be used as body payload (only for POST, PUT & DELETE)
  # - :jwt            => JWT for the call (if a previous session has already been created)
  # - :params         => GET parameters for the call (only for GET)
  # - :port_override  => Port number override for the API base URL; when +nil+, uses the default found from the settings
  #
  # == Returns
  # An APIProxy::Result wrapping the RestClient Response, even in case of errors.
  # The result's #body is always a valid JSON string; #json is its parsed value
  # and #error_detail the best human-readable rejection reason.
  #
  def self.call(options = {}) # rubocop:disable Metrics/AbcSize
    method = options[:method]
    url = options[:url]
    payload = options[:payload]
    jwt = options[:jwt]
    params = options[:params]
    port_override = options[:port_override]
    api_base_url = GogglesDb::AppParameter.config.settings(:framework_urls).api
    api_base_url = api_base_url.gsub(/:\d{3}$/, ":#{port_override}") if port_override.present?
    whitelisted = params.respond_to?(:permit!) ? params.permit!.to_h : params&.to_h
    hdrs = whitelisted.present? ? { params: whitelisted } : {}
    hdrs['Authorization'] = "Bearer #{jwt}" if jwt.present?

    Result.new(
      RestClient::Request.execute(
        method:,
        url: "#{api_base_url}/api/v3/#{url}",
        payload: payload.to_h,
        headers: hdrs
      )
    )
  rescue RestClient::ExceptionWithResponse => e
    Result.new(e.response)
  end
  #-- -------------------------------------------------------------------------
  #++
end
