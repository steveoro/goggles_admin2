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
end
#-- ---------------------------------------------------------------------------
#++
