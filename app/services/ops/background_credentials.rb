# frozen_string_literal: true

module Ops
  #
  # = Ops::BackgroundCredentials
  #
  # The API JWT used by the background jobs (KPI refresh, drift check), read at run time and never
  # stored anywhere new nor logged: it's the +users.jwt+ column (MySQL) of the admin who signed in last.
  #
  # - The user: the one stored in the Ops::Setting 'background.user_id' by Users::SessionsController
  #   after each sign-in with a valid JWT; otherwise (setting missing, user gone or no longer an admin)
  #   the admin with a JWT and the latest +current_sign_in_at+.
  # - The JWT is returned only while it is valid for the local API static key (the same check as
  #   APISession#valid_jwt?); goggles_api issues tokens lasting GogglesDb::JWTManager::TOKEN_LIFE (10 hours).
  #
  # A 401 from the API (e.g. the API URL now points to a server with another key) is not tracked here:
  # each job records it as 'unauthorized' in its own snapshot.
  #
  # == Usage
  #   Ops::BackgroundCredentials.jwt        # => String or nil
  #   Ops::BackgroundCredentials.status     # => :valid, :expired or :missing
  #   creds = Ops::BackgroundCredentials.new
  #   creds.status; creds.expires_at; creds.user_id
  #
  class BackgroundCredentials
    SETTING_KEY = 'background.user_id'
    STATUSES = %i[valid expired missing].freeze

    class << self
      # Stores +user+ as the background user (after a successful sign-in). Never raises; returns the ID or nil.
      def remember!(user)
        return if user&.id.blank?

        Ops.safely { Ops::Setting.store!(SETTING_KEY, user.id) if Ops.available? }
      end

      # The valid background JWT (or nil) and its status (:valid, :expired or :missing), from a new instance.
      delegate :jwt, :status, to: :new
    end

    # The background user (GogglesDb::User), or nil. Memoized.
    def user
      return @user if defined?(@user)

      @user = stored_user || latest_admin
    end

    def user_id
      user&.id
    end

    # The user's JWT when still valid; nil otherwise.
    def jwt
      valid? ? user.jwt : nil
    end

    # :missing (no user or no JWT), :expired (expired or not valid for the local API key) or :valid.
    def status
      return @status if defined?(@status)

      @status = if user.nil? || user.jwt.blank?
                  :missing
                elsif decoded_payload.present?
                  :valid
                else
                  :expired
                end
    end

    def valid?
      status == :valid
    end

    # Expiry time of the valid JWT (its 'exp' claim), or nil.
    def expires_at
      return unless valid?

      exp = JWT.decode(user.jwt, api_static_key, true, algorithm: 'HS512').first['exp']
      exp ? Time.zone.at(exp.to_i) : nil
    rescue JWT::DecodeError
      nil
    end

    private

    def decoded_payload
      GogglesDb::JWTManager.decode(user.jwt, api_static_key)
    end

    def api_static_key
      Rails.application.credentials.api_static_key
    end

    def stored_user
      user_id = Ops.safely { Ops::Setting.fetch(SETTING_KEY) if Ops.available? }
      return if user_id.blank?

      candidate = GogglesDb::User.find_by(id: user_id.to_i)
      candidate if GogglesDb::GrantChecker.admin?(candidate)
    end

    def latest_admin
      admin_ids = GogglesDb::AdminGrant.where(entity: nil).select(:user_id)
      GogglesDb::User.where(id: admin_ids).where.not(jwt: [nil, ''])
                     .order(GogglesDb::User.arel_table[:current_sign_in_at].desc)
                     .first
    end
  end
end
