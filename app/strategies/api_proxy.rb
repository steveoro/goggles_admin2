# frozen_string_literal: true

require 'singleton'

# = API Proxy
#
#   - file vers.: 0.3.29
#   - author....: Steve A.
#   - build.....: 20210908
#
#   Helper wrapper for various API calls.
#
class APIProxy
  include Singleton

  # Generic call helper
  #
  # == Params
  # - :method  => HTTP method used ('get', 'post', 'put', 'delete')
  # - :url     => API endpoint URL without the base prefix (i.e.: 'session')
  # - :payload => data Hash to be used as body payload (only for POST, PUT & DELETE)
  # - :jwt     => JWT for the call (if a previous session has already been created)
  # - :params  => GET parameters for the call (only for GET)
  #
  # == Returns
  # A RestClient Response object, even in case of errors.
  #
  def self.call(method:, url:, payload: nil, jwt: nil, params: nil)
    api_base_url = GogglesDb::AppParameter.config.settings(:framework_urls).api
    hdrs = params.present? ? { params: params.to_h } : {}
    hdrs.merge!('Authorization' => "Bearer #{jwt}") if jwt.present?
    # DEBUG
    # Rails.logger.debug("\r\n-- APIProxy, headers:")
    # Rails.logger.debug(hdrs.inspect)
    # Rails.logger.debug("\r\n-- APIProxy, payload:")
    # Rails.logger.debug(payload.inspect)

    RestClient::Request.execute(
      method: method,
      url: "#{api_base_url}/api/v3/#{url}",
      payload: payload.to_h,
      headers: hdrs
    )
  rescue RestClient::ExceptionWithResponse => e
    e.response
  end
  #-- -------------------------------------------------------------------------
  #++
end
