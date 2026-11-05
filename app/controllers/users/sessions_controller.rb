# frozen_string_literal: true

# = Devise::SessionsController customizations
#
module Users
  #
  # = SessionsController customizations
  #
  # Credentials are always checked against the local DB (Devise); a valid API JWT is then
  # retrieved from the API server currently configured in the local settings.
  #
  # When the JWT can't be obtained (API server down, wrong URL, credentials rejected by the remote DB, ...):
  # - from localhost: the admin is signed-in anyway as an "API-offline" session, which can reach
  #   only the Settings & Home pages, so that the API connection URL can be fixed;
  # - from any other IP: the sign-in is refused.
  #
  class SessionsController < Devise::SessionsController
    # POST /resource/sign_in
    def create
      self.resource = warden.authenticate!(auth_options)
      return reject_sign_in(I18n.t('devise.api_login.errors.not_an_admin')) unless GogglesDb::GrantChecker.admin?(resource)

      # Clear omniauth fields anyway:
      resource.update_columns(uid: nil, provider: nil)
      return reject_sign_in(@api_error) unless prepare_api_session?(resource, params['user'])

      super
    end

    # DELETE /resource/sign_out
    def destroy
      super
      reset_session
    end

    protected

    # Lands API-offline sessions directly on the Settings page.
    def after_sign_in_path_for(resource)
      session[:api_offline].present? ? settings_path : super
    end

    private

    # Signs out the just-authenticated resource and goes back to the sign-in page showing an error.
    def reject_sign_in(error_msg)
      sign_out(resource)
      flash[:error] = error_msg
      redirect_to(new_user_session_path)
    end

    # Makes sure a valid JWT is stored inside the user instance (refreshing it through the API when needed)
    # or, for local requests only, flags the session as API-offline.
    #
    # Returns +true+ when the sign-in can proceed; +false+ otherwise (with @api_error set).
    #
    def prepare_api_session?(user, user_params)
      if valid_jwt?(user)
        session.delete(:api_offline)
        return true
      end

      jwt, error = fetch_jwt(user_params)
      if jwt.present?
        user.update_columns(jwt:)
        session.delete(:api_offline)
        return true
      end

      unless local_request?
        @api_error = I18n.t('api_offline.remote_denied', reason: error)
        return false
      end

      flag_api_offline_session!(error)
      true
    end

    # Retrieves a new JWT from the API given the user params ('email' & 'password').
    #
    # == Returns:
    # <tt>[jwt, nil]</tt> on success; <tt>[nil, error_detail]</tt> otherwise.
    #
    def fetch_jwt(user_params)
      logger.debug("\r\nJWT for current user expired or invalid. Refreshing...")
      payload = {
        e: user_params['email'],
        p: user_params['password'],
        t: Rails.application.credentials.api_static_key
      }
      result = APIProxy.call(method: :post, url: 'session', payload:)
      return [nil, result.error_detail] unless (200..299).cover?(result.code)

      jwt = result.json.is_a?(Hash) ? result.json['jwt'] : nil
      jwt.present? ? [jwt, nil] : [nil, I18n.t('devise.api_login.errors.unauthorized')]
    end

    # Stores the API-offline details in the session & warns the user.
    def flag_api_offline_session!(error)
      url = APIProxy.configured_base_url
      logger.warn("* API-offline sign-in from localhost (API: #{url}): #{error}")
      session[:api_offline] = { 'url' => url, 'reason' => error.to_s.truncate(300), 'at' => Time.current.iso8601 }
      flash[:warning] = I18n.t('api_offline.signed_in_offline', url:, reason: error)
    end
    #-- -------------------------------------------------------------------------
    #++
  end
end
