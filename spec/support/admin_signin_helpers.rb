# frozen_string_literal: true

# = AdminSignInHelpers
#
# Adds helper methods for quick Admin sign-in, using an already valid JWT for the session.
#
module AdminSignInHelpers
  # Returns a new admin-type <tt>GogglesDb::User</tt> with a refreshed, valid JWT.
  def prepare_admin_user
    admin_user = FactoryBot.create(:user)
    # Freshen the JWT:
    admin_user.jwt = GogglesDb::JWTManager.encode(
      { user_id: admin_user.id },
      Rails.application.credentials.api_static_key
    )
    admin_user.save!
    # Add the proper grant:
    admin_grant = FactoryBot.create(:admin_grant, user: admin_user, entity: nil)
    expect(admin_grant).to be_a(GogglesDb::AdminGrant).and be_valid
    admin_user
  end

  # Signs-in the specified <tt>admin_user</tt>, checking that's a valid
  # admin-user instance.
  def sign_in_admin(admin_user)
    expect(admin_user).to be_a(GogglesDb::User).and be_valid
    expect(GogglesDb::GrantChecker.admin?(admin_user)).to be true
    sign_in(admin_user)
  end

  # Returns an APIProxy::Result as returned for an unreachable API server.
  def unreachable_api_result(base_url = 'http://localhost:8085')
    APIProxy::Result.new(
      APIProxy::UnreachableResponse.new(base_url, Errno::ECONNREFUSED.new('connect(2) for "localhost" port 8085'))
    )
  end

  # Signs-in the specified <tt>admin_user</tt> through the actual Users::SessionsController#create action,
  # with an expired JWT and an unreachable API server, obtaining an "API-offline" session
  # (as long as the request comes from localhost, which is the default for request specs).
  #
  # == Params:
  # - <tt>admin_user</tt>: the admin user (built by #prepare_admin_user)
  # - <tt>headers</tt>: additional request headers (or env, e.g. 'REMOTE_ADDR')
  def sign_in_api_offline(admin_user, headers: {})
    admin_user.update!(jwt: nil)
    allow(APIProxy).to receive(:call)
      .with(hash_including(method: :post, url: 'session'))
      .and_return(unreachable_api_result)
    post(user_session_path, params: { user: { email: admin_user.email, password: 'Password123!' } }, headers:)
  end
end
#-- ---------------------------------------------------------------------------
#++
