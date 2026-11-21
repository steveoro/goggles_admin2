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
    @data_fix_sources = GogglesDb::DataImportMeetingIndividualResult
                        .where.not(phase_file_path: [nil, ''])
                        .distinct
                        .order(:phase_file_path)
                        .pluck(:phase_file_path)
    @data_fix_session_count = @data_fix_sources.size
    @goggle_cups_count = count_remote_rows_for('goggle_cups')
  end

  protected

  # The landing page is reachable from API-offline sessions (remote counters will be zero).
  def api_offline_allowed?
    action_name == 'index'
  end

  private

  # Retrieves the remote row total for a specified endpoint.
  def count_remote_rows_for(api_endpoint)
    result = APIProxy.call(method: :get, url: api_endpoint, jwt: current_user&.jwt)
    result.headers[:total] || 0
  end
end
