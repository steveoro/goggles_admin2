# frozen_string_literal: true

# = Users Controller
#
# Manage User via API.
#
class APIUsersController < ApplicationController
  # GET /api_users
  # Show the Users dashboard.
  #
  # == Assigns:
  # - <tt>@domain</tt>: list of all instance rows
  # - <tt>@grid</tt>: the customized Datagrid instance
  #
  def index
    index_params # prepare @index_params memoized member
    result = if grid_filter_params.present? || params[:page].present? || params[:per_page].present?
               APIProxy.call(
                 method: :get, url: 'users', jwt: current_user.jwt,
                 params: {
                   name: grid_filter_params[:name], description: grid_filter_params[:description],
                   email: grid_filter_params[:email],
                   page: index_params[:page], per_page: index_params[:per_page]
                 }
               )
             else
               APIProxy.call(method: :get, url: 'users', jwt: current_user.jwt)
             end
    parsed_response = result.body.present? ? JSON.parse(result.body) : { 'error' => "Error #{result.code}" }
    unless result.code == 200
      flash[:error] = I18n.t('dashboard.api_proxy_error', error_code: result.code, error_msg: parsed_response['error'])
      redirect_to(root_path) && return
    end

    set_grid_domain_for(UsersGrid, GogglesDb::User, result.headers, parsed_response)

    respond_to do |format|
      @grid = UsersGrid.new(grid_filter_params)

      format.html { @grid }

      format.csv do
        send_data(
          @grid.to_csv,
          type: 'text/csv',
          disposition: 'inline',
          filename: "grid-users-#{DateTime.now.strftime('%Y%m%d.%H%M%S')}.csv"
        )
      end
    end
  end
  #-- -------------------------------------------------------------------------
  #++

  # PUT /api_user/:id
  # Updates a single GogglesDb::User row.
  #
  # All instance attributes are accepted, minus lock_version & the timestamps, which are
  # handled automatically.
  #
  # == Route param:
  # - <tt>id</tt>: ID of the instance row to be updated
  #
  def update
    id = edit_params(GogglesDb::User)['id']
    # Extract manually here all bool columns edited direct with a RowBoolSwitch button, which handles
    # the field with an array of values, indexed by the current ID (doesn't matter if the value in
    # the array is always just one).
    #
    # == NOTE:
    # - 'locked_at' as User column is handled by the API as 'locked' & makes the account locked/unlocked;
    # - 'active' toggles the {#active_for_authentication?} method result in the User model,
    #    which basically acts as 'locked' but has a custom Devise message for the user trying to login.
    locked = params.permit(locked_at: {})[:locked_at]&.fetch(id, nil) == 'true'
    active = [nil, '', 'true'].include?(params.permit(active: {})[:active]&.fetch(id, nil))
    result = APIProxy.call(
      method: :put,
      url: "user/#{id}",
      jwt: current_user.jwt,
      payload: edit_params(GogglesDb::User).merge(locked:, active:)
    )

    if result.body == 'true'
      flash[:info] = I18n.t('datagrid.edit_modal.edit_ok')
    else
      flash[:error] = I18n.t('datagrid.edit_modal.edit_failed', error: result)
    end
    redirect_to(api_users_path(index_params))
  end

  # DELETE /api_users
  # Removes GogglesDb::User rows. Accepts single (:id) or multiple (:ids) IDs for the deletion.
  #
  # == Params:
  # - <tt>id</tt>: to be used for single row deletion
  # - <tt>ids</tt>: to be used for multiple rows deletion
  #
  def destroy
    row_ids = delete_params[:ids].present? ? delete_params[:ids].split(',') : []
    row_ids << delete_params[:id] if delete_params[:id].present?
    row_ids.reject! { |id| id.to_i < 4 }

    # Also, ignore required IDs (< 4):
    error_ids = delete_rows!('user', row_ids)

    if row_ids.present? && error_ids.empty?
      flash[:info] = I18n.t('dashboard.grid_commands.delete_ok', tot: row_ids.count, ids: row_ids.to_s)
    elsif error_ids.present?
      flash[:error] = I18n.t('dashboard.grid_commands.delete_error', ids: error_ids.to_s)
    else
      flash[:info] = I18n.t('dashboard.grid_commands.no_op_msg')
    end
    redirect_to(api_users_path(index_params))
  end
  #-- -------------------------------------------------------------------------
  #++

  protected

  # Default whitelist for datagrid parameters
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def grid_filter_params
    @grid_filter_params = params.fetch(:users_grid, {}).permit!
  end

  # Strong parameters checking for /index, including pass-through from modal editors.
  # (NOTE: memoizazion is needed because the member variable is used in the view.)
  def index_params
    index_params_for(:users_grid)
  end
end
