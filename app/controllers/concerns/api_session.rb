# frozen_string_literal: true

#
# = APISession
#
# JWT session helpers & support for "API-offline" sessions: admin sessions signed-in from localhost using just the local
# DB credentials, because the API server couldn't release a valid JWT (server down, wrong URL in
# the settings, credentials rejected by the remote DB, ...).
#
# These sessions can reach only the actions that don't need the API (see #api_offline_allowed?),
# so that the API connection URL can be fixed from the Settings page.
#
# The session details are stored in <tt>session[:api_offline]</tt> as an Hash with keys
# 'url' (API base URL), 'reason' (error detail) & 'at' (ISO8601 timestamp).
#
module APISession
  extend ActiveSupport::Concern

  included do
    helper_method :api_offline_session?, :api_offline_info
  end

  protected

  # True when the specified user has a JWT that is still valid for the configured API key.
  def valid_jwt?(user)
    GogglesDb::JWTManager.decode(user&.jwt, Rails.application.credentials.api_static_key).present?
  end

  # True when the request comes from localhost (loopback IPs only; X-Forwarded-For is
  # considered only when coming from trusted proxies -- see ActionDispatch::RemoteIp).
  def local_request?
    ActionDispatch::Request::LOCALHOST.match?(request.remote_ip.to_s)
  end

  # True for a signed-in session created without a valid API JWT (localhost only).
  def api_offline_session?
    session[:api_offline].present? && local_request?
  end

  # Returns the API-offline session details Hash ('url', 'reason', 'at'), or +nil+.
  def api_offline_info
    session[:api_offline]
  end

  # Signs out the current user and redirects to the sign-in page, with an optional error message.
  def force_new_sign_in(error_msg = nil)
    sign_out(current_user)
    flash[:error] = error_msg if error_msg.present?
    redirect_to(new_user_session_path)
  end

  # Override in subclasses to allow API-offline sessions to reach specific actions
  # (default: none).
  def api_offline_allowed?
    false
  end

  # Lets an API-offline session through only for API-independent actions,
  # redirecting to the Settings page otherwise.
  def handle_api_offline_session
    return if api_offline_allowed?

    flash[:warning] = I18n.t('api_offline.redirected')
    redirect_to(settings_path)
  end
end
