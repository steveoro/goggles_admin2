# frozen_string_literal: true

require 'version'

# = HomeController
#
# Main landing actions.
#
class HomeController < ApplicationController
  # [GET] Main landing page default action.
  def index
    # (no-op)

    # Simulate API response while UI is still in design phase:
    @users_count = GogglesDb::User.count
    # @user_list = APIProxy.call(method: :get, url: 'users', jwt: current_user.jwt)

    # user_list: array of JSONified User instances (no subdetails), like this:
    # {"id"=>1,
    # "lock_version"=>910,
    # "name"=>"steve",
    # "description"=>"Stefano Alloro",
    # "swimmer_id"=>142,
    # "created_at"=>"2013-10-23T17:10:00.000Z",
    # "updated_at"=>"2020-11-10T11:42:26.000Z",
    # "email"=>"steve.alloro@gmail.com",
    # "avatar_url"=>nil,
    # "swimmer_level_type_id"=>nil,
    # "coach_level_type_id"=>nil,
    # "jwt"=>"zcjHAztDSzevSqaKsC3D",
    # "outstanding_goggle_score_bias"=>800,
    # "outstanding_standard_score_bias"=>800,
    # "last_name"=>"Alloro",
    # "first_name"=>"Stefano",
    # "year_of_birth"=>1969,
    # "provider"=>nil,
    # "uid"=>nil}

    @iqs_count = GogglesDb::ImportQueue.count
    # @user_list = APIProxy.call(method: :get, url: 'users', jwt: current_user.jwt)

    @api_uses_count = GogglesDb::APIDailyUse.count
    # @user_list = APIProxy.call(method: :get, url: 'users', jwt: current_user.jwt)

    # Setting groups:
    # GogglesDb::AppParameter::SETTINGS_GROUPS
    # => GogglesDb::AppParameter.config.settings(<GROUP_SYM>).values
    # :prefs on current_user
    # => current_user.settings(:prefs).values
  end
end
