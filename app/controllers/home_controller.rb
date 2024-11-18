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
    @users_count = count_remote_rows_for('users')
    @iqs_count = count_remote_rows_for('import_queues')
    @issues_count = count_remote_rows_for('issues')
    @api_uses_count = count_remote_rows_for('api_daily_uses')
  end

  # [GET] Retrieve the latest updates from both production & staging servers endpoints
  # (regardless of the currently connected server according to the settings).
  #
  def latest_updates
    # (ASSUMES: 447 => production, 446 => staging)
    @prod_updates = request_latest_updates(447)
    if @prod_updates.key?('error')
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: @prod_updates['error'].split.last, error_msg: @prod_updates['error'])
      redirect_to(root_path) && return
    end

    @staging_updates = request_latest_updates(446)
    return unless @staging_updates.key?('error')

    flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: @staging_updates['error'].split.last, error_msg: @staging_updates['error'])
    redirect_to(root_path) && return
  end

  private

  # Retrieves the remote row total for a specified endpoint.
  def count_remote_rows_for(api_endpoint)
    result = APIProxy.call(method: :get, url: api_endpoint, jwt: current_user&.jwt)
    result.headers[:total] || 0
  end

  # Retrieves the hash containing the latest row updates for the specified server (distinguished by the
  # port used for the API endpoint); nil in case of error.
  def request_latest_updates(port_override)
    result = APIProxy.call(method: :get, url: 'tools/latest_updates', jwt: current_user.jwt, port_override: port_override)
    result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
  end
end
