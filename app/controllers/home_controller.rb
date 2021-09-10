# frozen_string_literal: true

require 'version'

# = HomeController
#
# Main landing actions.
#
class HomeController < ApplicationController
  # [GET] Main landing page default action.
  #
  # Computes also main counters displayed on the landing dashboard.
  #
  def index
    result = APIProxy.call(method: :get, url: 'users', jwt: current_user.jwt)
    @users_count = result.headers[:total]

    result = APIProxy.call(method: :get, url: 'import_queues', jwt: current_user.jwt)
    @iqs_count = result.headers[:total]

    result = APIProxy.call(method: :get, url: 'api_daily_uses', jwt: current_user.jwt)
    @api_uses_count = result.headers[:total]
  end
end
