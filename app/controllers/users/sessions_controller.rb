# frozen_string_literal: true

# = Devise::SessionsController customizations
#
module Users
  #
  # = SessionsController customizations
  #
  class SessionsController < Devise::SessionsController
    # POST /resource/sign_in
    def create
      self.resource = warden.authenticate!(auth_options)
      freshen_jwt!(resource, params)
      super

      # Original #create (keep here for future reference):
      #
      # self.resource = warden.authenticate!(auth_options)
      # set_flash_message!(:notice, :signed_in)
      # sign_in(resource_name, resource)
      # yield resource if block_given?
      # respond_with resource, location: after_sign_in_path_for(resource)
    end

    private

    # Makes sure a valid JWT is always stored inside the current_user instance.
    # Redirects to login (new_user_session_path) unless the user is an Admin or in case of errors.
    def freshen_jwt!(user, params)
      unless GogglesDb::GrantChecker.admin?(user)
        set_flash_message!(:error, I18n.t('devise.api_login.errors.not_an_admin'))
        redirect_to new_user_session_path && return
      end

      # Clear omniauth fields anyway:
      user.update_columns(uid: nil, provider: nil)

      # Check JWT:
      decoded_jwt = GogglesDb::JWTManager.decode(user.jwt, Rails.application.credentials.api_static_key)

      # JWT expired? Get a fresh one:
      user.update_columns(jwt: retrieve_jwt(params['user'])) if decoded_jwt.nil?
      user.reload
    end

    # Returns the updated JWT given the specified user params.
    # Redirects to new_user_session_path in case of errors
    #
    # == Params:
    # - 'email' => User email
    # - 'password' => User password
    #
    def retrieve_jwt(params)
      logger.debug('\r\nJWT for current user expired or invalid. Refreshing...')
      payload = {
        e: params['email'],
        p: params['password'],
        t: Rails.application.credentials.api_static_key
      }

      response = APIProxy.call(method: :post, url: 'session', payload: payload)
      unless (200..299).cover?(response.code)
        msg = JSON.parse(response.body)
        set_flash_message!(:error, msg['error'])
        redirect_to new_user_session_path && return
      end

      json = JSON.parse(response.body)
      unless json['jwt'].present?
        set_flash_message!(:error, I18n.t('devise.api_login.errors.unauthorized'))
        redirect_to new_user_session_path && return
      end

      json['jwt']
    end
    #-- -------------------------------------------------------------------------
    #++
  end
end
